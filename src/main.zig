const std = @import("std");
const print = std.debug.print;
const net = std.net;
const mem = std.mem;

pub fn main() !void {
    print("Started server\n", .{});
    const loopback = try net.Ip4Address.parse("127.0.0.1", 2500);
    const local_address = net.Address{ .in = loopback };
    var server = try local_address.listen(.{ .reuse_address = true });
    print("Listening on {}\n", .{local_address});

    while (server.accept()) |connection| {
        std.debug.print("Accepted connection from: {}\n", .{connection.address});
        var received_total: [2048]u8 = undefined;
        var received_total_length: usize = 0;
        while (connection.stream.read(received_total[received_total_length..])) |temp_received_length| {
            if (temp_received_length == 0) break;
            received_total_length += temp_received_length;
            if (mem.containsAtLeast(u8, received_total[0..received_total_length], 1, "\r\n\r\n")) {
                break;
            }
        } else |read_err| {
            return read_err;
        }

        const request = received_total[0..received_total_length];

        print("Request: {s}\n", .{request});

        const httpHead =
            "HTTP/1.1 200 OK \r\n" ++
            "Connection: close\r\n" ++
            "\r\n";

        _ = try connection.stream.write(httpHead);
        connection.stream.close();
    } else |err| {
        return err;
    }
}
