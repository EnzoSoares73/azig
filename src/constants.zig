const std = @import("std");
const Response = @import("response.zig").Response;
const Baton = @import("baton.zig").Baton;
const uv = @import("imports/libuv.zig");
const ThreadSafeMemoryPool = @import("pools/thread_safe_memory_pool.zig").ThreadSafeMemoryPool;
const HeaderPool = @import("pools/header_pool.zig").HeaderPool;
const request_t = @import("request.zig").request_t;

pub const DEFAULT_PORT: u16 = 2500;
pub const DEFAULT_POOL_SIZE: u16 = 1024;

pub fn callback_t(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);
    if (AppContext == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (*AppContext, *Request, *Response) anyerror!void;
}

pub const thread_callback_t = ?*const fn (?*anyopaque) callconv(.C) void;

pub const suggested_buffer_size: usize = 65536;
pub const actual_buffer_size = suggested_buffer_size + @sizeOf(usize);

pub const buffer_pool_t = ThreadSafeMemoryPool([suggested_buffer_size]u8, .{
    .growable = true,
});

pub const response_pool_t = ThreadSafeMemoryPool(Response, .{
    .growable = true,
});

pub const client_pool_t = ThreadSafeMemoryPool(uv.uv_tcp_t, .{
    .growable = true,
});

pub const baton_pool_t = ThreadSafeMemoryPool(Baton, .{
    .growable = true,
});

pub const write_req_pool_t = ThreadSafeMemoryPool(uv.uv_write_t, .{
    .growable = true,
});

pub const header_t = HeaderPool(.{
    .growable = true,
});

pub const supported_versions = [_][]const u8{ "HTTP/1.1" };
