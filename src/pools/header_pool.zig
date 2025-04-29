const std = @import("std");
const StringHashMap = std.StringHashMap;
const Mutex = std.Thread.Mutex;

pub const Options = struct {
    growable: bool = true,
};

pub const MemoryPoolError = error{OutOfMemory};

pub fn HeaderPool(comptime options: Options) type {
    const MapType = StringHashMap([]const u8);

    return struct {
        arena: std.heap.ArenaAllocator,
        free_list: ?*Node = null,
        mutex: std.Thread.Mutex,

        const Self = @This();

        const Node = struct {
            next: ?*Node,
            data: *MapType,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .arena = std.heap.ArenaAllocator.init(allocator), .mutex = Mutex{} };
        }

        pub fn initPreheated(allocator: std.mem.Allocator, initial_size: usize) MemoryPoolError!Self {
            var pool = init(allocator);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        pub fn preheat(self: *Self, size: usize) MemoryPoolError!void {
            const allocator = self.arena.allocator();
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const map_ptr = try self.allocNew();
                const free_node = try allocator.create(Node);
                free_node.* = .{
                    .data = map_ptr,
                    .next = self.free_list,
                };
                self.free_list = free_node;
            }
        }

        fn allocNew(self: *Self) MemoryPoolError!*MapType {
            const allocator = self.*.arena.allocator();
            const map_ptr = try allocator.create(MapType);
            map_ptr.* = MapType.init(allocator);
            try map_ptr.*.ensureTotalCapacity(3);
            return map_ptr;
        }

        pub fn create(self: *Self) !*MapType {
            self.*.mutex.lock();
            defer self.*.mutex.unlock();

            if (self.*.free_list) |first_item| {
                const map_ptr = first_item.data;
                const node_to_free = self.*.free_list.?;
                self.*.free_list = first_item.next;

                self.*.arena.allocator().destroy(node_to_free);

                return map_ptr;
            } else if (options.growable) {
                return try self.*.allocNew();
            } else {
                return MemoryPoolError.OutOfMemory;
            }
        }

        pub fn destroy(self: *Self, map_ptr: *MapType) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            map_ptr.*.clearRetainingCapacity();

            const allocator = self.arena.allocator();
            const free_node = try allocator.create(Node);
            free_node.* = .{
                .data = map_ptr,
                .next = self.free_list,
            };
            self.free_list = free_node;
        }

        pub fn deinit(self: *Self) void {
            self.*.arena.deinit();
            self.* = undefined;
        }
    };
}
