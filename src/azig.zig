const thread_callback_t = @import("constants.zig").thread_callback_t;
const uv = @import("imports/libuv.zig");

pub const Server = @import("server.zig").Server;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Config = @import("config.zig").Config;

pub fn act_blocking(cb: thread_callback_t, context: ?*anyopaque) void {
    var thread: uv.uv_thread_t = undefined;

    _ = uv.uv_thread_create(&thread, cb, context);
    _ = uv.uv_thread_join(&thread);
}

pub fn act_non_blocking(cb: thread_callback_t, context: ?*anyopaque) void {
    var thread: uv.uv_thread_t = undefined;

    _ = uv.uv_thread_create(&thread, cb, context);
    _ = uv.uv_thread_detach(&thread);
}
