const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const uv = @import("imports/libuv.zig");
const Context = @import("context.zig").Context;
const ThreadSafeMemoryPool = @import("thread_safe_memory_pool.zig").ThreadSafeMemoryPool;
const mem = std.mem;
const MemoryPoolExtra = std.heap.MemoryPoolExtra;

pub const DEFAULT_PORT: u16 = 2500;

pub const callback_t = * const fn (mem.Allocator, *Request, *Response) anyerror!void;

pub const suggested_buffer_size: usize = 65536;
pub const actual_buffer_size = suggested_buffer_size + @sizeOf(usize);

pub const buffer_pool_t = ThreadSafeMemoryPool([suggested_buffer_size]u8, .{
    .growable = true,
});

pub const request_pool_t = ThreadSafeMemoryPool(Request, .{
    .growable = true,
});

pub const response_pool_t = ThreadSafeMemoryPool(Response, .{
    .growable = true,
});

pub const client_pool_t = ThreadSafeMemoryPool(uv.uv_tcp_t, .{
    .growable = true,
});

pub const context_pool_t = ThreadSafeMemoryPool(Context, .{
    .growable = true,
});

pub const write_req_pool_t = ThreadSafeMemoryPool(uv.uv_write_t, .{
    .growable = true,
});