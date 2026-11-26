const std = @import("std");

test {
    _ = @import("server.zig");
    _ = @import("response.zig");
    _ = @import("request.zig");
    _ = @import("action.zig");
    _ = @import("pools/map_pool.zig");
    _ = @import("header.zig");
    _ = @import("pools/sync.zig");
    _ = @import("libuv_io.zig");
    _ = @import("router.zig");
    _ = @import("middlewares/cors.zig");

    std.testing.refAllDecls(@This());
}
