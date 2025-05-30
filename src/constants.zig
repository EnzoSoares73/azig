const std = @import("std");
const Response = @import("response.zig").Response;
const Baton = @import("baton.zig").Baton;
const uv = @import("imports/libuv.zig");
const ThreadSafeMemoryPool = @import("pools/thread_safe_memory_pool.zig").ThreadSafeMemoryPool;
const MapPool = @import("pools/map_pool.zig").MapPool;
const request_t = @import("request.zig").request_t;
const action_t = @import("action.zig").action_t;

pub const DEFAULT_PORT: u16 = 2500;
pub const DEFAULT_POOL_SIZE: u16 = 1024;
pub const DEFAULT_INACTIVITY_TIMEOUT: u64 = 15_000;
pub const DEFAULT_BACKLOG_SIZE: u16 = 128;
pub const DEFAULT_LISTEN_ADDRESS = "0.0.0.0";
pub const suggested_buffer_size: usize = 65536;

pub fn callback_t(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);
    if (AppContext == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (*AppContext, *Request, *Response) anyerror!void;
}

pub fn middleware_t(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);
    const Action = action_t(AppContext, RequestContext);
    if (AppContext == void)
        return *const fn (*Request, *Response, Action) anyerror!void
    else
        return *const fn (*AppContext, *Request, *Response, Action) anyerror!void;
}

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

pub const arena_pool_t = ThreadSafeMemoryPool(std.heap.ArenaAllocator, .{
    .growable = true,
});

pub const map_t = MapPool(.{
    .growable = true,
});

pub const supported_versions = [_][]const u8{ "HTTP/1.1" };
