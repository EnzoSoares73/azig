const std = @import("std");
const Options = std.heap.memory_pool.Options;
const Mutex = @import("spin_lock.zig").SpinLock;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const MemoryPoolError = error{OutOfMemory};

pub fn ThreadSafeMemoryPool(comptime Item: type, comptime pool_options: Options) type {
    if (pool_options.alignment) |a| {
        if (a.compare(.eq, .of(Item))) {
            var new_options = pool_options;
            new_options.alignment = null;
            return ThreadSafeMemoryPool(Item, new_options);
        }
    }
    return struct {
        const Pool = @This();

        arena: std.heap.ArenaAllocator,
        free_list: std.SinglyLinkedList,
        mutex: Mutex,

        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));

        pub const item_alignment: Alignment = .max(pool_options.alignment orelse .of(Item), .of(Node));

        const Node = std.SinglyLinkedList.Node;
        const ItemPtr = *align(item_alignment.toByteUnits()) Item;

        pub fn init(allocator: Allocator) Allocator.Error!Pool {
            return Pool{ .arena = std.heap.ArenaAllocator.init(allocator), .mutex = Mutex{}, .free_list = .{} };
        }

        pub fn initPreheated(allocator: Allocator, initial_size: usize) MemoryPoolError!Pool {
            var pool = try init(allocator);
            errdefer pool.deinit();
            try pool.preheat(initial_size);
            return pool;
        }

        pub fn deinit(pool: *Pool) void {
            pool.arena.deinit();
            pool.* = undefined;
        }

        pub fn preheat(pool: *Pool, num: usize) Allocator.Error!void {
            var i: usize = 0;
            while (i < num) : (i += 1) {
                const memory = try pool.allocNew();
                pool.free_list.prepend(@ptrCast(memory));
            }
        }

        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        pub fn reset(pool: *Pool, mode: ResetMode) bool {
            const reset_successful = pool.arena.reset(mode);
            pool.free_list = .{};

            return reset_successful;
        }

        pub fn create(pool: *Pool) Allocator.Error!ItemPtr {
            pool.*.mutex.lock();
            defer pool.*.mutex.unlock();

            const ptr: ItemPtr = if (pool.free_list.popFirst()) |node|
                @ptrCast(@alignCast(node))
            else if (pool_options.growable)
                @ptrCast(try pool.allocNew())
            else
                return error.OutOfMemory;

            ptr.* = undefined;
            return ptr;
        }

        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            pool.*.mutex.lock();
            defer pool.*.mutex.unlock();

            ptr.* = undefined;
            pool.free_list.prepend(@ptrCast(ptr));
        }

        fn allocNew(pool: *Pool) Allocator.Error!*align(item_alignment.toByteUnits()) [item_size]u8 {
            const memory = try pool.*.arena.allocator().alignedAlloc(u8, item_alignment, item_size);
            return memory[0..item_size];
        }
    };
}
