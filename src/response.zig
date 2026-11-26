const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const StringMapPool = @import("constants.zig").StringMapPool;
const testing = std.testing;
const statusCodeToMessage = @import("http_error.zig").statusCodeToMessage;
const http_header = @import("header.zig");

pub const Response = struct {
    status_code: u16,
    headers: *StringHashMap([]const u8),
    body: ?[]const u8,
    arena: *std.heap.ArenaAllocator,
    /// When false, the body is left out but Content-Length still reflects it (HEAD responses).
    send_body: bool,

    const Self = @This();

    pub const Error = error{InvalidHeader};

    pub fn init(arena: *std.heap.ArenaAllocator, map_pool: *StringMapPool) !Self {
        const map = try map_pool.*.create();
        return Self{
            .body = null,
            .headers = map,
            .status_code = 200,
            .arena = arena,
            .send_body = true,
        };
    }

    pub fn deinit(self: *Self, map_pool: *StringMapPool) void {
        map_pool.*.destroy(self.*.headers);
        self.* = undefined;
    }

    /// Returns error.InvalidHeader if the name is not a valid token or the value contains
    /// CR, LF or NUL, which would allow header injection.
    pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
        if (!http_header.isValidName(name) or !http_header.isValidValue(value)) {
            return Error.InvalidHeader;
        }
        try self.*.headers.*.put(name, value);
    }

    /// Serializes the response into a newly allocated buffer owned by the caller.
    /// The buffer does not reference the response, so it stays valid after the
    /// response (and its arena) are destroyed, e.g. while an async write is in flight.
    pub fn toString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try self.serializeInto(allocator, &out);
        return out.toOwnedSlice(allocator);
    }

    /// Serializes the response into `out`, replacing its contents. `out`'s existing
    /// capacity is reused, so a buffer kept across responses only allocates when it grows.
    /// On error `out` is left empty (its capacity is kept).
    pub fn serializeInto(self: *Self, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();

        const size = try self.calculateSerializedSize();
        try out.ensureTotalCapacity(allocator, size);

        var writer = std.Io.Writer.fixed(out.allocatedSlice()[0..size]);
        try self.writeToStream(&writer);
        std.debug.assert(writer.end == size);

        out.items.len = size;
    }

    fn calculateSerializedSize(self: *Self) !usize {
        var size: usize = 0;

        const status_text = statusCodeToMessage(self.status_code) orelse "Unknown";
        size += "HTTP/1.1 ".len;
        size += std.fmt.count("{d}", .{self.status_code});
        size += " ".len;
        size += status_text.len;
        size += "\r\n".len;

        var headers_iter = self.headers.*.iterator();
        while (headers_iter.next()) |entry| {
            // Checked here too, since handlers can also write to the headers map directly.
            if (!http_header.isValidName(entry.key_ptr.*) or !http_header.isValidValue(entry.value_ptr.*)) {
                return Error.InvalidHeader;
            }
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

        if (self.send_body) {
            if (self.body) |b| {
                size += b.len;
            }
        }

        return size;
    }

    fn writeToStream(self: *Self, writer: *std.Io.Writer) !void {
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            self.status_code,
            statusCodeToMessage(self.status_code) orelse "Unknown",
        });

        var headers_iter = self.headers.*.iterator();
        while (headers_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        const len = if (self.body) |b| b.len else 0;
        try writer.print("Content-Length: {d}\r\n", .{len});

        try writer.writeAll("\r\n");

        if (self.send_body) {
            if (self.body) |b| {
                try writer.writeAll(b);
            }
        }
    }

    pub fn setResponseError(self: *Self, code: u16) void {
        self.*.body = null;
        self.*.status_code = code;
    }
};

test "Response initialization and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expectEqual(@as(?[]const u8, null), response.body);
    try testing.expectEqual(@as(usize, 0), response.headers.count());

    response.deinit(&map_pool);
}

test "Response addHeader" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    try response.addHeader("Content-Type", "application/json");
    try response.addHeader("X-Custom-Header", "test-value");

    try testing.expectEqual(@as(usize, 2), response.headers.count());
    try testing.expectEqualStrings("application/json", response.headers.get("Content-Type").?);
    try testing.expectEqualStrings("test-value", response.headers.get("X-Custom-Header").?);

    response.deinit(&map_pool);
}

test "Response toString with small response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    try response.addHeader("Content-Type", "text/plain");
    response.body = "Hello, World!";

    const response_str = try response.toString(allocator);
    defer allocator.free(response_str);

    try testing.expect(mem.startsWith(u8, response_str, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str, "Content-Type: text/plain\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str, "Content-Length: 13\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str, "\r\n\r\nHello, World!"));

    response.deinit(&map_pool);
}

test "Response toString with large response" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    const body_size = 5000;
    const large_body = try allocator.alloc(u8, body_size);
    defer allocator.free(large_body);
    @memset(large_body, 'A');
    response.body = large_body;

    const response_str = try response.toString(allocator);
    defer allocator.free(response_str);

    try testing.expect(mem.startsWith(u8, response_str, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str, "Content-Length: 5000\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str, "\r\n\r\n").? + 4 + body_size == response_str.len);

    response.deinit(&map_pool);
}

test "Response status code strings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    // Test known status codes
    response.status_code = 200;
    const ok_str = try response.toString(allocator);
    defer allocator.free(ok_str);
    try testing.expect(mem.startsWith(u8, ok_str, "HTTP/1.1 200 OK\r\n"));

    response.status_code = 404;
    const not_found_str = try response.toString(allocator);
    defer allocator.free(not_found_str);
    try testing.expect(mem.startsWith(u8, not_found_str, "HTTP/1.1 404 Not Found\r\n"));

    // Test unknown status code
    response.status_code = 999;
    const unknown_str = try response.toString(allocator);
    defer allocator.free(unknown_str);
    try testing.expect(mem.startsWith(u8, unknown_str, "HTTP/1.1 999 Unknown\r\n"));

    response.deinit(&map_pool);
}

test "Response with no body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);
    try response.addHeader("X-Empty", "true");
    response.body = null;

    const response_str = try response.toString(allocator);
    defer allocator.free(response_str);

    try testing.expect(mem.startsWith(u8, response_str, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, response_str, "X-Empty: true\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str, "Content-Length: 0\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str, "\r\n\r\n"));

    response.deinit(&map_pool);
}

test "Response calculateSerializedSize" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    try response.addHeader("Content-Type", "text/html");
    response.body = "<html></html>";

    const size = try response.calculateSerializedSize();
    const expected_size =
        "HTTP/1.1 200 OK\r\n".len +
        "Content-Type: text/html\r\n".len +
        "Content-Length: 12\r\n".len +
        "\r\n".len +
        "<html></html>".len;

    try testing.expectEqual(expected_size, size);

    response.deinit(&map_pool);
}

test "Response without send_body keeps Content-Length but omits the body (HEAD)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);
    defer response.deinit(&map_pool);

    response.body = "Hello, World!";
    response.send_body = false;

    const response_str = try response.toString(allocator);
    defer allocator.free(response_str);

    try testing.expect(mem.indexOf(u8, response_str, "Content-Length: 13\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str, "\r\n\r\n"));
    try testing.expect(mem.indexOf(u8, response_str, "Hello") == null);
}

test "Response addHeader rejects header injection" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);
    defer response.deinit(&map_pool);

    try testing.expectError(Response.Error.InvalidHeader, response.addHeader("X-Name", "value\r\nSet-Cookie: session=evil"));
    try testing.expectError(Response.Error.InvalidHeader, response.addHeader("X-Name\r\nSet-Cookie", "evil"));
    try testing.expectError(Response.Error.InvalidHeader, response.addHeader("", "value"));
    try testing.expectEqual(@as(usize, 0), response.headers.count());
}

test "Response toString rejects invalid headers written to the map directly" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);
    defer response.deinit(&map_pool);

    try response.headers.put("X-Name", "value\r\n\r\ninjected body");
    try testing.expectError(Response.Error.InvalidHeader, response.toString(allocator));
}

test "Response setResponseError keeps the headers and drops the body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var response = try Response.init(&arena, &map_pool);
    try response.addHeader("Access-Control-Allow-Origin", "*");
    response.body = "partial";
    response.setResponseError(404);

    const response_str = try response.toString(allocator);
    defer allocator.free(response_str);

    try testing.expect(mem.startsWith(u8, response_str, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(mem.indexOf(u8, response_str, "Access-Control-Allow-Origin: *\r\n") != null);
    try testing.expect(mem.indexOf(u8, response_str, "Content-Length: 0\r\n") != null);
    try testing.expect(mem.endsWith(u8, response_str, "\r\n\r\n"));

    response.deinit(&map_pool);
}
