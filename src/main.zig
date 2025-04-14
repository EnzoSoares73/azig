const std = @import("std");
const libuv_execute = @import("libuv.zig").libuv_execute;
const Server = @import("server.zig").Server;
const mem = std.mem;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Config = @import("config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = Server.init(&allocator, Config{}, on_response);
    try server.start();
}

fn on_response(_: mem.Allocator, _: *Request, _: *Response) !void {}
