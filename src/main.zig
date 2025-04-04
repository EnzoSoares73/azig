const std = @import("std");
const libuv_execute = @import("libuv.zig").libuv_execute;
const print = std.debug.print;
const mem = std.mem;
const net = std.net;
const StringHashMap = std.StringHashMap;

pub fn main() !void {
    try libuv_execute();
}