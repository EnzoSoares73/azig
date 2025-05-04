const uv = @import("imports/libuv.zig");
const Response = @import("response.zig").Response;
const response_pool_t = @import("constants.zig").response_pool_t;
const header_t = @import("constants.zig").header_t;

pub const Baton = struct {
    req: uv.uv_work_t,
    stream: [*c]uv.uv_stream_t,
    request_raw: []u8,
    response: *Response,
    cleanup_response_cb: *const fn (*Response, *header_t, *response_pool_t) anyerror!void,
    on_write_cb: *const fn([*c]uv.uv_write_t, c_int) callconv(.c) void,
};
