//! An `std.Io` implementation whose tasks run as fibers on a libuv event loop.
//!
//! Every task (`io.async`, `io.concurrent`, `Group.async`, ...) gets its own stack and runs on
//! the loop thread. When a task waits (`await`, `sleep`, a futex used by `Io.Mutex`,
//! `Io.Condition`, `Io.Queue`, ...), it switches back to the loop instead of blocking the
//! thread, so thousands of waiting tasks cost memory, not threads.
//!
//! Tasks, groups, cancelation, futexes and sleeping are implemented natively. Every other
//! operation (files, sockets, DNS, processes, ...) is handed to an `Io.Threaded` instance: the
//! task is suspended while one of that instance's worker threads performs the blocking call,
//! and it resumes on the loop once the call returns. The loop thread itself never blocks.
//!
//! Rules:
//! - The `Io` must only be used from the tasks it runs (all of them run on the loop thread).
//! - Code that blocks the thread without going through the `Io` (a C library calling `recv`,
//!   `std.Thread.sleep`, a long CPU-bound loop) blocks the whole loop.
//! - Operations handed to `Io.Threaded` are not interrupted by cancelation: a cancel request
//!   takes effect at the task's next cancelation point after the operation returns.
//!
//! Fibers use std's context switch (`std.Io.fiber`) on POSIX systems, and Win32 fibers on
//! Windows, where switching stacks also needs the thread information block to be updated.

const std = @import("std");
const builtin = @import("builtin");
const uv = @import("uv");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const logger = std.log.scoped(.libuv_io);

const is_windows = builtin.os.tag == .windows;

comptime {
    if (!is_windows and !Io.fiber.supported) {
        @compileError("azig's Io needs fibers, which std does not support on " ++ @tagName(builtin.cpu.arch));
    }
}

/// Largest alignment supported for task arguments and results.
const max_task_align: Alignment = .@"64";
/// Number of buckets futex waiters are spread over (by address).
const futex_bucket_count = 64;

pub const Options = struct {
    /// Stack size of each task. On POSIX systems the memory is reserved up front but only
    /// committed as it is used; on Windows it is the fiber's reserved stack size.
    stack_size: usize = 4 * 1024 * 1024,
    /// Finished tasks keep their stack for reuse, up to this many.
    max_idle_tasks: usize = 256,
};

pub const InitError = error{ IoInitFailed, OutOfMemory };

/// A task started with `spawnDetached`. Only valid until its finish callback has run.
pub const Task = *Fiber;

pub const Libuv = struct {
    allocator: Allocator,
    loop: *uv.uv_loop_t,
    options: Options,
    /// Performs every operation that is not implemented natively.
    fallback: Io.Threaded,
    /// The fallback's tasks that perform operations on behalf of fibers.
    offload_group: Io.Group = .init,
    loop_thread: std.Thread.Id,

    /// The loop's own context, which runs libuv callbacks and resumes fibers.
    main: MainContext,
    /// Windows: whether `init` turned the loop thread into a fiber (and `deinit` must undo it).
    converted_thread: bool = false,
    /// The fiber that is running, or null while the loop's own context runs.
    current: ?*Fiber = null,

    ready: FiberQueue = .{},
    draining: bool = false,
    /// Active while fibers are ready to run, so the loop does not block in its poll phase.
    idle: uv.uv_idle_t = undefined,
    idle_active: bool = false,
    /// Wakes the loop when another thread completes an operation for a fiber. Referenced
    /// while tasks are alive, so the loop keeps running until every task has finished.
    wake_signal: uv.uv_async_t = undefined,
    /// Fibers whose offloaded operation has completed, pushed by worker threads.
    remote_head: ?*Fiber = null,
    /// Tasks that have been started and have not finished yet.
    live: usize = 0,

    idle_fibers: ?*Fiber = null,
    idle_count: usize = 0,
    futex_buckets: [futex_bucket_count]?*Fiber = @splat(null),

    const MainContext = if (is_windows) *anyopaque else Io.fiber.Context;

    /// Must be called on the thread that runs `loop`, and the instance must not move
    /// afterwards. Call `deinit` once the loop has stopped running, before it is closed.
    pub fn init(lio: *Libuv, allocator: Allocator, loop: *uv.uv_loop_t, options: Options) InitError!void {
        lio.* = .{
            .allocator = allocator,
            .loop = loop,
            .options = options,
            .fallback = Io.Threaded.init(allocator, .{}),
            .loop_thread = std.Thread.getCurrentId(),
            .main = undefined,
        };
        errdefer lio.fallback.deinit();

        if (uv.uv_idle_init(loop, &lio.idle) != 0) return error.IoInitFailed;
        lio.idle.data = lio;
        errdefer uv.uv_close(@ptrCast(&lio.idle), null);

        if (uv.uv_async_init(loop, &lio.wake_signal, onWake) != 0) return error.IoInitFailed;
        lio.wake_signal.data = lio;
        uv.uv_unref(@ptrCast(&lio.wake_signal));
        errdefer uv.uv_close(@ptrCast(&lio.wake_signal), null);

        if (is_windows) {
            if (win.IsThreadAFiber() != 0) {
                lio.main = win.getCurrentFiber();
            } else {
                lio.main = win.ConvertThreadToFiberEx(null, win.FIBER_FLAG_FLOAT_SWITCH) orelse return error.IoInitFailed;
                lio.converted_thread = true;
            }
        }
    }

    /// Closes the instance's libuv handles; the loop must run once more (and then be closed)
    /// for them to finish closing. Every task must have finished.
    pub fn deinit(lio: *Libuv) void {
        if (lio.live != 0) {
            logger.err("{d} task(s) still running at shutdown; their memory is leaked", .{lio.live});
        }

        // Waits until every worker is done with this instance (the last thing a worker does
        // is wake the loop through `wake_signal`, so it must stay open until then).
        lio.offload_group.await(lio.fallback.io()) catch {};

        uv.uv_close(@ptrCast(&lio.idle), null);
        uv.uv_close(@ptrCast(&lio.wake_signal), null);

        while (lio.idle_fibers) |fiber| {
            lio.idle_fibers = fiber.next;
            fiber.destroy();
        }
        lio.idle_count = 0;

        lio.fallback.deinit();

        if (is_windows and lio.converted_thread) {
            _ = win.ConvertFiberToThread();
        }
    }

    pub fn io(lio: *Libuv) Io {
        return .{ .userdata = lio, .vtable = &vtable };
    }

    /// Starts `start(arg)` as a task. Once it returns, `finish(arg)` runs on the loop's own
    /// context (not on the task's stack). Must be called on the loop thread.
    pub fn spawnDetached(
        lio: *Libuv,
        start: *const fn (arg: *anyopaque) void,
        finish: *const fn (arg: *anyopaque) void,
        arg: *anyopaque,
    ) error{OutOfMemory}!Task {
        const fiber = try lio.spawn(.detached, &.{}, .@"1", 0, .@"1");
        fiber.detached_start = start;
        fiber.detached_finish = finish;
        fiber.detached_arg = arg;
        lio.schedule(fiber);
        return fiber;
    }

    /// Requests cancelation of a task started with `spawnDetached`: its next cancelation
    /// point (or the one it is waiting in) returns `error.Canceled`.
    pub fn cancelTask(lio: *Libuv, task: Task) void {
        lio.requestCancel(task);
    }

    // ---------------------------------------------------------------------------------------
    // Scheduling

    fn spawn(
        lio: *Libuv,
        kind: Fiber.Kind,
        context: []const u8,
        context_alignment: Alignment,
        result_len: usize,
        result_alignment: Alignment,
    ) error{OutOfMemory}!*Fiber {
        lio.assertLoopThread();
        if (context_alignment.compare(.gt, max_task_align) or result_alignment.compare(.gt, max_task_align)) {
            return error.OutOfMemory;
        }

        const fiber = try lio.acquireFiber();
        errdefer lio.releaseFiber(fiber);
        try fiber.prepareTask(context, result_len);

        fiber.kind = kind;
        fiber.cancel = .none;
        fiber.protection = .unblocked;
        fiber.awaiter = null;
        lio.liveInc();
        return fiber;
    }

    fn acquireFiber(lio: *Libuv) error{OutOfMemory}!*Fiber {
        if (lio.idle_fibers) |fiber| {
            lio.idle_fibers = fiber.next;
            lio.idle_count -= 1;
            fiber.next = null;
            return fiber;
        }
        return Fiber.create(lio);
    }

    fn releaseFiber(lio: *Libuv, fiber: *Fiber) void {
        fiber.state = .idle;
        fiber.group = null;
        fiber.detached_start = null;
        fiber.detached_finish = null;
        fiber.detached_arg = null;
        if (lio.idle_count < lio.options.max_idle_tasks) {
            fiber.next = lio.idle_fibers;
            lio.idle_fibers = fiber;
            lio.idle_count += 1;
        } else {
            fiber.destroy();
        }
    }

    fn liveInc(lio: *Libuv) void {
        if (lio.live == 0) uv.uv_ref(@ptrCast(&lio.wake_signal));
        lio.live += 1;
    }

    fn liveDec(lio: *Libuv) void {
        lio.live -= 1;
        if (lio.live == 0) uv.uv_unref(@ptrCast(&lio.wake_signal));
    }

    fn schedule(lio: *Libuv, fiber: *Fiber) void {
        fiber.state = .ready;
        lio.ready.push(fiber);
        if (!lio.idle_active) {
            _ = uv.uv_idle_start(&lio.idle, onIdle);
            lio.idle_active = true;
        }
    }

    /// Runs ready fibers until none is left. Only runs on the loop's own context.
    fn drain(lio: *Libuv) void {
        if (lio.draining) return;
        assert(lio.current == null);
        lio.draining = true;
        defer lio.draining = false;

        while (lio.ready.pop()) |fiber| {
            lio.current = fiber;
            fiber.state = .running;
            lio.switchTo(fiber);
            lio.current = null;
            if (fiber.state == .finished) lio.onFinished(fiber);
        }

        if (lio.idle_active) {
            _ = uv.uv_idle_stop(&lio.idle);
            lio.idle_active = false;
        }
    }

    fn onFinished(lio: *Libuv, fiber: *Fiber) void {
        lio.liveDec();
        switch (fiber.kind) {
            // Kept (with its result) until it is awaited or canceled.
            .future => if (fiber.awaiter) |awaiter| lio.wake(awaiter, .normal),
            .group => {
                lio.groupRemove(fiber);
                lio.releaseFiber(fiber);
            },
            .detached => {
                const finish = fiber.detached_finish.?;
                const arg = fiber.detached_arg.?;
                lio.releaseFiber(fiber);
                finish(arg);
            },
        }
    }

    fn switchTo(lio: *Libuv, fiber: *Fiber) void {
        if (is_windows) {
            win.SwitchToFiber(fiber.platform);
        } else {
            _ = Io.fiber.contextSwitch(&.{ .old = &lio.main, .new = &fiber.platform.context });
        }
    }

    fn yieldToMain(lio: *Libuv, fiber: *Fiber) void {
        if (is_windows) {
            win.SwitchToFiber(lio.main);
        } else {
            _ = Io.fiber.contextSwitch(&.{ .old = &fiber.platform.context, .new = &lio.main });
        }
    }

    fn currentFiber(lio: *Libuv) *Fiber {
        lio.assertLoopThread();
        return lio.current orelse @panic("a blocking std.Io operation was called outside of a task of azig's Io");
    }

    fn assertLoopThread(lio: *Libuv) void {
        if (std.debug.runtime_safety and std.Thread.getCurrentId() != lio.loop_thread) {
            @panic("azig's Io was used from a thread other than its event loop's");
        }
    }

    /// Suspends the current fiber until `wake` is called for it.
    fn suspendCurrent(lio: *Libuv, wait: Fiber.Wait, cancelable: bool) Fiber.Woke {
        const fiber = lio.currentFiber();
        fiber.wait = wait;
        fiber.wait_cancelable = cancelable;
        fiber.state = .waiting;
        lio.yieldToMain(fiber);
        fiber.wait = .none;
        if (fiber.woke == .canceled) fiber.cancel = .acknowledged;
        return fiber.woke;
    }

    fn wake(lio: *Libuv, fiber: *Fiber, reason: Fiber.Woke) void {
        if (fiber.state != .waiting) return;
        if (fiber.wait == .futex) lio.futexRemove(fiber);
        if (fiber.timer_active) {
            _ = uv.uv_timer_stop(&fiber.timer);
            fiber.timer_active = false;
        }
        fiber.woke = reason;
        lio.schedule(fiber);
    }

    fn startTimer(fiber: *Fiber, duration: Io.Duration) void {
        const ns = duration.toNanoseconds();
        const ms: u64 = if (ns <= 0) 0 else @intCast(@min(
            @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            std.math.maxInt(u64),
        ));
        _ = uv.uv_timer_start(&fiber.timer, onTimer, ms, 0);
        fiber.timer_active = true;
    }

    fn requestCancel(lio: *Libuv, fiber: *Fiber) void {
        switch (fiber.state) {
            .idle, .finished => return,
            .ready, .running, .waiting => {},
        }
        if (fiber.cancel != .none) return;
        fiber.cancel = .requested;
        if (fiber.state == .waiting and fiber.wait_cancelable and fiber.protection == .unblocked) {
            lio.wake(fiber, .canceled);
        }
    }

    /// Called from worker threads once an offloaded operation has completed.
    fn postRemote(lio: *Libuv, fiber: *Fiber) void {
        var head = @atomicLoad(?*Fiber, &lio.remote_head, .monotonic);
        while (true) {
            fiber.remote_next = head;
            head = @cmpxchgWeak(?*Fiber, &lio.remote_head, head, fiber, .release, .monotonic) orelse break;
        }
        _ = uv.uv_async_send(&lio.wake_signal);
    }

    fn onIdle(handle: [*c]uv.uv_idle_t) callconv(.c) void {
        const lio: *Libuv = @ptrCast(@alignCast(handle.*.data));
        lio.drain();
    }

    fn onWake(handle: [*c]uv.uv_async_t) callconv(.c) void {
        const lio: *Libuv = @ptrCast(@alignCast(handle.*.data));
        var node = @atomicRmw(?*Fiber, &lio.remote_head, .Xchg, null, .acquire);
        // The stack holds the most recent completion first; wake fibers in completion order.
        var reversed: ?*Fiber = null;
        while (node) |fiber| {
            node = fiber.remote_next;
            fiber.remote_next = reversed;
            reversed = fiber;
        }
        while (reversed) |fiber| {
            reversed = fiber.remote_next;
            fiber.remote_next = null;
            lio.wake(fiber, .normal);
        }
        lio.drain();
    }

    fn onTimer(handle: [*c]uv.uv_timer_t) callconv(.c) void {
        const fiber: *Fiber = @ptrCast(@alignCast(handle.*.data));
        fiber.timer_active = false;
        fiber.lio.wake(fiber, .timeout);
        fiber.lio.drain();
    }

    // ---------------------------------------------------------------------------------------
    // Groups. `Io.Group.state` holds the first member of an intrusive list of the group's
    // running tasks. `Io.Group.token` is null when no task is running; otherwise it points
    // to the fiber waiting in `groupAwait`/`groupCancel`, or to the instance if none is.

    fn groupHead(g: *Io.Group) ?*Fiber {
        return @ptrFromInt(g.state);
    }

    fn groupAdd(lio: *Libuv, g: *Io.Group, fiber: *Fiber) void {
        fiber.group = g;
        fiber.group_prev = null;
        fiber.group_next = groupHead(g);
        if (groupHead(g)) |head| head.group_prev = fiber;
        g.state = @intFromPtr(fiber);
        if (g.token.load(.monotonic) == null) g.token.store(lio, .monotonic);
    }

    fn groupRemove(lio: *Libuv, fiber: *Fiber) void {
        const g = fiber.group.?;
        if (fiber.group_prev) |prev| prev.group_next = fiber.group_next else g.state = @intFromPtr(fiber.group_next);
        if (fiber.group_next) |next| next.group_prev = fiber.group_prev;
        fiber.group_prev = null;
        fiber.group_next = null;
        fiber.group = null;

        if (g.state == 0) {
            const token = g.token.load(.monotonic);
            g.token.store(null, .monotonic);
            if (token) |t| {
                if (t != @as(*anyopaque, lio)) lio.wake(@ptrCast(@alignCast(t)), .normal);
            }
        }
    }

    fn groupCancelMembers(lio: *Libuv, g: *Io.Group) void {
        var member = groupHead(g);
        while (member) |fiber| : (member = fiber.group_next) lio.requestCancel(fiber);
    }

    // ---------------------------------------------------------------------------------------
    // Futex

    fn futexBucket(lio: *Libuv, address: usize) *?*Fiber {
        return &lio.futex_buckets[(address >> 2) % futex_bucket_count];
    }

    fn futexInsert(lio: *Libuv, fiber: *Fiber, address: usize) void {
        const bucket = lio.futexBucket(address);
        fiber.futex_address = address;
        fiber.wait_prev = null;
        fiber.wait_next = bucket.*;
        if (bucket.*) |head| head.wait_prev = fiber;
        bucket.* = fiber;
    }

    fn futexRemove(lio: *Libuv, fiber: *Fiber) void {
        const bucket = lio.futexBucket(fiber.futex_address);
        if (fiber.wait_prev) |prev| prev.wait_next = fiber.wait_next else bucket.* = fiber.wait_next;
        if (fiber.wait_next) |next| next.wait_prev = fiber.wait_prev;
        fiber.wait_prev = null;
        fiber.wait_next = null;
    }

    fn futexWaitInner(lio: *Libuv, ptr: *const u32, expected: u32, timeout: Io.Timeout, cancelable: bool) Io.Cancelable!void {
        const fiber = lio.currentFiber();
        if (cancelable) try fiber.checkCancel();
        if (@atomicLoad(u32, ptr, .acquire) != expected) return;

        const duration: ?Io.Clock.Duration = timeout.toDurationFromNow(lio.io());
        if (duration) |d| {
            if (d.raw.toNanoseconds() <= 0) return;
        }

        lio.futexInsert(fiber, @intFromPtr(ptr));
        if (duration) |d| startTimer(fiber, d.raw);
        switch (lio.suspendCurrent(.futex, cancelable)) {
            .normal, .timeout => {},
            .canceled => return error.Canceled,
        }
    }

    // ---------------------------------------------------------------------------------------
    // Natively implemented `Io.VTable` functions.

    const native = struct {
        pub fn async(
            userdata: ?*anyopaque,
            result: []u8,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) ?*Io.AnyFuture {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.spawn(.future, context, context_alignment, result.len, result_alignment) catch {
                start(context.ptr, result.ptr);
                return null;
            };
            fiber.start_future = start;
            lio.schedule(fiber);
            return @ptrCast(fiber);
        }

        pub fn concurrent(
            userdata: ?*anyopaque,
            result_len: usize,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) Io.ConcurrentError!*Io.AnyFuture {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.spawn(.future, context, context_alignment, result_len, result_alignment) catch
                return error.ConcurrencyUnavailable;
            fiber.start_future = start;
            lio.schedule(fiber);
            return @ptrCast(fiber);
        }

        pub fn await(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
            _ = result_alignment;
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const target: *Fiber = @ptrCast(@alignCast(any_future));

            if (target.state != .finished) {
                const self = lio.currentFiber();
                target.awaiter = self;
                var propagated = false;
                while (target.state != .finished) {
                    if (lio.suspendCurrent(.await, !propagated) == .canceled) {
                        // The awaiting task was canceled: the cancelation goes to the awaited one.
                        propagated = true;
                        lio.requestCancel(target);
                    }
                }
                // If the awaited task never acknowledged the cancelation, it is still ours.
                if (propagated and target.cancel != .acknowledged) self.cancel = .requested;
            }

            @memcpy(result, target.resultBytes(result.len));
            lio.releaseFiber(target);
        }

        pub fn cancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
            _ = result_alignment;
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const target: *Fiber = @ptrCast(@alignCast(any_future));

            if (target.state != .finished) {
                lio.requestCancel(target);
                target.awaiter = lio.currentFiber();
                while (target.state != .finished) _ = lio.suspendCurrent(.await, false);
            }

            @memcpy(result, target.resultBytes(result.len));
            lio.releaseFiber(target);
        }

        pub fn groupAsync(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque) void,
        ) void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.spawn(.group, context, context_alignment, 0, .@"1") catch return start(context.ptr);
            fiber.start_group = start;
            lio.groupAdd(group, fiber);
            lio.schedule(fiber);
        }

        pub fn groupConcurrent(
            userdata: ?*anyopaque,
            group: *Io.Group,
            context: []const u8,
            context_alignment: Alignment,
            start: *const fn (context: *const anyopaque) void,
        ) Io.ConcurrentError!void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.spawn(.group, context, context_alignment, 0, .@"1") catch
                return error.ConcurrencyUnavailable;
            fiber.start_group = start;
            lio.groupAdd(group, fiber);
            lio.schedule(fiber);
        }

        pub fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
            _ = token;
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            if (groupHead(group) == null) {
                group.token.store(null, .monotonic);
                return;
            }
            const self = lio.currentFiber();
            group.token.store(self, .monotonic);
            var canceled = false;
            while (groupHead(group) != null) {
                if (lio.suspendCurrent(.group_await, !canceled) == .canceled) {
                    canceled = true;
                    lio.groupCancelMembers(group);
                }
            }
            if (canceled) return error.Canceled;
        }

        pub fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
            _ = token;
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            if (groupHead(group) == null) {
                group.token.store(null, .monotonic);
                return;
            }
            lio.groupCancelMembers(group);
            group.token.store(lio.currentFiber(), .monotonic);
            while (groupHead(group) != null) _ = lio.suspendCurrent(.group_await, false);
        }

        pub fn recancel(userdata: ?*anyopaque) void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.currentFiber();
            assert(fiber.cancel == .acknowledged); // called `recancel` but was not canceled
            fiber.cancel = .requested;
        }

        pub fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.current orelse return .unblocked;
            const old = fiber.protection;
            fiber.protection = new;
            return old;
        }

        pub fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.current orelse return;
            return fiber.checkCancel();
        }

        pub fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            return lio.futexWaitInner(ptr, expected, timeout, true);
        }

        pub fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            lio.futexWaitInner(ptr, expected, .none, false) catch unreachable;
        }

        pub fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            lio.assertLoopThread();
            const address = @intFromPtr(ptr);
            var woken: u32 = 0;
            var node = lio.futexBucket(address).*;
            while (node) |fiber| {
                if (woken == max_waiters) break;
                node = fiber.wait_next;
                if (fiber.futex_address == address) {
                    lio.wake(fiber, .normal);
                    woken += 1;
                }
            }
        }

        pub fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.current orelse {
                // Not in a task (e.g. setup code on the loop thread): block the thread.
                return lio.fallback.io().vtable.sleep(lio.fallback.io().userdata, timeout);
            };
            try fiber.checkCancel();
            const duration = timeout.toDurationFromNow(lio.io());
            if (duration) |d| {
                if (d.raw.toNanoseconds() <= 0) return;
                startTimer(fiber, d.raw);
            }
            switch (lio.suspendCurrent(.sleep, true)) {
                .normal, .timeout => {},
                .canceled => return error.Canceled,
            }
        }
    };

    // ---------------------------------------------------------------------------------------
    // Operations performed by the fallback `Io.Threaded`.

    /// Operations that never block for long, run directly on the calling thread.
    const run_inline = [_][]const u8{
        "crashHandler",            "now",                  "clockResolution",
        "random",                  "randomSecure",         "lockStderr",
        "tryLockStderr",           "unlockStderr",         "processExecutablePath",
        "processCurrentPath",      "processSetCurrentDir", "processSetCurrentPath",
        "processReplace",          "progressParentFile",   "inheritParentDir",
        "inheritParentFile",       "fileClose",            "dirClose",
        "netClose",                "childKill",            "fileMemoryMapDestroy",
        "netInterfaceName",        "netInterfaceNameResolve",
        "fileIsTty",               "fileSupportsAnsiEscapeCodes",
        "fileEnableAnsiEscapeCodes",
    };

    fn runsInline(comptime name: []const u8) bool {
        for (run_inline) |inline_name| {
            if (std.mem.eql(u8, inline_name, name)) return true;
        }
        return false;
    }

    fn canReturnCanceled(comptime R: type) bool {
        const E = switch (@typeInfo(R)) {
            .error_union => |eu| eu.error_set,
            else => return false,
        };
        const names = @typeInfo(E).error_set.error_names orelse return true;
        for (names) |err_name| {
            if (std.mem.eql(u8, err_name, "Canceled")) return true;
        }
        return false;
    }

    /// Generates a `VTable` function that forwards `name` to the fallback `Io.Threaded`,
    /// either on the calling thread or on one of its workers.
    fn Forward(comptime name: []const u8) type {
        const Fn = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
        const info = @typeInfo(Fn).@"fn";
        const R = info.return_type.?;
        const P = info.param_types;
        const offload = !runsInline(name);

        return struct {
            fn call(userdata: ?*anyopaque, args: anytype) R {
                const lio: *Libuv = @ptrCast(@alignCast(userdata));
                const fallback = lio.fallback.io();
                const target = @field(fallback.vtable, name);
                if (!offload) return @call(.auto, target, .{fallback.userdata} ++ args);

                const fiber = lio.current orelse return @call(.auto, target, .{fallback.userdata} ++ args);
                if (comptime canReturnCanceled(R)) {
                    fiber.checkCancel() catch return error.Canceled;
                }

                const Job = struct {
                    lio: *Libuv,
                    fiber: *Fiber,
                    args: @TypeOf(args),
                    result: R = undefined,

                    fn run(context: *const anyopaque) void {
                        const job: *@This() = @as(*const *@This(), @ptrCast(@alignCast(context))).*;
                        const l = job.lio;
                        const f = job.fiber;
                        const fb = l.fallback.io();
                        job.result = @call(.auto, @field(fb.vtable, name), .{fb.userdata} ++ job.args);
                        // `job` lives on the fiber's stack: it may be gone once the fiber resumes.
                        l.postRemote(f);
                    }
                };
                var job: Job = .{ .lio = lio, .fiber = fiber, .args = args };
                const job_ptr: *Job = &job;
                fallback.vtable.groupConcurrent(fallback.userdata, &lio.offload_group, @ptrCast(&job_ptr), .of(*Job), Job.run) catch {
                    // No worker available: perform the operation here, blocking the loop.
                    return @call(.auto, target, .{fallback.userdata} ++ args);
                };
                _ = lio.suspendCurrent(.offload, false);
                return job.result;
            }

            const function = switch (P.len) {
                1 => struct {
                    fn f(ud: ?*anyopaque) R {
                        return call(ud, .{});
                    }
                }.f,
                2 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?) R {
                        return call(ud, .{a});
                    }
                }.f,
                3 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?) R {
                        return call(ud, .{ a, b });
                    }
                }.f,
                4 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?) R {
                        return call(ud, .{ a, b, c });
                    }
                }.f,
                5 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?) R {
                        return call(ud, .{ a, b, c, d });
                    }
                }.f,
                6 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?) R {
                        return call(ud, .{ a, b, c, d, e });
                    }
                }.f,
                7 => struct {
                    fn f(ud: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?, g: P[6].?) R {
                        return call(ud, .{ a, b, c, d, e, g });
                    }
                }.f,
                else => @compileError("unsupported number of parameters in Io.VTable." ++ name),
            };
        };
    }

    const vtable: Io.VTable = blk: {
        @setEvalBranchQuota(100_000);
        var vt: Io.VTable = undefined;
        for (@typeInfo(Io.VTable).@"struct".field_names) |name| {
            @field(vt, name) = if (@hasDecl(native, name)) // must be `pub` to be seen
                &@field(native, name)
            else
                &Forward(name).function;
        }
        break :blk vt;
    };
};

const FiberQueue = struct {
    head: ?*Fiber = null,
    tail: ?*Fiber = null,

    fn push(q: *FiberQueue, fiber: *Fiber) void {
        fiber.next = null;
        if (q.tail) |tail| tail.next = fiber else q.head = fiber;
        q.tail = fiber;
    }

    fn pop(q: *FiberQueue) ?*Fiber {
        const fiber = q.head orelse return null;
        q.head = fiber.next;
        if (q.head == null) q.tail = null;
        fiber.next = null;
        return fiber;
    }
};

const Fiber = struct {
    lio: *Libuv,
    allocator: Allocator,
    platform: Platform,
    /// Used by `sleep` and futex timeouts. Initialized for the fiber's whole lifetime.
    timer: uv.uv_timer_t,
    timer_active: bool = false,

    state: State = .idle,
    kind: Kind = .detached,

    /// The task's arguments, followed by its result.
    buffer: []align(max_task_align.toByteUnits()) u8 = &.{},
    result_offset: usize = 0,
    start_future: ?*const fn (context: *const anyopaque, result: *anyopaque) void = null,
    start_group: ?*const fn (context: *const anyopaque) void = null,
    detached_start: ?*const fn (arg: *anyopaque) void = null,
    detached_finish: ?*const fn (arg: *anyopaque) void = null,
    detached_arg: ?*anyopaque = null,

    /// The fiber waiting for this future to finish.
    awaiter: ?*Fiber = null,
    group: ?*Io.Group = null,
    group_prev: ?*Fiber = null,
    group_next: ?*Fiber = null,

    cancel: CancelStatus = .none,
    protection: Io.CancelProtection = .unblocked,

    wait: Wait = .none,
    wait_cancelable: bool = false,
    woke: Woke = .normal,
    futex_address: usize = 0,
    wait_prev: ?*Fiber = null,
    wait_next: ?*Fiber = null,

    /// Ready queue or idle list.
    next: ?*Fiber = null,
    /// Completion stack filled by worker threads.
    remote_next: ?*Fiber = null,

    const State = enum { idle, ready, running, waiting, finished };
    const Kind = enum { future, group, detached };
    const CancelStatus = enum { none, requested, acknowledged };
    const Wait = enum { none, futex, sleep, await, group_await, offload };
    const Woke = enum { normal, timeout, canceled };

    const Platform = if (is_windows) *anyopaque else struct {
        context: Io.fiber.Context,
        stack: []align(std.heap.page_size_min) u8,
    };

    fn create(lio: *Libuv) error{OutOfMemory}!*Fiber {
        const fiber = try lio.allocator.create(Fiber);
        errdefer lio.allocator.destroy(fiber);
        fiber.* = .{
            .lio = lio,
            .allocator = lio.allocator,
            .platform = undefined,
            .timer = undefined,
        };

        if (is_windows) {
            fiber.platform = win.CreateFiberEx(0, lio.options.stack_size, win.FIBER_FLAG_FLOAT_SWITCH, windowsEntry, fiber) orelse
                return error.OutOfMemory;
        } else {
            const stack = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), lio.options.stack_size);
            protectGuardPage(stack);
            fiber.platform = .{ .context = initialContext(stack, fiber), .stack = stack };
        }
        errdefer fiber.freeStack();

        if (uv.uv_timer_init(lio.loop, &fiber.timer) != 0) return error.OutOfMemory;
        fiber.timer.data = fiber;
        return fiber;
    }

    /// Frees the fiber. Its memory is released once its timer has finished closing.
    fn destroy(fiber: *Fiber) void {
        fiber.freeStack();
        if (fiber.buffer.len > 0) fiber.allocator.free(fiber.buffer);
        fiber.buffer = &.{};
        uv.uv_close(@ptrCast(&fiber.timer), onTimerClosed);
    }

    fn onTimerClosed(handle: [*c]uv.uv_handle_t) callconv(.c) void {
        const fiber: *Fiber = @ptrCast(@alignCast(handle.*.data));
        fiber.allocator.destroy(fiber);
    }

    fn freeStack(fiber: *Fiber) void {
        if (is_windows) {
            win.DeleteFiber(fiber.platform);
        } else {
            std.heap.page_allocator.free(fiber.platform.stack);
        }
    }

    fn prepareTask(fiber: *Fiber, context: []const u8, result_len: usize) error{OutOfMemory}!void {
        const result_offset = max_task_align.forward(context.len);
        const total = result_offset + result_len;
        if (fiber.buffer.len < total) {
            if (fiber.buffer.len > 0) fiber.allocator.free(fiber.buffer);
            fiber.buffer = &.{};
            fiber.buffer = try fiber.allocator.alignedAlloc(u8, max_task_align, total);
        }
        @memcpy(fiber.buffer[0..context.len], context);
        fiber.result_offset = result_offset;
    }

    fn contextPointer(fiber: *Fiber) *const anyopaque {
        return fiber.buffer.ptr;
    }

    fn resultBytes(fiber: *Fiber, len: usize) []u8 {
        return fiber.buffer[fiber.result_offset..][0..len];
    }

    fn checkCancel(fiber: *Fiber) Io.Cancelable!void {
        if (fiber.protection == .blocked) return;
        if (fiber.cancel == .requested) {
            fiber.cancel = .acknowledged;
            return error.Canceled;
        }
    }

    /// Body of every fiber. A fiber is reused for one task after another: after a task, it
    /// switches back to the loop, and resumes here once it is given a new task.
    fn main(fiber: *Fiber) noreturn {
        while (true) {
            switch (fiber.kind) {
                .future => fiber.start_future.?(fiber.contextPointer(), fiber.buffer[fiber.result_offset..].ptr),
                .group => fiber.start_group.?(fiber.contextPointer()),
                .detached => fiber.detached_start.?(fiber.detached_arg.?),
            }
            fiber.state = .finished;
            fiber.lio.yieldToMain(fiber);
        }
    }

    fn windowsEntry(param: ?*anyopaque) callconv(.winapi) void {
        main(@ptrCast(@alignCast(param.?)));
    }

    /// The first switch to a new fiber jumps to `posixEntry` with the stack pointer just
    /// below a slot holding the fiber's address (the same layout std's evented Io uses).
    fn initialContext(stack: []align(std.heap.page_size_min) u8, fiber: *Fiber) Io.fiber.Context {
        const top = @intFromPtr(stack.ptr) + stack.len;
        const slot = std.mem.alignBackward(usize, top - 2 * @sizeOf(usize), 16);
        @as(**Fiber, @ptrFromInt(slot)).* = fiber;
        return switch (builtin.cpu.arch) {
            .x86_64 => blk: {
                // Fake return address slot, so the entry sees the usual call-site alignment.
                @as(*usize, @ptrFromInt(slot - 8)).* = 0;
                break :blk .{ .rsp = slot - 8, .rbp = 0, .rip = @intFromPtr(&posixEntry) };
            },
            .aarch64, .riscv64 => .{ .sp = slot, .fp = 0, .pc = @intFromPtr(&posixEntry) },
            else => |arch| @compileError("unsupported architecture: " ++ @tagName(arch)),
        };
    }

    fn posixEntry() callconv(.naked) void {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (
                \\ mov x0, sp
                \\ b %[call]
                :
                : [call] "X" (&posixCall),
            ),
            .riscv64 => asm volatile (
                \\ mv a0, sp
                \\ tail %[call]@plt
                :
                : [call] "X" (&posixCall),
            ),
            .x86_64 => asm volatile (
                \\ leaq 8(%%rsp), %%rdi
                \\ jmp %[call:P]
                :
                : [call] "X" (&posixCall),
            ),
            else => |arch| @compileError("unsupported architecture: " ++ @tagName(arch)),
        }
    }

    fn posixCall(slot: *const *Fiber) callconv(.withStackAlign(.c, 16)) noreturn {
        main(slot.*);
    }

    fn protectGuardPage(stack: []align(std.heap.page_size_min) u8) void {
        // The stack grows down: an overflow hits the lowest page and faults instead of
        // corrupting whatever memory comes before the stack.
        if (builtin.link_libc) {
            _ = std.c.mprotect(@ptrCast(stack.ptr), std.heap.pageSize(), .{});
        } else if (builtin.os.tag == .linux) {
            _ = std.os.linux.mprotect(stack.ptr, std.heap.pageSize(), .{});
        }
    }
};

const win = struct {
    const FIBER_FLAG_FLOAT_SWITCH: u32 = 0x1;
    const StartRoutine = *const fn (?*anyopaque) callconv(.winapi) void;

    extern "kernel32" fn CreateFiberEx(commit_size: usize, reserve_size: usize, flags: u32, start: StartRoutine, parameter: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn ConvertThreadToFiberEx(parameter: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) c_int;
    extern "kernel32" fn IsThreadAFiber() callconv(.winapi) c_int;

    fn getCurrentFiber() *anyopaque {
        return std.os.windows.teb().NtTib.DUMMYUNIONNAME.FiberData;
    }
};

// -------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Runs `func(io)` as a task on a fresh loop, and returns once the loop has stopped.
fn runOnLoop(comptime func: fn (Io) anyerror!void) !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = gpa.deinit();

    var loop: uv.uv_loop_t = undefined;
    try testing.expectEqual(@as(c_int, 0), uv.uv_loop_init(&loop));

    var lio: Libuv = undefined;
    try lio.init(gpa.allocator(), &loop, .{});

    const Root = struct {
        lio: *Libuv,
        result: anyerror!void = {},
        finished: bool = false,

        fn start(arg: *anyopaque) void {
            const root: *@This() = @ptrCast(@alignCast(arg));
            root.result = func(root.lio.io());
        }

        fn finish(arg: *anyopaque) void {
            const root: *@This() = @ptrCast(@alignCast(arg));
            root.finished = true;
        }
    };
    var root: Root = .{ .lio = &lio };
    _ = try lio.spawnDetached(Root.start, Root.finish, &root);
    _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);

    lio.deinit();
    uv.uv_walk(&loop, struct {
        fn cb(handle: [*c]uv.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
            if (uv.uv_is_closing(handle) == 0) uv.uv_close(handle, null);
        }
    }.cb, null);
    _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);
    try testing.expectEqual(@as(c_int, 0), uv.uv_loop_close(&loop));

    try testing.expect(root.finished);
    return root.result;
}

fn sleepMs(io: Io, ms: i64) Io.Cancelable!void {
    return Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io);
}

fn elapsedMs(io: Io, since: Io.Clock.Timestamp) i64 {
    return since.untilNow(io).raw.toMilliseconds();
}

test "natively implemented functions are the ones in the vtable" {
    // `@hasDecl` only sees `pub` declarations: a native function that is not `pub` would
    // silently be forwarded to the fallback instead.
    inline for (@typeInfo(Libuv.native).@"struct".decl_names) |name| {
        try testing.expect(@field(Libuv.vtable, name) == &@field(Libuv.native, name));
    }
    try testing.expect(Libuv.vtable.async == &Libuv.native.async);
    try testing.expect(Libuv.vtable.futexWait == &Libuv.native.futexWait);
}

test "async tasks run concurrently and await returns their results" {
    try runOnLoop(struct {
        fn double(io: Io, x: u32) Io.Cancelable!u32 {
            try sleepMs(io, 100);
            return x * 2;
        }

        fn run(io: Io) anyerror!void {
            const start = Io.Clock.Timestamp.now(io, .awake);
            var a = io.async(double, .{ io, 1 });
            var b = io.async(double, .{ io, 20 });
            var c = try io.concurrent(double, .{ io, 300 });
            try testing.expectEqual(@as(u32, 2), try a.await(io));
            try testing.expectEqual(@as(u32, 40), try b.await(io));
            try testing.expectEqual(@as(u32, 600), try c.await(io));
            // The three sleeps overlap: well under the 300 ms they would take one after another.
            try testing.expect(elapsedMs(io, start) < 250);
        }
    }.run);
}

test "canceling a future interrupts its wait" {
    try runOnLoop(struct {
        fn sleepLong(io: Io) Io.Cancelable!void {
            try sleepMs(io, 60_000);
        }

        fn run(io: Io) anyerror!void {
            const start = Io.Clock.Timestamp.now(io, .awake);
            var future = io.async(sleepLong, .{io});
            try sleepMs(io, 10);
            try testing.expectError(error.Canceled, future.cancel(io));
            try testing.expect(elapsedMs(io, start) < 1000);
        }
    }.run);
}

test "cancelation is reported once, can be re-armed, and respects protection" {
    try runOnLoop(struct {
        fn task(io: Io, saw_protected_sleep: *bool) Io.Cancelable!void {
            // Wait for the cancel request, protected: the sleep completes normally.
            {
                const old = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(old);
                sleepMs(io, 50) catch unreachable;
                saw_protected_sleep.* = true;
            }
            // The pending request fires at the next cancelation point, only once...
            if (io.checkCancel()) |_| return error.Canceled else |_| {}
            io.checkCancel() catch unreachable;
            // ...unless it is re-armed.
            io.recancel();
            sleepMs(io, 60_000) catch |err| return err;
            unreachable;
        }

        fn run(io: Io) anyerror!void {
            var saw_protected_sleep = false;
            const start = Io.Clock.Timestamp.now(io, .awake);
            var future = io.async(task, .{ io, &saw_protected_sleep });
            try sleepMs(io, 10);
            try testing.expectError(error.Canceled, future.cancel(io));
            try testing.expect(saw_protected_sleep);
            try testing.expect(elapsedMs(io, start) < 1000);
        }
    }.run);
}

test "group runs every task and await waits for all of them" {
    try runOnLoop(struct {
        fn add(io: Io, counter: *u32, delay: i64) Io.Cancelable!void {
            try sleepMs(io, delay);
            counter.* += 1;
        }

        fn run(io: Io) anyerror!void {
            var counter: u32 = 0;
            var group: Io.Group = .init;
            for (0..20) |i| group.async(io, add, .{ io, &counter, @as(i64, @intCast(i % 5)) * 10 });
            try group.await(io);
            try testing.expectEqual(@as(u32, 20), counter);
            try testing.expect(group.token.raw == null);
        }
    }.run);
}

test "group cancel interrupts every task" {
    try runOnLoop(struct {
        fn wait(io: Io, canceled: *u32) Io.Cancelable!void {
            sleepMs(io, 60_000) catch |err| {
                canceled.* += 1;
                return err;
            };
        }

        fn run(io: Io) anyerror!void {
            var canceled: u32 = 0;
            var group: Io.Group = .init;
            for (0..5) |_| try group.concurrent(io, wait, .{ io, &canceled });
            try sleepMs(io, 10);
            group.cancel(io);
            try testing.expectEqual(@as(u32, 5), canceled);
        }
    }.run);
}

test "queue and mutex work between tasks" {
    try runOnLoop(struct {
        fn produce(io: Io, queue: *Io.Queue(u32)) !void {
            for (1..101) |i| try queue.putOne(io, @intCast(i));
            queue.close(io);
        }

        fn consume(io: Io, queue: *Io.Queue(u32), mutex: *Io.Mutex, sum: *u64) !void {
            while (true) {
                const item = queue.getOne(io) catch |err| switch (err) {
                    error.Closed => return,
                    else => |e| return e,
                };
                try mutex.lock(io);
                defer mutex.unlock(io);
                const before = sum.*;
                // Wait while holding the lock: the other consumer has to wait for it.
                try sleepMs(io, 1);
                sum.* = before + item;
            }
        }

        fn run(io: Io) anyerror!void {
            var buffer: [4]u32 = undefined;
            var queue: Io.Queue(u32) = .init(&buffer);
            var mutex: Io.Mutex = .init;
            var sum: u64 = 0;
            var producer = io.async(produce, .{ io, &queue });
            var consumer1 = io.async(consume, .{ io, &queue, &mutex, &sum });
            var consumer2 = io.async(consume, .{ io, &queue, &mutex, &sum });
            try producer.await(io);
            try consumer1.await(io);
            try consumer2.await(io);
            try testing.expectEqual(@as(u64, 5050), sum);
        }
    }.run);
}

test "file operations are performed by the fallback Io" {
    try runOnLoop(struct {
        fn run(io: Io) anyerror!void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "Hello from a fiber" });
            const data = try tmp.dir.readFileAlloc(io, "hello.txt", testing.allocator, .limited(1024));
            defer testing.allocator.free(data);
            try testing.expectEqualStrings("Hello from a fiber", data);
        }
    }.run);
}

test "a blocking fallback operation does not block other tasks" {
    try runOnLoop(struct {
        fn acceptOne(io: Io, server: *Io.net.Server) !void {
            // Blocks a worker thread until the connection below arrives.
            const stream = try server.accept(io);
            stream.close(io);
        }

        fn run(io: Io) anyerror!void {
            const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
            var server = try address.listen(io, .{});
            defer server.deinit(io);

            var accepting = io.async(acceptOne, .{ io, &server });

            // Meanwhile, timers keep firing on time.
            const start = Io.Clock.Timestamp.now(io, .awake);
            for (0..10) |_| try sleepMs(io, 10);
            try testing.expect(elapsedMs(io, start) < 1000);

            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            stream.close(io);
            try accepting.await(io);
        }
    }.run);
}
