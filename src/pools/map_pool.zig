const std = @import("std");
const Mutex = @import("spin_lock.zig").SpinLock;

pub const Options = struct {
    growable: bool = true,
    /// Maps whose capacity grew past this are shrunk back when returned to the pool,
    /// so a single request with many headers does not pin that memory forever.
    max_retained_capacity: u32 = 64,
};

pub const MemoryPoolError = error{OutOfMemory};

/// A thread-safe pool of `StringHashMap([]const u8)`.
///
/// The free list is intrusive (each map lives inside an `Entry` that carries its own
/// links), so `create` and `destroy` never allocate and `destroy` cannot fail.
///
/// The maps' storage is allocated from the backing allocator by whichever thread
/// inserts into them, so the backing allocator must be thread-safe when the maps
/// are used from several threads (as the server does).
pub fn MapPool(comptime options: Options) type {
    const MapType = std.StringHashMap([]const u8);

    return struct {
        allocator: std.mem.Allocator,
        /// Maps that are available to be handed out.
        free_list: ?*Entry = null,
        /// Every map ever allocated by the pool, so that `deinit` can free maps
        /// that are still in use.
        all_list: ?*Entry = null,
        mutex: Mutex = .{},

        const Self = @This();

        const Entry = struct {
            map: MapType,
            next_free: ?*Entry,
            next_all: ?*Entry,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn initPreheated(allocator: std.mem.Allocator, initial_size: usize) MemoryPoolError!Self {
            var pool = init(allocator);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        pub fn preheat(self: *Self, size: usize) MemoryPoolError!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (0..size) |_| {
                const entry = try self.allocEntry();
                entry.next_free = self.free_list;
                self.free_list = entry;
            }
        }

        /// Caller must hold the mutex.
        fn allocEntry(self: *Self) MemoryPoolError!*Entry {
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);

            entry.* = .{
                .map = MapType.init(self.allocator),
                .next_free = null,
                .next_all = self.all_list,
            };
            try entry.map.ensureTotalCapacity(3);

            self.all_list = entry;
            return entry;
        }

        pub fn create(self: *Self) MemoryPoolError!*MapType {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.free_list) |entry| {
                self.free_list = entry.next_free;
                entry.next_free = null;
                return &entry.map;
            }

            if (!options.growable) {
                return MemoryPoolError.OutOfMemory;
            }

            const entry = try self.allocEntry();
            return &entry.map;
        }

        pub fn destroy(self: *Self, map_ptr: *MapType) void {
            // The caller owns the map until it is back on the free list,
            // so it can be cleared without holding the lock.
            if (map_ptr.capacity() > options.max_retained_capacity) {
                map_ptr.clearAndFree();
            } else {
                map_ptr.clearRetainingCapacity();
            }

            const entry: *Entry = @fieldParentPtr("map", map_ptr);

            self.mutex.lock();
            defer self.mutex.unlock();

            entry.next_free = self.free_list;
            self.free_list = entry;
        }

        pub fn deinit(self: *Self) void {
            var it = self.all_list;
            while (it) |entry| {
                it = entry.next_all;
                entry.map.deinit();
                self.allocator.destroy(entry);
            }
            self.* = undefined;
        }
    };
}

const testing = std.testing;

test "MapPool reuses maps and does not allocate on destroy" {
    var pool = try MapPool(.{}).initPreheated(testing.allocator, 2);
    defer pool.deinit();

    const a = try pool.create();
    const b = try pool.create();
    try a.put("key", "value");

    pool.destroy(a);
    pool.destroy(b);

    // Destroyed maps come back cleared, and no new maps were allocated.
    const c = try pool.create();
    const d = try pool.create();
    try testing.expect(c == b);
    try testing.expect(d == a);
    try testing.expectEqual(@as(usize, 0), d.count());

    pool.destroy(c);
    pool.destroy(d);
}

test "MapPool grows when empty and frees in-use maps on deinit" {
    var pool = MapPool(.{}).init(testing.allocator);
    defer pool.deinit();

    const a = try pool.create();
    try a.put("key", "value");
    // `a` is never destroyed: deinit must still free it (testing.allocator detects leaks).
}

test "MapPool shrinks maps that grew past max_retained_capacity" {
    var pool = MapPool(.{ .max_retained_capacity = 8 }).init(testing.allocator);
    defer pool.deinit();

    const map = try pool.create();
    const keys = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p" };
    for (keys) |key| try map.put(key, "v");
    try testing.expect(map.capacity() > 8);

    pool.destroy(map);
    try testing.expectEqual(@as(u32, 0), map.capacity());
}

test "MapPool non-growable returns OutOfMemory when empty" {
    var pool = try MapPool(.{ .growable = false }).initPreheated(testing.allocator, 1);
    defer pool.deinit();

    const a = try pool.create();
    try testing.expectError(MemoryPoolError.OutOfMemory, pool.create());
    pool.destroy(a);
}
