const std = @import("std");
const print = std.debug.print;
const net = std.net;
const mem = std.mem;
const StringHashMap = std.StringHashMap;

const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,

    const Self = @This();

    fn init(allocator: mem.Allocator) Self {
        const map = StringHashMap([]const u8).init(allocator);
        return Self{
            .body = null,
            .headers = map,
            .method = undefined,
            .path = undefined,
            .version = undefined,
        };
    }

    fn deinit(self: *Self) void {
        self.headers.deinit();
        self.* = undefined;
    }

    fn printSelf(self: Self) void {
        print("{s} {s} {s}\n", .{ self.method, self.path, self.version });

        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            print("{s}: {s}\n", .{ key, value });
        }

        if (self.body) |body| {
            print("\n{s}\n", .{body});
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    print("Started server\n", .{});
    const loopback = try net.Ip4Address.parse("127.0.0.1", 2500);
    const local_address = net.Address{ .in = loopback };
    var server = try local_address.listen(.{ .reuse_address = true });
    print("Listening on {}\n", .{local_address});

    while (server.accept()) |connection| {
        std.debug.print("Accepted connection from: {}\n\n", .{connection.address});
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

        var request: Request = try parseRequest(allocator, request_raw);
        request.printSelf();
        request.deinit();

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

fn parseRequest(allocator: mem.Allocator, request_raw: []u8) !Request {
    var request_iter = mem.tokenizeSequence(u8, request_raw, "\r\n\r\n");
    const raw_headers = request_iter.next() orelse "";
    var request = try parseHeaders(allocator, raw_headers);
    request.body = request_iter.next() orelse null;

    return request;
}

fn parseHeaders(allocator: mem.Allocator, raw_headers: []const u8) !Request {
    var request: Request = Request.init(allocator);

    var header_iter = mem.tokenizeSequence(u8, raw_headers, "\r\n");

    if (header_iter.next()) |first_line| {
        request.method, request.path, request.version = parseFirstLine(first_line);
    }

    while (header_iter.next()) |line| {
        const name, const value = parseHeader(line);
        try request.headers.put(name, value);
    }

    return request;
}

fn parseFirstLine(first_line: []const u8) [3][]const u8 {
    var first_line_iter = mem.tokenizeScalar(u8, first_line, ' ');

    const method = first_line_iter.next() orelse "";
    const path = first_line_iter.next() orelse "";
    const version = first_line_iter.next() orelse "";

    return .{ method, path, version };
}

fn parseHeader(line: []const u8) [2][]const u8 {
    var line_iter = mem.tokenizeSequence(u8, line, ": ");

    const name = line_iter.next() orelse "";
    const value = line_iter.next() orelse "";

    return .{ name, value };
}
