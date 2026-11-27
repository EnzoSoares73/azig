const std = @import("std");
const Response = @import("http/response.zig").Response;
const uv = @import("uv");
const MapPool = @import("pools/map_pool.zig").MapPool;
const GenericRequest = @import("http/request.zig").GenericRequest;
const GenericAction = @import("action.zig").GenericAction;

pub const default_port: u16 = 2500;
pub const default_pool_size: u16 = 1024;
pub const default_inactivity_timeout: u64 = 15_000;
pub const default_backlog_size: u16 = 128;
pub const default_listen_address = "0.0.0.0";
pub const default_max_payload_size: u64 = 1_048_576;
/// Stack size of each request handler (handlers run as fibers on the event loop).
pub const default_task_stack_size: usize = 4 * 1024 * 1024;
pub const default_allowed_methods: *const [7][]const u8 = &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
pub const suggested_buffer_size: usize = 65536;
/// Minimum free space handed to libuv for each read. Reads go straight into the
/// connection's read buffer, which grows past this only for large requests.
pub const read_chunk_size: usize = 4096;

pub fn Callback(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = GenericRequest(RequestContext);
    if (AppContext == void) {
        return *const fn (std.Io, *Request, *Response) anyerror!void;
    }
    return *const fn (*AppContext, std.Io, *Request, *Response) anyerror!void;
}

pub fn Middleware(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = GenericRequest(RequestContext);
    const Action = GenericAction(AppContext, RequestContext);
    if (AppContext == void)
        return *const fn (std.Io, *Request, *Response, Action) anyerror!void
    else
        return *const fn (*AppContext, std.Io, *Request, *Response, Action) anyerror!void;
}

pub const ResponsePool = std.heap.MemoryPool(Response);

pub const ClientPool = std.heap.MemoryPool(uv.uv_tcp_t);

pub const WriteReqPool = std.heap.MemoryPool(uv.uv_write_t);

pub const ArenaPool = std.heap.MemoryPool(std.heap.ArenaAllocator);

pub const StringMapPool = MapPool(.{
    .growable = true,
});

pub const supported_versions = [_][]const u8{"HTTP/1.1"};
