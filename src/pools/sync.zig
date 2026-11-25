const std = @import("std");

/// The `Io` used by the locks (`std.Io.Mutex`) that guard state shared between threads: the
/// pools, and the server's stop signalling, which `stop()` reaches from any thread.
///
/// Those locks are taken from threads that are not tasks of any particular `Io` (the event
/// loop's own context, the thread calling `stop()`), so they need an `Io` whose futex works
/// from every thread. `Io.Threaded`'s futex is the operating system's, so its global instance
/// does; locking only ever uses its futex, never its thread pool.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "std.Io.Mutex with this Io provides mutual exclusion between threads" {
    const Shared = struct {
        mutex: std.Io.Mutex = .init,
        counter: usize = 0,

        fn work(shared: *@This()) void {
            for (0..10_000) |_| {
                shared.mutex.lockUncancelable(io());
                defer shared.mutex.unlock(io());
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
