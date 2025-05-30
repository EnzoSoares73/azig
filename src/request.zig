const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const ascii = std.ascii;
const map_t = @import("constants.zig").map_t;
const testing = std.testing;
const supported_versions = @import("constants.zig").supported_versions;

pub fn request_t(comptime RequestContext: type) type {
    return struct {
        method: []const u8,
        path: []const u8,
        version: []const u8,
        headers: *StringHashMap([]const u8),
        params: *StringHashMap([]const u8),
        body: ?[]const u8,
        context: RequestContext,

        const Self = @This();

        pub fn init(map_pool: *map_t) !Self {
            return Self{
                .body = null,
                .headers = try map_pool.*.create(),
                .params = try map_pool.*.create(),
                .method = undefined,
                .path = undefined,
                .version = undefined,
                .context = undefined,
            };
        }

        pub fn deinit(self: *Self, map_pool: *map_t) !void {
            try map_pool.*.destroy(self.*.headers);
            self.* = undefined;
        }

        pub fn printSelf(self: Self) void {
            print("{s} {s} {s}\n", .{ self.method, self.path, self.version });

            var iter = self.headers.*.iterator();
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

        pub fn getHeader(self: Self, name: []const u8) ?[]const u8 {
            return self.headers.*.get(@constCast(name));
        }

        pub fn parseRequest(self: *Self, request_raw: []u8) !void {
            var i: usize = 0;

            const method_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
            self.method = request_raw[i .. i + method_end];
            i += method_end + 1;

            const path_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
            self.path = request_raw[i .. i + path_end];

            if (std.mem.indexOfScalar(u8, self.path, '?')) |query_start| {
                const path_part = self.path[0..query_start];
                const query_part = self.path[query_start + 1..];

                self.path = path_part;

                var query_iter = std.mem.splitScalar(u8, query_part, '&');
                while (query_iter.next()) |param| {
                    if (std.mem.indexOf(u8, param, "=")) |equals_pos| {
                        const name = param[0..equals_pos];
                        const value = param[equals_pos + 1..];
                        try self.*.params.*.put(name, value);
                    } else if (param.len > 0) {
                        try self.*.params.*.put(param, "");
                    }
                }
            }

            i += path_end + 1;

            const version_end = std.mem.indexOfScalar(u8, request_raw[i..], '\r') orelse return error.InvalidRequest;
            self.version = request_raw[i .. i + version_end];
            for (supported_versions) |supported_version| {
                if (mem.eql(u8, self.version, supported_version)) {
                    break;
                }
            } else {
                return error.UnsupportedVersion;
            }
            i += version_end + 2;

            while (i < request_raw.len) {
                if (i + 1 < request_raw.len and request_raw[i] == '\r' and request_raw[i + 1] == '\n') {
                    i += 2;
                    break;
                }

                const line_end = std.mem.indexOfScalarPos(u8, request_raw, i, '\r') orelse return error.InvalidRequest;
                const colon_pos = std.mem.indexOfScalar(u8, request_raw[i..line_end], ':') orelse return error.InvalidHeader;

                const key = std.mem.trim(u8, request_raw[i .. i + colon_pos], " ");
                const value = std.mem.trim(u8, request_raw[i + colon_pos + 1 .. line_end], " ");

                capitalizeHeaderName(@constCast(key));
                try self.*.headers.*.put(key, value);
                i = line_end + 2;
            }

            if (i < request_raw.len) {
                self.*.body = request_raw[i..];
            }
        }

        fn capitalizeHeaderName(name: []u8) void {
            var capitalize = true;
            for (name) |*c| {
                if (capitalize and ascii.isAlphabetic(c.*)) {
                    c.* = ascii.toUpper(c.*);
                    capitalize = false;
                } else {
                    c.* = ascii.toLower(c.*);
                    capitalize = (c.* == '-');
                }
            }
        }
    };
}

test "Request initialization and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    try testing.expect(request.body == null);

    try request.deinit(&map_pool);
}

test "parse simple GET request" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/index.html", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqual(@as(?[]const u8, null), request.body);

    try testing.expectEqualStrings("example.com", request.getHeader("Host").?);
    try testing.expectEqualStrings("test-agent", request.getHeader("User-Agent").?);

    try request.deinit(&map_pool);
}

test "parse POST request with body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 18\r\n" ++
        "\r\n" ++
        "{\"key\": \"value\"}";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/submit", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqualStrings("{\"key\": \"value\"}", request.body.?);

    try testing.expectEqualStrings("application/json", request.getHeader("Content-Type").?);
    try testing.expectEqualStrings("18", request.getHeader("Content-Length").?);

    try request.deinit(&map_pool);
}

test "header name capitalization" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "content-type: text/html\r\n" ++
        "user-AGENT: test-agent\r\n" ++
        "x-custom-header: value\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expect(request.getHeader("Content-Type") != null);
    try testing.expect(request.getHeader("User-Agent") != null);
    try testing.expect(request.getHeader("X-Custom-Header") != null);

    try request.deinit(&map_pool);
}

test "invalid request format" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    try testing.expectError(error.InvalidRequest, request.parseRequest(@constCast("/path HTTP/1.1\r\n\r\n")));

    try testing.expectError(error.InvalidRequest, request.parseRequest(@constCast("GET HTTP/1.1\r\n\r\n")));

    try testing.expectError(error.UnsupportedVersion, request.parseRequest(@constCast("GET /path HTTP/1\r\n\r\n")));

    try testing.expectError(error.InvalidHeader, request.parseRequest(@constCast("GET /path HTTP/1.1\r\ninvalidheader\r\n\r\n")));

    try request.deinit(&map_pool);
}

test "request with multiple headers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Accept: text/html\r\n" ++
        "Accept-Language: en-US\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expectEqual(@as(usize, 4), request.headers.*.count());
    try testing.expectEqualStrings("example.com", request.getHeader("Host").?);
    try testing.expectEqualStrings("text/html", request.getHeader("Accept").?);
    try testing.expectEqualStrings("en-US", request.getHeader("Accept-Language").?);
    try testing.expectEqualStrings("keep-alive", request.getHeader("Connection").?);

    try request.deinit(&map_pool);
}

test "request with empty headers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Empty-Header: \r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expectEqual(@as(usize, 1), request.headers.*.count());
    try testing.expectEqualStrings("", request.getHeader("Empty-Header").?);

    try request.deinit(&map_pool);
}

test "request with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    const request_raw =
        "GET /path?param1=value1&param2=value2&flag HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request);

    try request.parseRequest(@constCast(mutable_request));

    try testing.expectEqualStrings("/path", request.path);

    try testing.expectEqual(@as(usize, 3), request.params.*.count());
    try testing.expectEqualStrings("value1", request.params.*.get("param1").?);
    try testing.expectEqualStrings("value2", request.params.*.get("param2").?);
    try testing.expectEqualStrings("", request.params.*.get("flag").?);

    try request.deinit(&map_pool);
}
