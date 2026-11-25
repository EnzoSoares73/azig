//! An `std.Io` implementation whose tasks run as fibers on a libuv event loop.
//!
//! Every task (`io.async`, `io.concurrent`, `Group.async`, ...) gets its own stack and runs on
//! the loop thread. When a task waits (`await`, `sleep`, a futex used by `Io.Mutex`,
//! `Io.Condition`, `Io.Queue`, ...), it switches back to the loop instead of blocking the
//! thread, so thousands of waiting tasks cost memory, not threads.
//!
//! How each kind of operation is performed:
//! - Tasks, groups, cancelation, futexes, sleeping: on the loop.
//! - TCP sockets (listen, accept, connect, read, write, close): on the loop, with `uv_tcp_t`.
//!   Waiting for a connection or for data costs no thread.
//! - DNS (`HostName.lookup`, and so `HostName.connect`): `uv_getaddrinfo`.
//! - Files and directories: on libuv's thread pool, like libuv's own `uv_fs_*` (which cannot
//!   be used directly: it takes C runtime descriptors on Windows, where std uses OS handles,
//!   and has no directory-relative operations). The operation itself is std's
//!   (`Io.Threaded`'s), so its behavior and errors are exactly std's.
//! - Everything else (UDP and Unix domain sockets, child processes, reading pipes and
//!   terminals, ...): on `Io.Threaded`'s pool, which grows as needed, so operations that may
//!   block indefinitely cannot use up libuv's small pool. Quick operations (clocks, random
//!   numbers, closing files) run directly.
//! In every case the task is suspended until the operation completes; the loop thread never
//! blocks.
//!
//! Rules:
//! - The `Io` must only be used from the tasks it runs (all of them run on the loop thread).
//! - Code that blocks the thread without going through the `Io` (a C library calling `recv`,
//!   `std.Thread.sleep`, a long CPU-bound loop) blocks the whole loop.
//! - Operations on a thread pool are not interrupted by cancelation once they have started
//!   (one still queued on libuv's pool is removed from the queue): a cancel request then
//!   takes effect at the task's next cancelation point. TCP reads, accepts and connects, DNS
//!   lookups that have not started, sleeps and waits are interrupted right away. TCP writes
//!   are not: libuv uses the caller's buffers until the write completes.
//! - libuv's thread pool has 4 threads unless the `UV_THREADPOOL_SIZE` environment variable
//!   says otherwise (read when the pool first starts; at most 1024). File operations and DNS
//!   lookups share it.
//!
//! Fibers use std's context switch (`std.Io.fiber`) on POSIX systems, and Win32 fibers on
//! Windows, where switching stacks also needs the thread information block to be updated.

const std = @import("std");
const builtin = @import("builtin");
const uv = @import("uv");
const Io = std.Io;
const net = Io.net;
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
    futex_buckets: [futex_bucket_count]WaitList = @splat(.{}),
    /// TCP sockets managed by libuv, by OS handle.
    sockets: std.AutoHashMapUnmanaged(usize, *TcpSocket) = .empty,

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

        // Sockets the application left open.
        var sockets = lio.sockets.valueIterator();
        while (sockets.next()) |s| {
            s.*.closing = true;
            uv.uv_close(@ptrCast(&s.*.tcp), TcpSocket.onClosed);
        }
        lio.sockets.deinit(lio.allocator);

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
    ///
    /// Tasks started from a libuv callback otherwise only run once the loop reaches its idle
    /// phase, in the next iteration. Callers that start a task on a hot path (one per
    /// request) call this right away so the task runs now instead.
    pub fn drain(lio: *Libuv) void {
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
        if (fiber.wait_list) |list| list.remove(fiber);
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

    fn futexBucket(lio: *Libuv, address: usize) *WaitList {
        return &lio.futex_buckets[(address >> 2) % futex_bucket_count];
    }

    fn futexWaitInner(lio: *Libuv, ptr: *const u32, expected: u32, timeout: Io.Timeout, cancelable: bool) Io.Cancelable!void {
        const fiber = lio.currentFiber();
        if (cancelable) try fiber.checkCancel();
        if (@atomicLoad(u32, ptr, .acquire) != expected) return;

        const duration: ?Io.Clock.Duration = timeout.toDurationFromNow(lio.io());
        if (duration) |d| {
            if (d.raw.toNanoseconds() <= 0) return;
        }

        fiber.futex_address = @intFromPtr(ptr);
        lio.futexBucket(fiber.futex_address).insert(fiber);
        if (duration) |d| startTimer(fiber, d.raw);
        switch (lio.suspendCurrent(.futex, cancelable)) {
            .normal, .timeout, .closed => {},
            .canceled => return error.Canceled,
        }
    }

    // ---------------------------------------------------------------------------------------
    // TCP sockets, on `uv_tcp_t`. std refers to sockets by their OS handle; `sockets` maps the
    // handles of the sockets created here to their libuv handle. Sockets that are not in the
    // map (UDP, Unix domain sockets) are left to the fallback.

    fn findSocket(lio: *Libuv, handle: net.Socket.Handle) ?*TcpSocket {
        return lio.sockets.get(socketKey(handle));
    }

    /// Returns null (with the libuv error in `status`) if the socket cannot be created.
    /// `family` is `AF_UNSPEC` for a socket that will be filled in by `uv_accept`.
    fn tcpCreate(lio: *Libuv, family: c_int, status: *c_int) ?*TcpSocket {
        const s = lio.allocator.create(TcpSocket) catch {
            status.* = uv.UV_ENOMEM;
            return null;
        };
        s.* = .{ .lio = lio, .allocator = lio.allocator };
        const r = uv.uv_tcp_init_ex(lio.loop, &s.tcp, @intCast(family));
        if (r != 0) {
            lio.allocator.destroy(s);
            status.* = r;
            return null;
        }
        s.tcp.data = s;
        return s;
    }

    /// Makes the socket known by its OS handle. Returns a libuv error code.
    fn tcpRegister(lio: *Libuv, s: *TcpSocket) c_int {
        var fd: uv.uv_os_fd_t = undefined;
        const r = uv.uv_fileno(@ptrCast(&s.tcp), &fd);
        if (r != 0) return r;
        s.os_handle = socketHandleFromUv(fd);
        lio.sockets.put(lio.allocator, socketKey(s.os_handle), s) catch return uv.UV_ENOMEM;
        s.registered = true;
        return 0;
    }

    /// Closes the socket. Fibers waiting on it wake up with `closed`; its memory is freed once
    /// libuv has finished closing it.
    fn tcpClose(lio: *Libuv, s: *TcpSocket) void {
        if (s.closing) return;
        s.closing = true;
        if (s.registered) _ = lio.sockets.remove(socketKey(s.os_handle));
        if (s.read_op) |op| {
            s.read_op = null;
            lio.wake(op.fiber, .closed);
        }
        while (s.accept_waiters.head) |fiber| lio.wake(fiber, .closed);
        uv.uv_close(@ptrCast(&s.tcp), TcpSocket.onClosed);
    }

    fn tcpRead(lio: *Libuv, s: *TcpSocket, o: Io.Operation.NetRead) Io.Cancelable!Io.Operation.NetRead.Result {
        const Result = Io.Operation.NetRead.Result;
        const fiber = lio.currentFiber();
        try fiber.checkCancel();
        const buffer = for (o.data) |b| {
            if (b.len > 0) break b;
        } else return .{ .data_len = 0 };
        assert(s.read_op == null); // one read at a time per socket

        // libuv asks for a buffer (onAlloc) only once data has arrived, on every platform, so
        // the caller's buffer is never used after the read is stopped.
        var op: TcpSocket.ReadOp = .{ .fiber = fiber, .buffer = buffer };
        s.read_op = &op;
        const r = uv.uv_read_start(s.stream(), TcpSocket.onAlloc, TcpSocket.onRead);
        if (r != 0) {
            s.read_op = null;
            return @as(Result, uvError(Io.Operation.NetRead.Error, r));
        }
        while (op.result == null) {
            switch (lio.suspendCurrent(.socket, true)) {
                .normal, .timeout => {},
                // The socket is gone: do not touch it.
                .closed => return @as(Result, error.SocketUnconnected),
                .canceled => {
                    if (op.result != null) {
                        fiber.cancel = .requested; // data arrived as well: report that first
                        break;
                    }
                    _ = uv.uv_read_stop(s.stream());
                    s.read_op = null;
                    return error.Canceled;
                },
            }
        }
        const n = op.result.?;
        if (n >= 0) return .{ .data_len = @intCast(n) };
        if (n == uv.UV_EOF) return .{ .data_len = 0 };
        return @as(Result, uvError(Io.Operation.NetRead.Error, @intCast(n)));
    }

    fn tcpWrite(lio: *Libuv, s: *TcpSocket, o: Io.Operation.NetWrite) Io.Cancelable!Io.Operation.NetWrite.Result {
        const Result = Io.Operation.NetWrite.Result;
        var bufs: [max_write_buffers]uv.uv_buf_t = undefined;
        var count: usize = 0;
        var total: usize = 0;
        const Add = struct {
            fn add(b: *[max_write_buffers]uv.uv_buf_t, c: *usize, t: *usize, bytes: []const u8) void {
                if (bytes.len == 0 or c.* == b.len) return;
                const len: c_uint = @intCast(@min(bytes.len, std.math.maxInt(c_uint)));
                b[c.*] = uv.uv_buf_init(@constCast(bytes.ptr), len);
                c.* += 1;
                t.* += len;
            }
        };
        Add.add(&bufs, &count, &total, o.header);
        if (o.data.len > 0) {
            for (o.data[0 .. o.data.len - 1]) |bytes| Add.add(&bufs, &count, &total, bytes);
            const last = o.data[o.data.len - 1];
            // Writing fewer bytes than asked is allowed: the caller writes the rest later.
            if (last.len > 0) for (0..o.splat) |_| {
                if (count == bufs.len) break;
                Add.add(&bufs, &count, &total, last);
            };
        }
        if (total == 0) return 0;

        // Most writes complete right away, without suspending.
        const tried = uv.uv_try_write(s.stream(), &bufs, @intCast(count));
        if (tried > 0) return @as(usize, @intCast(tried));
        if (tried < 0 and tried != uv.UV_EAGAIN and tried != uv.UV_ENOSYS) {
            return @as(Result, uvError(Io.Operation.NetWrite.Error, tried));
        }

        const fiber = lio.currentFiber();
        var op: TcpSocket.WriteOp = .{ .fiber = fiber };
        op.req.data = &op;
        const r = uv.uv_write(&op.req, s.stream(), &bufs, @intCast(count), TcpSocket.onWrite);
        if (r != 0) return @as(Result, uvError(Io.Operation.NetWrite.Error, r));
        // A write cannot be aborted (libuv uses the buffers until it completes), so this wait is
        // not a cancelation point. Closing the socket completes it with an error.
        while (op.status == null) _ = lio.suspendCurrent(.socket, false);
        if (op.status.? != 0) return @as(Result, uvError(Io.Operation.NetWrite.Error, op.status.?));
        return total;
    }

    fn lookup(
        lio: *Libuv,
        fiber: *Fiber,
        host_name: net.HostName,
        resolved: *Io.Queue(net.HostName.LookupResult),
        options: net.HostName.LookupOptions,
    ) (net.HostName.LookupError || Io.QueueClosedError)!void {
        try fiber.checkCancel();
        const io_ = lio.io();
        const name = host_name.bytes;
        assert(name.len <= net.HostName.max_len);

        var name_buffer: [net.HostName.max_len:0]u8 = undefined;
        @memcpy(name_buffer[0..name.len], name);
        name_buffer[name.len] = 0;
        var port_buffer: [8]u8 = undefined;
        const port = std.mem.printSentinel(&port_buffer, "{d}", .{options.port}, 0) catch unreachable;

        var hints: uv.struct_addrinfo = .{};
        hints.ai_flags = uv.AI_NUMERICSERV | @as(c_int, if (options.canonical_name_buffer != null) uv.AI_CANONNAME else 0);
        hints.ai_family = if (options.family) |family| switch (family) {
            .ip4 => uv.AF_INET,
            .ip6 => uv.AF_INET6,
        } else uv.AF_UNSPEC;
        hints.ai_socktype = uv.SOCK_STREAM;
        hints.ai_protocol = uv.IPPROTO_TCP;

        var op: LookupOp = .{ .fiber = fiber };
        op.req.data = &op;
        const r = uv.uv_getaddrinfo(lio.loop, &op.req, LookupOp.onResolved, &name_buffer, port.ptr, &hints);
        if (r != 0) return lookupError(r);

        // getaddrinfo runs on libuv's thread pool: a lookup that has not started yet can be
        // canceled; one in progress runs to completion.
        var cancel_tried = false;
        while (op.status == null) {
            if (lio.suspendCurrent(.dns, !cancel_tried) == .canceled) {
                cancel_tried = true;
                if (uv.uv_cancel(@ptrCast(&op.req)) != 0) fiber.cancel = .requested;
            }
        }
        if (op.status.? == uv.UV_ECANCELED) return error.Canceled;
        if (op.status.? != 0) return lookupError(op.status.?);
        defer uv.uv_freeaddrinfo(op.res);

        var canonical_name: ?[*:0]const u8 = null;
        var it: [*c]uv.struct_addrinfo = op.res;
        while (it != null) : (it = it.*.ai_next) {
            const info = it.*;
            if (info.ai_addr == null) continue;
            try resolved.putOne(io_, .{ .address = Io.Threaded.addressFromPosix(@ptrCast(@alignCast(info.ai_addr))) });
            if (canonical_name == null and info.ai_canonname != null) canonical_name = info.ai_canonname;
        }
        if (canonical_name) |canon| {
            if (options.canonical_name_buffer) |buffer| {
                const bytes = std.mem.sliceTo(canon, 0);
                const len = @min(bytes.len, buffer.len);
                @memcpy(buffer[0..len], bytes[0..len]);
                try resolved.putOne(io_, .{ .canonical_name = .{ .bytes = buffer[0..len] } });
            }
        }
    }

    fn lookupError(code: c_int) net.HostName.LookupError {
        return switch (code) {
            uv.UV_EAI_NONAME, uv.UV_EAI_NODATA => error.UnknownHostName,
            uv.UV_EAI_AGAIN, uv.UV_EAI_FAIL => error.NameServerFailure,
            uv.UV_EAI_FAMILY, uv.UV_EAI_ADDRFAMILY => error.AddressFamilyUnsupported,
            uv.UV_EAI_MEMORY, uv.UV_ENOMEM => error.SystemResources,
            else => error.Unexpected,
        };
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
            var node = lio.futexBucket(address).head;
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
                .normal, .timeout, .closed => {},
                .canceled => return error.Canceled,
            }
        }

        pub fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            switch (operation) {
                .net_read => |o| if (lio.findSocket(o.socket_handle)) |s| return .{ .net_read = try lio.tcpRead(s, o) },
                .net_write => |o| if (lio.findSocket(o.socket_handle)) |s| return .{ .net_write = try lio.tcpWrite(s, o) },
                else => {},
            }
            return Forward("operate").call(userdata, .{operation});
        }

        pub fn netListenIp(
            userdata: ?*anyopaque,
            address: *const net.IpAddress,
            options: net.IpAddress.ListenOptions,
        ) net.IpAddress.ListenError!net.Socket {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            if (options.mode != .stream or options.protocol != .tcp) {
                return Forward("netListenIp").call(userdata, .{ address, options });
            }
            lio.assertLoopThread();
            if (lio.current) |fiber| try fiber.checkCancel();

            var status: c_int = 0;
            const s = lio.tcpCreate(addressFamily(address), &status) orelse
                return uvError(net.IpAddress.ListenError, status);
            var storage: Io.Threaded.PosixAddress = undefined;
            // libuv always sets SO_REUSEADDR on POSIX systems; SO_REUSEPORT needs a flag.
            const flags: c_uint = if (options.reuse_address and builtin.os.tag == .linux) uv.UV_TCP_REUSEPORT else 0;
            var r = uv.uv_tcp_bind(&s.tcp, uvAddress(address, &storage), flags);
            if (r == 0) r = uv.uv_listen(s.stream(), @intCast(options.kernel_backlog), TcpSocket.onConnection);
            if (r == 0) r = lio.tcpRegister(s);
            if (r != 0) {
                lio.tcpClose(s);
                return uvError(net.IpAddress.ListenError, r);
            }
            return .{ .handle = s.os_handle, .address = s.localAddress() };
        }

        pub fn netAccept(
            userdata: ?*anyopaque,
            server: net.Socket.Handle,
            options: net.Server.AcceptOptions,
        ) net.Server.AcceptError!net.Socket {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const s = lio.findSocket(server) orelse return Forward("netAccept").call(userdata, .{ server, options });
            const fiber = lio.currentFiber();
            try fiber.checkCancel();

            while (true) {
                if (s.pending > 0) {
                    var status: c_int = 0;
                    const client = lio.tcpCreate(uv.AF_UNSPEC, &status) orelse
                        return uvError(net.Server.AcceptError, status);
                    const r = uv.uv_accept(s.stream(), client.stream());
                    if (r == uv.UV_EAGAIN) {
                        // The reported connection is gone (or was already taken).
                        s.pending = 0;
                        lio.tcpClose(client);
                        continue;
                    }
                    s.pending -= 1;
                    const registered = if (r == 0) lio.tcpRegister(client) else r;
                    if (registered != 0) {
                        lio.tcpClose(client);
                        return uvError(net.Server.AcceptError, registered);
                    }
                    return .{ .handle = client.os_handle, .address = client.peerAddress() };
                }
                if (s.listen_status != 0) {
                    const status = s.listen_status;
                    s.listen_status = 0;
                    return uvError(net.Server.AcceptError, status);
                }
                s.accept_waiters.insert(fiber);
                switch (lio.suspendCurrent(.socket, true)) {
                    .normal, .timeout => {},
                    .canceled => return error.Canceled,
                    // The listening socket was closed: do not touch it.
                    .closed => return error.SocketNotListening,
                }
            }
        }

        pub fn netConnectIp(
            userdata: ?*anyopaque,
            address: *const net.IpAddress,
            options: net.IpAddress.ConnectOptions,
        ) net.IpAddress.ConnectError!net.Socket {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            if (options.mode != .stream or (options.protocol orelse .tcp) != .tcp) {
                return Forward("netConnectIp").call(userdata, .{ address, options });
            }
            const fiber = lio.currentFiber();
            try fiber.checkCancel();

            var status: c_int = 0;
            const s = lio.tcpCreate(addressFamily(address), &status) orelse
                return uvError(net.IpAddress.ConnectError, status);
            var storage: Io.Threaded.PosixAddress = undefined;
            var op: TcpSocket.ConnectOp = .{ .fiber = fiber };
            op.req.data = &op;
            const r = uv.uv_tcp_connect(&op.req, &s.tcp, uvAddress(address, &storage), TcpSocket.onConnect);
            if (r != 0) {
                lio.tcpClose(s);
                return uvError(net.IpAddress.ConnectError, r);
            }
            if (options.timeout.toDurationFromNow(lio.io())) |d| startTimer(fiber, d.raw);

            // Canceling or timing out closes the socket; libuv then completes the request with
            // UV_ECANCELED. Until then `op` must stay alive, and afterwards `s` is gone.
            var interrupted: ?enum { canceled, timeout } = null;
            var closed = false;
            while (op.status == null) {
                switch (lio.suspendCurrent(.socket, interrupted == null)) {
                    .normal, .closed => continue,
                    .canceled => interrupted = .canceled,
                    .timeout => interrupted = .timeout,
                }
                if (op.status == null and !closed) {
                    lio.tcpClose(s);
                    closed = true;
                }
            }
            if (closed) {
                return switch (interrupted orelse .canceled) {
                    .canceled => error.Canceled,
                    .timeout => error.Timeout,
                };
            }
            // Connected (or failed) before the interruption could take effect.
            if (interrupted == .canceled) fiber.cancel = .requested;

            const registered = if (op.status.? == 0) lio.tcpRegister(s) else op.status.?;
            if (registered != 0) {
                lio.tcpClose(s);
                return uvError(net.IpAddress.ConnectError, registered);
            }
            return .{ .handle = s.os_handle, .address = address.* };
        }

        pub fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            for (sockets) |*socket| {
                if (lio.findSocket(socket.handle)) |s| {
                    lio.tcpClose(s);
                } else {
                    Forward("netClose").call(userdata, .{socket[0..1]});
                }
            }
        }

        pub fn netWriteFile(
            userdata: ?*anyopaque,
            handle: net.Socket.Handle,
            header: []const u8,
            file_reader: *Io.File.Reader,
            limit: Io.Limit,
        ) net.Stream.Writer.WriteFileError!usize {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            // No zero-copy path for libuv sockets: the writer falls back to reading the file and
            // writing what it read.
            if (lio.findSocket(handle) != null) return error.Unimplemented;
            return Forward("netWriteFile").call(userdata, .{ handle, header, file_reader, limit });
        }

        pub fn netLookup(
            userdata: ?*anyopaque,
            host_name: net.HostName,
            resolved: *Io.Queue(net.HostName.LookupResult),
            options: net.HostName.LookupOptions,
        ) net.HostName.LookupError!void {
            const lio: *Libuv = @ptrCast(@alignCast(userdata));
            const fiber = lio.current orelse return Forward("netLookup").call(userdata, .{ host_name, resolved, options });
            defer resolved.close(lio.io());
            lio.lookup(fiber, host_name, resolved, options) catch |err| switch (err) {
                error.Closed => unreachable, // `resolved` must not be closed until `netLookup` returns
                else => |e| return e,
            };
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
        "netClose",                "netShutdown",          "childKill",            "fileMemoryMapDestroy",
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

    const Backend = enum {
        /// Called directly: the operation never blocks for long.
        run_inline,
        /// File system operations, on libuv's thread pool (like libuv's own `uv_fs_*`).
        uv_pool,
        /// Operations that may block indefinitely (waiting for a child process, sockets that
        /// libuv does not manage, reading a pipe or terminal), on `Io.Threaded`'s pool, which
        /// grows as needed, so they cannot use up libuv's small pool.
        threaded,
    };

    fn backendOf(comptime name: []const u8) Backend {
        if (runsInline(name)) return .run_inline;
        if (std.mem.startsWith(u8, name, "dir") or std.mem.startsWith(u8, name, "file")) return .uv_pool;
        return .threaded;
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
        const backend = backendOf(name);
        const cancelable = canReturnCanceled(R);

        return struct {
            fn call(userdata: ?*anyopaque, args: anytype) R {
                const lio: *Libuv = @ptrCast(@alignCast(userdata));
                const fallback = lio.fallback.io();
                const target = @field(fallback.vtable, name);
                if (backend == .run_inline) return @call(.auto, target, .{fallback.userdata} ++ args);

                const fiber = lio.current orelse return @call(.auto, target, .{fallback.userdata} ++ args);
                if (cancelable) {
                    fiber.checkCancel() catch return error.Canceled;
                }

                if (backend == .uv_pool) return callOnUvPool(lio, fiber, args);

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

            /// Performs the operation on libuv's thread pool. While it is still queued, a
            /// cancel request removes it from the queue.
            fn callOnUvPool(lio: *Libuv, fiber: *Fiber, args: anytype) R {
                const Job = struct {
                    req: uv.uv_work_t = undefined,
                    lio: *Libuv,
                    fiber: *Fiber,
                    args: @TypeOf(args),
                    result: R = undefined,
                    status: ?c_int = null,

                    fn work(req: [*c]uv.uv_work_t) callconv(.c) void {
                        const job: *@This() = @alignCast(@fieldParentPtr("req", @as(*uv.uv_work_t, req)));
                        const fb = job.lio.fallback.io();
                        job.result = @call(.auto, @field(fb.vtable, name), .{fb.userdata} ++ job.args);
                    }

                    fn after(req: [*c]uv.uv_work_t, status: c_int) callconv(.c) void {
                        const job: *@This() = @alignCast(@fieldParentPtr("req", @as(*uv.uv_work_t, req)));
                        job.status = status;
                        job.lio.wake(job.fiber, .normal);
                        job.lio.drain();
                    }
                };
                var job: Job = .{ .lio = lio, .fiber = fiber, .args = args };
                if (uv.uv_queue_work(lio.loop, &job.req, Job.work, Job.after) != 0) {
                    const fallback = lio.fallback.io();
                    return @call(.auto, @field(fallback.vtable, name), .{fallback.userdata} ++ args);
                }

                var cancel_tried = false;
                while (job.status == null) {
                    if (lio.suspendCurrent(.offload, cancelable and !cancel_tried) == .canceled) {
                        cancel_tried = true;
                        // Succeeds only if no thread has picked the operation up yet. Otherwise it
                        // runs to completion and the request stays pending for the next
                        // cancelation point.
                        if (uv.uv_cancel(@ptrCast(&job.req)) != 0) fiber.cancel = .requested;
                    }
                }
                if (cancelable and job.status.? == uv.UV_ECANCELED) return error.Canceled;
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

/// Most buffers passed to one `uv_write`; a larger write is done in parts.
const max_write_buffers = 32;

/// A TCP socket managed by libuv (see `Libuv.findSocket`).
const TcpSocket = struct {
    lio: *Libuv,
    allocator: Allocator,
    tcp: uv.uv_tcp_t = undefined,
    os_handle: net.Socket.Handle = undefined,
    /// Whether `os_handle` is in `Libuv.sockets`.
    registered: bool = false,
    closing: bool = false,

    /// Listening sockets: connections libuv reported that have not been accepted yet.
    pending: u32 = 0,
    /// Listening sockets: an error libuv reported instead of a connection.
    listen_status: c_int = 0,
    accept_waiters: WaitList = .{},

    /// The read in progress, if any. Lives on the reading fiber's stack.
    read_op: ?*ReadOp = null,

    const ReadOp = struct { fiber: *Fiber, buffer: []u8, result: ?isize = null };
    const WriteOp = struct { req: uv.uv_write_t = undefined, fiber: *Fiber, status: ?c_int = null };
    const ConnectOp = struct { req: uv.uv_connect_t = undefined, fiber: *Fiber, status: ?c_int = null };

    fn stream(s: *TcpSocket) *uv.uv_stream_t {
        return @ptrCast(&s.tcp);
    }

    fn localAddress(s: *TcpSocket) net.IpAddress {
        var storage: uv.struct_sockaddr_storage = undefined;
        var len: c_int = @sizeOf(uv.struct_sockaddr_storage);
        if (uv.uv_tcp_getsockname(&s.tcp, @ptrCast(&storage), &len) != 0) return .{ .ip4 = .loopback(0) };
        return Io.Threaded.addressFromPosix(@ptrCast(@alignCast(&storage)));
    }

    fn peerAddress(s: *TcpSocket) net.IpAddress {
        var storage: uv.struct_sockaddr_storage = undefined;
        var len: c_int = @sizeOf(uv.struct_sockaddr_storage);
        if (uv.uv_tcp_getpeername(&s.tcp, @ptrCast(&storage), &len) != 0) return .{ .ip4 = .loopback(0) };
        return Io.Threaded.addressFromPosix(@ptrCast(@alignCast(&storage)));
    }

    fn onClosed(handle: [*c]uv.uv_handle_t) callconv(.c) void {
        const s: *TcpSocket = @ptrCast(@alignCast(handle.*.data));
        s.allocator.destroy(s);
    }

    fn onConnection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
        const s: *TcpSocket = @ptrCast(@alignCast(server.*.data));
        if (status < 0) s.listen_status = status else s.pending += 1;
        if (s.accept_waiters.oldest()) |fiber| s.lio.wake(fiber, .normal);
        s.lio.drain();
    }

    fn onConnect(req: [*c]uv.uv_connect_t, status: c_int) callconv(.c) void {
        const op: *ConnectOp = @ptrCast(@alignCast(req.*.data));
        op.status = status;
        op.fiber.lio.wake(op.fiber, .normal);
        op.fiber.lio.drain();
    }

    fn onAlloc(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
        const s: *TcpSocket = @ptrCast(@alignCast(handle.*.data));
        if (s.read_op) |op| {
            buf.* = uv.uv_buf_init(op.buffer.ptr, @intCast(@min(op.buffer.len, std.math.maxInt(c_uint))));
        } else {
            buf.* = uv.uv_buf_init(null, 0);
        }
    }

    fn onRead(handle: [*c]uv.uv_stream_t, nread: isize, _: [*c]const uv.uv_buf_t) callconv(.c) void {
        const s: *TcpSocket = @ptrCast(@alignCast(handle.*.data));
        if (nread == 0) return; // nothing read (EAGAIN)
        const op = s.read_op orelse return;
        s.read_op = null;
        _ = uv.uv_read_stop(handle);
        op.result = nread;
        s.lio.wake(op.fiber, .normal);
        s.lio.drain();
    }

    fn onWrite(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
        const op: *WriteOp = @ptrCast(@alignCast(req.*.data));
        op.status = status;
        op.fiber.lio.wake(op.fiber, .normal);
        op.fiber.lio.drain();
    }
};

const LookupOp = struct {
    req: uv.uv_getaddrinfo_t = undefined,
    fiber: *Fiber,
    status: ?c_int = null,
    res: [*c]uv.struct_addrinfo = null,

    fn onResolved(req: [*c]uv.uv_getaddrinfo_t, status: c_int, res: [*c]uv.struct_addrinfo) callconv(.c) void {
        const op: *LookupOp = @ptrCast(@alignCast(req.*.data));
        op.status = status;
        op.res = res;
        op.fiber.lio.wake(op.fiber, .normal);
        op.fiber.lio.drain();
    }
};

fn socketKey(handle: net.Socket.Handle) usize {
    return switch (@typeInfo(net.Socket.Handle)) {
        .pointer => @intFromPtr(handle),
        else => @intCast(handle),
    };
}

fn socketHandleFromUv(fd: uv.uv_os_fd_t) net.Socket.Handle {
    const raw = if (@typeInfo(@TypeOf(fd)) == .optional) fd.? else fd;
    return switch (@typeInfo(net.Socket.Handle)) {
        .pointer => @ptrCast(raw),
        else => @intCast(raw),
    };
}

fn uvAddress(address: *const net.IpAddress, storage: *Io.Threaded.PosixAddress) *const uv.struct_sockaddr {
    _ = Io.Threaded.addressToPosix(address, storage);
    return @ptrCast(storage);
}

fn addressFamily(address: *const net.IpAddress) c_int {
    return switch (address.*) {
        .ip4 => uv.AF_INET,
        .ip6 => uv.AF_INET6,
    };
}

/// Translates a libuv error code into the matching error of `E`, or `error.Unexpected`.
fn uvError(comptime E: type, code: c_int) E {
    const candidates: []const []const u8 = switch (code) {
        uv.UV_ECONNREFUSED => &.{"ConnectionRefused"},
        uv.UV_ECONNRESET, uv.UV_EPIPE => &.{"ConnectionResetByPeer"},
        uv.UV_ECONNABORTED => &.{ "ConnectionAborted", "ConnectionResetByPeer" },
        uv.UV_ETIMEDOUT => &.{ "ConnectionTimedOut", "Timeout" },
        uv.UV_ENETUNREACH => &.{"NetworkUnreachable"},
        uv.UV_EHOSTUNREACH => &.{"HostUnreachable"},
        uv.UV_ENETDOWN => &.{"NetworkDown"},
        uv.UV_EADDRINUSE => &.{"AddressInUse"},
        uv.UV_EADDRNOTAVAIL => &.{"AddressUnavailable"},
        uv.UV_EAFNOSUPPORT => &.{"AddressFamilyUnsupported"},
        uv.UV_EACCES, uv.UV_EPERM => &.{"AccessDenied"},
        uv.UV_EMFILE => &.{"ProcessFdQuotaExceeded"},
        uv.UV_ENFILE => &.{"SystemFdQuotaExceeded"},
        uv.UV_ENOMEM, uv.UV_ENOBUFS => &.{"SystemResources"},
        uv.UV_ENOTCONN, uv.UV_ECANCELED => &.{ "SocketUnconnected", "SocketNotListening" },
        uv.UV_EPROTONOSUPPORT => &.{"ProtocolUnsupportedBySystem"},
        uv.UV_EAGAIN => &.{"WouldBlock"},
        else => &.{},
    };
    const names = @typeInfo(E).error_set.error_names.?;
    for (candidates) |candidate| {
        inline for (names) |name| {
            if (std.mem.eql(u8, name, candidate)) return @field(E, name);
        }
    }
    return error.Unexpected;
}

/// An intrusive list of waiting fibers, from which `wake` removes a fiber.
const WaitList = struct {
    head: ?*Fiber = null,

    fn insert(list: *WaitList, fiber: *Fiber) void {
        assert(fiber.wait_list == null);
        fiber.wait_list = list;
        fiber.wait_prev = null;
        fiber.wait_next = list.head;
        if (list.head) |head| head.wait_prev = fiber;
        list.head = fiber;
    }

    fn remove(list: *WaitList, fiber: *Fiber) void {
        assert(fiber.wait_list == list);
        if (fiber.wait_prev) |prev| prev.wait_next = fiber.wait_next else list.head = fiber.wait_next;
        if (fiber.wait_next) |next| next.wait_prev = fiber.wait_prev;
        fiber.wait_prev = null;
        fiber.wait_next = null;
        fiber.wait_list = null;
    }

    /// The fiber that has waited longest.
    fn oldest(list: *WaitList) ?*Fiber {
        var node = list.head orelse return null;
        while (node.wait_next) |next| node = next;
        return node;
    }
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
    /// The list the fiber is waiting in (a futex bucket, a socket's accept queue), if any.
    wait_list: ?*WaitList = null,
    wait_prev: ?*Fiber = null,
    wait_next: ?*Fiber = null,

    /// Ready queue or idle list.
    next: ?*Fiber = null,
    /// Completion stack filled by worker threads.
    remote_next: ?*Fiber = null,

    const State = enum { idle, ready, running, waiting, finished };
    const Kind = enum { future, group, detached };
    const CancelStatus = enum { none, requested, acknowledged };
    const Wait = enum { none, futex, sleep, await, group_await, offload, socket, dns };
    /// `closed`: the socket the fiber was waiting on was closed.
    const Woke = enum { normal, timeout, canceled, closed };

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

fn listenLocal(io: Io) !net.Server {
    const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
    return address.listen(io, .{});
}

test "TCP sockets are managed by libuv" {
    try runOnLoop(struct {
        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
            defer server.deinit(io);
            const lio: *Libuv = @ptrCast(@alignCast(io.userdata));
            try testing.expect(lio.findSocket(server.socket.handle) != null);
            try testing.expect(server.socket.address.getPort() != 0);

            const client = try server.socket.address.connect(io, .{ .mode = .stream });
            const accepted = try server.accept(io);
            try testing.expect(lio.findSocket(client.socket.handle) != null);
            try testing.expect(lio.findSocket(accepted.socket.handle) != null);
            client.close(io);
            accepted.close(io);
            try testing.expect(lio.findSocket(client.socket.handle) == null);
        }
    }.run);
}

test "TCP echo of a large payload between tasks" {
    try runOnLoop(struct {
        fn echo(io: Io, server: *net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            _ = try reader.interface.streamRemaining(&writer.interface);
            try writer.interface.flush();
        }

        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
            defer server.deinit(io);
            var echoing = io.async(echo, .{ io, &server });
            defer echoing.cancel(io) catch {};

            // Larger than the socket buffers, so writes have to wait for the peer to read.
            const payload = try testing.allocator.alloc(u8, 4 * 1024 * 1024);
            defer testing.allocator.free(payload);
            for (payload, 0..) |*byte, i| byte.* = @truncate(i *% 7);

            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);

            const Sender = struct {
                fn send(io_: Io, s: net.Stream, data: []const u8) !void {
                    var buffer: [8192]u8 = undefined;
                    var writer = s.writer(io_, &buffer);
                    try writer.interface.writeAll(data);
                    try writer.interface.flush();
                    try s.shutdown(io_, .send);
                }
            };
            var sending = io.async(Sender.send, .{ io, stream, payload });
            defer sending.cancel(io) catch {};

            var buffer: [8192]u8 = undefined;
            var reader = stream.reader(io, &buffer);
            const received = try reader.interface.allocRemaining(testing.allocator, .unlimited);
            defer testing.allocator.free(received);

            try sending.await(io);
            try echoing.await(io);
            try testing.expectEqualSlices(u8, payload, received);
        }
    }.run);
}

test "accept and read can be canceled, and the socket stays usable" {
    try runOnLoop(struct {
        fn acceptOne(io: Io, server: *net.Server) !net.Stream {
            return server.accept(io);
        }

        fn readSome(io: Io, stream: net.Stream, buffer: []u8) !usize {
            var bufs = [_][]u8{buffer};
            return stream.read(io, &bufs);
        }

        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
            defer server.deinit(io);

            var accepting = io.async(acceptOne, .{ io, &server });
            try sleepMs(io, 10);
            try testing.expectError(error.Canceled, accepting.cancel(io));

            const client = try server.socket.address.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const accepted = try server.accept(io);
            defer accepted.close(io);

            var buffer: [16]u8 = undefined;
            var reading = io.async(readSome, .{ io, accepted, &buffer });
            try sleepMs(io, 10);
            try testing.expectError(error.Canceled, reading.cancel(io));

            var writer = client.writer(io, &.{});
            try writer.interface.writeAll("ping");
            try testing.expectEqual(@as(usize, 4), try readSome(io, accepted, &buffer));
            try testing.expectEqualStrings("ping", buffer[0..4]);
        }
    }.run);
}

test "closing a socket wakes the task reading from it" {
    try runOnLoop(struct {
        fn readSome(io: Io, stream: net.Stream) !usize {
            var buffer: [16]u8 = undefined;
            var bufs = [_][]u8{&buffer};
            return stream.read(io, &bufs);
        }

        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
            defer server.deinit(io);
            const client = try server.socket.address.connect(io, .{ .mode = .stream });
            defer client.close(io);
            const accepted = try server.accept(io);

            var reading = io.async(readSome, .{ io, accepted });
            try sleepMs(io, 10);
            accepted.close(io);
            try testing.expectError(error.SocketUnconnected, reading.await(io));
        }
    }.run);
}

test "connecting to a port nobody listens on fails" {
    try runOnLoop(struct {
        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
            const address = server.socket.address;
            server.deinit(io);
            try testing.expectError(error.ConnectionRefused, address.connect(io, .{ .mode = .stream }));
        }
    }.run);
}

test "host names are resolved with libuv" {
    try runOnLoop(struct {
        fn run(io: Io) anyerror!void {
            const host = try net.HostName.init("localhost");
            var buffer: [16]net.HostName.LookupResult = undefined;
            var results: Io.Queue(net.HostName.LookupResult) = .init(&buffer);
            try host.lookup(io, &results, .{ .port = 80, .family = .ip4 });

            var addresses: usize = 0;
            while (results.getOne(io)) |result| switch (result) {
                .address => |address| {
                    addresses += 1;
                    try testing.expectEqual(@as(u16, 80), address.getPort());
                    try testing.expectEqual([4]u8{ 127, 0, 0, 1 }, address.ip4.bytes);
                },
                .canonical_name => {},
            } else |err| try testing.expectEqual(error.Closed, err);
            try testing.expect(addresses > 0);

            try testing.expectError(error.UnknownHostName, (try net.HostName.init("does-not-exist.invalid")).lookup(io, &results, .{ .port = 80 }));
        }
    }.run);
}

test "connecting by host name goes through lookup and connect" {
    try runOnLoop(struct {
        fn run(io: Io) anyerror!void {
            const address = try net.IpAddress.parseIp4("127.0.0.1", 0);
            var server = try address.listen(io, .{});
            defer server.deinit(io);
            const host = try net.HostName.init("localhost");
            const stream = try host.connect(io, server.socket.address.getPort(), .{ .mode = .stream });
            defer stream.close(io);
            const accepted = try server.accept(io);
            accepted.close(io);
        }
    }.run);
}

test "waiting for a connection does not block other tasks" {
    try runOnLoop(struct {
        fn acceptOne(io: Io, server: *net.Server) !void {
            const stream = try server.accept(io);
            stream.close(io);
        }

        fn run(io: Io) anyerror!void {
            var server = try listenLocal(io);
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

test "a blocking fallback operation (UDP) does not block other tasks" {
    try runOnLoop(struct {
        fn receiveOne(io: Io, socket: *const net.Socket, buffer: []u8) ![]u8 {
            // UDP sockets are not managed by libuv: this blocks a worker thread.
            const message = try socket.receive(io, buffer);
            return message.data;
        }

        fn run(io: Io) anyerror!void {
            const local = try net.IpAddress.parseIp4("127.0.0.1", 0);
            const receiver = try local.bind(io, .{ .mode = .dgram });
            defer receiver.close(io);
            const sender = try local.bind(io, .{ .mode = .dgram });
            defer sender.close(io);

            var buffer: [64]u8 = undefined;
            var receiving = io.async(receiveOne, .{ io, &receiver, &buffer });

            const start = Io.Clock.Timestamp.now(io, .awake);
            for (0..10) |_| try sleepMs(io, 10);
            try testing.expect(elapsedMs(io, start) < 1000);

            try sender.send(io, &receiver.address, "datagram");
            try testing.expectEqualStrings("datagram", try receiving.await(io));
        }
    }.run);
}
