const std = @import("std");

test {
    _ = @import("server.zig");
    _ = @import("response.zig");
    _ = @import("request.zig");
    _ = @import("action.zig");

    std.testing.refAllDecls(@This());
}