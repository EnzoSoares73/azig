const std = @import("std");
const Options = std.heap.MemoryPoolOptions;
const Mutex = std.Thread.Mutex;

pub const MemoryPoolError = error{OutOfMemory};

pub fn ThreadSafeMemoryPool(comptime Item: type, comptime pool_options: Options) type {
    return struct {
        const Pool = @This();

        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));

        const node_alignment = @alignOf(*anyopaque);

        pub const item_alignment = @max(node_alignment, pool_options.alignment orelse @alignOf(Item));

        const Node = struct {
            next: ?*align(item_alignment) @This(),
        };
        const NodePtr = *align(item_alignment) Node;
        const ItemPtr = *align(item_alignment) Item;

        arena: std.heap.ArenaAllocator,
        free_list: ?NodePtr = null,
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator) Pool {
            return Pool{ .arena = std.heap.ArenaAllocator.init(allocator), .mutex = Mutex{} };
        }

        pub fn initPreheated(allocator: std.mem.Allocator, initial_size: usize) MemoryPoolError!Pool {
            var pool = init(allocator);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        pub fn deinit(pool: *Pool) void {
            pool.arena.deinit();
            pool.* = undefined;
        }

        pub fn preheat(pool: *Pool, size: usize) MemoryPoolError!void {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const raw_mem = try pool.allocNew();
                const free_node = @as(NodePtr, @ptrCast(raw_mem));
                free_node.* = Node{
                    .next = pool.free_list,
                };
                pool.free_list = free_node;
            }
        }

        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// Resets the memory pool and destroys all allocated items.
        /// This can be used to batch-destroy all objects without invalidating the memory pool.
        ///
        /// The function will return whether the reset operation was successful or not.
        /// If the reallocation  failed `false` is returned. The pool will still be fully
        /// functional in that case, all memory is released. Future allocations just might
        /// be slower.
        ///
        /// NOTE: If `mode` is `free_all`, the function will always return `true`.
        pub fn reset(pool: *Pool, mode: ResetMode) bool {
            const reset_successful = pool.arena.reset(mode);

            pool.free_list = null;

            return reset_successful;
        }

        pub fn create(pool: *Pool) !ItemPtr {
            pool.*.mutex.lock();
            defer pool.*.mutex.unlock();

            const node = if (pool.free_list) |item| blk: {
                pool.free_list = item.next;
                break :blk item;
            } else if (pool_options.growable)
                @as(NodePtr, @ptrCast(try pool.allocNew()))
            else
                return error.OutOfMemory;

            const ptr = @as(ItemPtr, @ptrCast(node));
            ptr.* = undefined;
            return ptr;
        }

        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            pool.*.mutex.lock();
            defer pool.*.mutex.unlock();
            ptr.* = undefined;

            const node = @as(NodePtr, @ptrCast(ptr));

            node.* = Node{
                .next = pool.free_list,
            };
            pool.free_list = node;
        }

        fn allocNew(pool: *Pool) MemoryPoolError!*align(item_alignment) [item_size]u8 {
            const mem = try pool.arena.allocator().alignedAlloc(u8, item_alignment, item_size);
            return mem[0..item_size];
        }
    };
}
