const std = @import("std");
const azig = @import("azig.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server(void).init(&allocator, azig.Config{}, on_response, {});
    try server.start();
}

fn on_response(_: *azig.Request, _: *azig.Response) !void {
}