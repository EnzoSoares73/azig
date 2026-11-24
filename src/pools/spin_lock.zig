const std = @import("std");

/// A small lock for very short critical sections (pushing to or popping from a free list,
/// setting a flag). Unlike `std.Io.Mutex` it needs no `Io` instance, so it can be used
/// from libuv callbacks and thread-pool workers.
///
/// It spins briefly and then yields the thread, so a holder that gets preempted does not
/// make the waiters burn a whole time slice.
pub const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub const init: SpinLock = .{};

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (!self.state.tryLock()) {
            if (spins < 128) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

test "SpinLock provides mutual exclusion" {
    const Shared = struct {
        lock: SpinLock = .init,
        counter: usize = 0,

        fn work(shared: *@This()) void {
            for (0..10_000) |_| {
                shared.lock.lock();
                defer shared.lock.unlock();
                shared.counter += 1;
            }
        }
    };

    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 40_000), shared.counter);
}
