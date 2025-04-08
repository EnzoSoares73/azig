const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: mem.Allocator) Self {
        const map = StringHashMap([]const u8).init(allocator);
        return Self{
            .body = null,
            .headers = map,
            .method = undefined,
            .path = undefined,
            .version = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.* = undefined;
    }

    pub fn printSelf(self: Self) void {
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

        print("\n\n", .{});
    }
};

pub fn parseRequest(allocator: mem.Allocator, request_raw: []u8) !Request {
    var request_iter = mem.tokenizeSequence(u8, request_raw, "\r\n\r\n");
    const raw_headers = request_iter.next() orelse "";
    var request = try parseHeaders(allocator, raw_headers);
    request.body = request_iter.next() orelse null;

    return request;
}

fn parseHeaders(allocator: mem.Allocator, raw_headers: []const u8) !Request {
    var request = Request.init(allocator);

    const first_line_end = mem.indexOfScalar(u8, raw_headers, '\n') orelse raw_headers.len;
    const first_line = mem.trim(u8, raw_headers[0..first_line_end], "\r");

    {
        var iter = mem.splitScalar(u8, first_line, ' ');
        request.method = iter.next() orelse "";
        request.path = iter.next() orelse "";
        request.version = iter.next() orelse "";
    }

    var headers = raw_headers[first_line_end + 1 ..];
    while (headers.len > 0) {
        const line_end = mem.indexOfScalar(u8, headers, '\n') orelse headers.len;
        const line = mem.trim(u8, headers[0..line_end], "\r");

        if (line.len > 0) {
            const colon = mem.indexOfScalar(u8, line, ':') orelse {
                headers = headers[line_end + 1 ..];
                continue;
            };

            const name = mem.trim(u8, line[0..colon], " ");
            const value = if (colon + 1 < line.len)
                mem.trim(u8, line[colon + 1 ..], " ")
            else
                "";

            try request.headers.put(name, value);
        }

        if (line_end + 1 > headers.len) {
            break;
        }
        headers = headers[line_end + 1 ..];
    }

    return request;
}