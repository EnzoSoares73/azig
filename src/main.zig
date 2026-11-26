const std = @import("std");
const azig = @import("azig.zig").Azig(void, void);
pub const std_options: std.Options = .{ .log_level = .info };

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const router: azig.Router = comptime .{
        .handlers = &.{.get("/v1/api", onResponse), .put("/v1/api", onResponse)},
    };

    var server = try azig.Server.init(allocator, azig.Config{}, router, {});
    defer server.deinit();
    try server.start();
}

fn onResponse(_: std.Io, _: *azig.Request, _: *azig.Response) !void {}
