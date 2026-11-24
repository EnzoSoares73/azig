const std = @import("std");
const azig = @import("azig.zig").Azig(void, void);

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = azig.Server.init(allocator, azig.Config{}, onResponse, {});
    try server.start();
}

fn onResponse(_: *azig.Request, _: *azig.Response) !void {}
