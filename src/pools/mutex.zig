const std = @import("std");
const uv = @import("uv");

/// A mutex backed by libuv's `uv_mutex_t` (a pthread mutex on Unix, a critical section on
/// Windows). Unlike `std.Io.Mutex` it needs no `Io` instance, so it can be used from libuv
/// callbacks and thread-pool workers.
///
/// A `uv_mutex_t` must not be moved after it is initialized, so it lives on the heap and this
/// struct only holds a pointer to it: owners can be returned by value and copied freely.
/// Every copy refers to the same mutex, and `deinit` must be called exactly once.
pub const Mutex = struct {
    handle: *uv.uv_mutex_t,

    pub const InitError = error{ OutOfMemory, MutexInitFailed };

    pub fn init(allocator: std.mem.Allocator) InitError!Mutex {
        const handle = try allocator.create(uv.uv_mutex_t);
        errdefer allocator.destroy(handle);
        if (uv.uv_mutex_init(handle) != 0) return error.MutexInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: Mutex, allocator: std.mem.Allocator) void {
        uv.uv_mutex_destroy(self.handle);
        allocator.destroy(self.handle);
    }

    pub fn lock(self: Mutex) void {
        uv.uv_mutex_lock(self.handle);
    }

    pub fn unlock(self: Mutex) void {
        uv.uv_mutex_unlock(self.handle);
    }
};

test "Mutex provides mutual exclusion" {
    const Shared = struct {
        mutex: Mutex,
        counter: usize = 0,

        fn work(shared: *@This()) void {
            for (0..10_000) |_| {
                shared.mutex.lock();
                defer shared.mutex.unlock();
                shared.counter += 1;
            }
        }
    };

    var shared: Shared = .{ .mutex = try Mutex.init(std.testing.allocator) };
    defer shared.mutex.deinit(std.testing.allocator);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 40_000), shared.counter);
}
