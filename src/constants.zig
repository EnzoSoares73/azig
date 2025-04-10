const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;
const mem = std.mem;

pub const DEFAULT_PORT: u16 = 2500;

pub const callback_t = * const fn (mem.Allocator, *Request, *Response) anyerror!void;

pub const suggested_buffer_size: usize = 65536;
pub const actual_buffer_size = suggested_buffer_size + @sizeOf(usize);

pub const buffer_pool_t = MemoryPoolExtra([suggested_buffer_size]u8, .{
    .growable = true,
});