const std = @import("std");

pub const HeaderPool = struct {
    arena: std.heap.ArenaAllocator,
    free_list: ?NodePtr = null,

    const Self = @This();

    const Node = struct {
        next: ?*Self,
    };
};
