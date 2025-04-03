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