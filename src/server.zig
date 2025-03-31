const std = @import("std");
const net = std.net;
const print = std.debug.print;

pub fn serve() !net.Server {
    print("Started server\n", .{});
    const loopback = try net.Ip4Address.parse("127.0.0.1", 2500);
    const local_address = net.Address{ .in = loopback };
    const server = try local_address.listen(.{ .reuse_address = true });
    print("Listening on {}\n", .{local_address});

    return server;
}
