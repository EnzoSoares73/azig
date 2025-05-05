const std = @import("std");
const azig = @import("azig.zig");

const Request = azig.request_t(void);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server(void, void).init(&allocator, azig.Config{}, on_response, {});
    try server.start();
}

fn on_response(_: *Request, _: *azig.Response) !void {
}