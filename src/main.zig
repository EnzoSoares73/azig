const std = @import("std");
const azig = @import("azig.zig").Azig(void, void);

pub const std_options: std.Options = .{
    .log_level = .err
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = azig.Server.init(&allocator, azig.Config{}, on_response, {});
    try server.start();
}

fn on_response(_: *azig.Request, _: *azig.Response) !void {
}