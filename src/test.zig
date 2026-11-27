const std = @import("std");

test {
    _ = @import("server.zig");
    _ = @import("http/response.zig");
    _ = @import("http/request.zig");
    _ = @import("action.zig");
    _ = @import("pools/map_pool.zig");
    _ = @import("http/header.zig");
    _ = @import("http/http_error.zig");
    _ = @import("pools/sync.zig");
    _ = @import("libuv_io.zig");
    _ = @import("router.zig");
    _ = @import("middlewares/cors.zig");

    std.testing.refAllDecls(@This());
}
