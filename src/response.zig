const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;

pub const Response = struct {
    status_code: u16,
    headers: StringHashMap([]const u8),
    body: ?[]const u8,
    is_init: bool = false,

    const Self = @This();

    pub fn init(allocator: mem.Allocator) !Self {
        var map = StringHashMap([]const u8).init(allocator);
        try map.ensureTotalCapacity(3);
        return Self{
            .body = null,
            .headers = map,
            .status_code = 200,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Self) void {
        self.*.body = null;
        self.*.status_code = 200;
        self.*.headers.clearRetainingCapacity();
        self.*.is_init = true;
    }

    pub fn addHeader(self: *Self, name: []u8, value: []u8) !void {
        try self.*.headers.put(name, value);
    }

    pub fn to_string(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var response_string = std.ArrayList(u8).init(allocator);
        defer response_string.deinit();

        const writer = response_string.writer();

        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            self.*.status_code,
            statusCodeToString(self.status_code) orelse "Unknown",
        });

        const content_length = "Content-Length";
        const len = if (self.*.body) |body| body.len else 0;
        try self.*.addHeader(@constCast(content_length), try std.fmt.allocPrint(allocator, "{d}", .{len}));

        var headers_iter = self.*.headers.iterator();
        while (headers_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.writeAll("\r\n");

        if (self.*.body) |body| {
            try writer.writeAll(body);
        }

        return response_string.toOwnedSlice();
    }

    fn statusCodeToString(code: u16) ?[]const u8 {
        return switch (code) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => null,
        };
    }
};
