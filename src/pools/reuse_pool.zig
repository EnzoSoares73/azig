const std = @import("std");
const Allocator = std.mem.Allocator;

/// A pool of objects that keep their allocations between uses: `release` resets an object
/// instead of destroying it. `T` must provide `init(Allocator) T`, `reset(*T)` and
/// `deinit(*T)`. Not thread-safe.
pub fn ReusePool(comptime T: type) type {
    return struct {
        allocator: Allocator,
        free: ?*Node = null,
        /// Every node, so `deinit` also frees objects still in use.
        all: ?*Node = null,

        const Self = @This();

        const Node = struct {
            value: T,
            next_free: ?*Node,
            next_all: ?*Node,
        };

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn initPreheated(allocator: Allocator, count: usize) Allocator.Error!Self {
            var pool = init(allocator);
            errdefer pool.deinit();
            for (0..count) |_| {
                const node = try pool.newNode();
                node.next_free = pool.free;
                pool.free = node;
            }
            return pool;
        }

        pub fn deinit(self: *Self) void {
            var it = self.all;
            while (it) |node| {
                it = node.next_all;
                node.value.deinit();
                self.allocator.destroy(node);
            }
            self.* = undefined;
        }

        pub fn acquire(self: *Self) Allocator.Error!*T {
            if (self.free) |node| {
                self.free = node.next_free;
                return &node.value;
            }
            return &(try self.newNode()).value;
        }

        pub fn release(self: *Self, value: *T) void {
            value.reset();
            const node: *Node = @fieldParentPtr("value", value);
            node.next_free = self.free;
            self.free = node;
        }

        fn newNode(self: *Self) Allocator.Error!*Node {
            const node = try self.allocator.create(Node);
            node.* = .{ .value = T.init(self.allocator), .next_free = null, .next_all = self.all };
            self.all = node;
            return node;
        }
    };
}

const testing = std.testing;

test "released objects are reset and handed out again" {
    const Item = struct {
        list: std.ArrayList(u8) = .empty,
        allocator: Allocator,

        fn init(allocator: Allocator) @This() {
            return .{ .allocator = allocator };
        }
        fn reset(item: *@This()) void {
            item.list.clearRetainingCapacity();
        }
        fn deinit(item: *@This()) void {
            item.list.deinit(item.allocator);
        }
    };

    var pool = try ReusePool(Item).initPreheated(testing.allocator, 1);
    defer pool.deinit();

    const first = try pool.acquire();
    try first.list.appendSlice(first.allocator, "hello");
    const capacity = first.list.capacity;
    pool.release(first);

    const again = try pool.acquire();
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(usize, 0), again.list.items.len);
    try testing.expectEqual(capacity, again.list.capacity);

    // Not released: deinit frees it anyway.
    _ = try pool.acquire();
}
