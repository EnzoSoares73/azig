const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const header_t = @import("constants.zig").header_t;
const testing = std.testing;

pub const ResponseString = struct {
    string: []const u8,
    in_heap: bool,
};

pub const Response = struct {
    status_code: u16,
    headers: *StringHashMap([]const u8),
    body: ?[]const u8,
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(arena: *std.heap.ArenaAllocator, header_pool: *header_t) !Self {
        const map = try header_pool.*.create();
        return Self{
            .body = null,
            .headers = map,
            .status_code = 200,
            .arena = arena
        };
    }

    pub fn deinit(self: *Self, header_pool: *header_t) !void {
        try header_pool.*.destroy(self.*.headers);
        self.* = undefined;
    }

    pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.*.headers.*.put(name, value);
    }

    pub fn to_string(self: *Self, allocator: std.mem.Allocator) !ResponseString {
        const size = try self.calculate_serialized_size();

        if (size < 4096) {
            var buffer: [4096]u8 = undefined;
            return .{ .string = try self.write_to_buffer(&buffer), .in_heap = false };
        } else {
            const buffer = try allocator.alloc(u8, size);
            errdefer allocator.free(buffer);

            var stream = std.io.fixedBufferStream(buffer);
            try self.write_to_stream(stream.writer());

            return .{ .string = buffer, .in_heap = true };
        }
    }

    fn calculate_serialized_size(self: *Self) !usize {
        var size: usize = 0;

        const status_text = statusCodeToString(self.status_code) orelse "Unknown";
        size += "HTTP/1.1 ".len;
        size += std.fmt.count("{d}", .{self.status_code});
        size += " ".len;
        size += status_text.len;
        size += "\r\n".len;

        var headers_iter = self.headers.*.iterator();
        while (headers_iter.next()) |entry| {
            size += entry.key_ptr.len;
            size += ": ".len;
            size += entry.value_ptr.len;
            size += "\r\n".len;
        }

        const content_length = "Content-Length";
        const len = if (self.body) |b| b.len else 0;
        size += content_length.len;
        size += ": ".len;
        size += std.fmt.count("{d}", .{len});
        size += "\r\n".len;

        size += "\r\n".len;

        if (self.body) |b| {
            size += b.len;
        }

        return size;
    }

    fn write_to_stream(self: *Self, writer: anytype) !void {
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            self.status_code,
            statusCodeToString(self.status_code) orelse "Unknown",
        });

        var headers_iter = self.headers.*.iterator();
        while (headers_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        const len = if (self.body) |b| b.len else 0;
        try writer.print("Content-Length: {d}\r\n", .{len});

        try writer.writeAll("\r\n");

        if (self.body) |b| {
            try writer.writeAll(b);
        }
    }

    fn write_to_buffer(self: *Self, buffer: []u8) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();

        try write_to_stream(self, writer);

        return buffer[0..stream.pos];
    }

    fn set_error_response(self: *Self) void {
        self.*.headers.clearRetainingCapacity();
        self.*.body = null;
        self.*.status_code = 500;
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

test "Response initialization and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expectEqual(@as(?[]const u8, null), response.body);
    try testing.expectEqual(@as(usize, 0), response.headers.count());

    try response.deinit(&header_pool);
}

test "Response addHeader" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    try response.addHeader("Content-Type", "application/json");
    try response.addHeader("X-Custom-Header", "test-value");

    try testing.expectEqual(@as(usize, 2), response.headers.count());
    try testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("test-value", response.headers.get("X-Custom-Header").?);

    try response.deinit(&header_pool);
}

test "Response to_string with small response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    try response.addHeader("Content-Type", "text/plain");
    response.body = "Hello, World!";

    const response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);

    try testing.expect(!response_str.in_heap);
    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str.string, "Content-Type: text/plain\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str.string, "Content-Length: 13\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str.string, "\r\n\r\nHello, World!"));

    try response.deinit(&header_pool);
}

test "Response to_string with large response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    const body_size = 5000;
    const large_body = try allocator.alloc(u8, body_size);
    defer allocator.free(large_body);
    @memset(large_body, 'A');
    response.body = large_body;

    const response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);

    try testing.expect(response_str.in_heap);
    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str.string, "Content-Length: 5000\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str.string, "\r\n\r\n").? + 4 + body_size == response_str.string.len);

    try response.deinit(&header_pool);
}

test "Response status code strings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    // Test known status codes
    response.status_code = 200;
    var response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);
    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 200 OK\r\n"));

    response.status_code = 404;
    response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);
    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 404 Not Found\r\n"));

    // Test unknown status code
    response.status_code = 999;
    response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);
    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 999 Unknown\r\n"));

    try response.deinit(&header_pool);
}

test "Response with no body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);
    try response.addHeader("X-Empty", "true");
    response.body = null;

    const response_str = try response.to_string(allocator);
    defer if (response_str.in_heap) allocator.free(response_str.string);

    try testing.expect(mem.startsWith(u8, response_str.string, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str.string, "X-Empty: true\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str.string, "Content-Length: 0\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str.string, "\r\n\r\n"));

    try response.deinit(&header_pool);
}

test "Response calculate_serialized_size" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var header_pool = header_t.init(allocator);

    var response = try Response.init(arena, &header_pool);

    try response.addHeader("Content-Type", "text/html");
    response.body = "<html></html>";

    const size = try response.calculate_serialized_size();
    const expected_size =
        "HTTP/1.1 200 OK\r\n".len +
        "Content-Type: text/html\r\n".len +
        "Content-Length: 12\r\n".len +
        "\r\n".len +
        "<html></html>".len;

    try testing.expectEqual(expected_size, size);

    try response.deinit(&header_pool);
}
