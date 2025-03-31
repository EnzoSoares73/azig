const std = @import("std");
const request_lib = @import("request.zig");
const net = std.net;
const mem = std.mem;

pub fn parse_data(allocator: mem.Allocator, connection: net.Server.Connection) !void {
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

    const request_raw = received_total[0..received_total_length];

    var request: request_lib.Request = try request_lib.parseRequest(allocator, request_raw);
    request.printSelf();
    request.deinit();

    const httpHead =
        "HTTP/1.1 200 OK \r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    _ = try connection.stream.write(httpHead);
    connection.stream.close();
}
