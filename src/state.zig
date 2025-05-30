const uv = @import("imports/libuv.zig");

pub const State = struct {
    context: *anyopaque,
    timer: uv.uv_timer_t,
    stream: [*c]uv.uv_stream_t,
    request_raw: ?[]u8,
};
