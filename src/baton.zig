const uv = @import("imports/libuv.zig");
const Response = @import("response.zig").Response;
const response_pool_t = @import("constants.zig").response_pool_t;
const map_t = @import("constants.zig").map_t;

pub const Baton = struct {
    req: uv.uv_work_t,
    stream: [*c]uv.uv_stream_t,
    request_raw: []u8,
    buffer: ?[*c]u8,
    response: *Response,
    cleanup_response_cb: *const fn (*Response, *map_t, *response_pool_t) anyerror!void,
    on_write_cb: *const fn([*c]uv.uv_write_t, c_int) callconv(.c) void,
};
