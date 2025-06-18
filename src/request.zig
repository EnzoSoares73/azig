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
            try map_pool.*.destroy(self.*.params);
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

        pub fn get_header(self: Self, name: []const u8) ?[]const u8 {
            return self.headers.*.get(@constCast(name));
        }

        pub fn parse_chunked_body(self: *Self) !void {
            if (self.body) |body| {
                var slider: u64 = 0;
                var cursor: u64 = 0;

                const end_pos = std.mem.indexOf(u8, body, "0\r\n\r\n") orelse return error.InvalidRequest;

                if (end_pos + 5 < body.len) {
                    return error.InvalidRequest;
                }

                while (slider < end_pos) {
                    const chunk_pos = std.mem.indexOf(u8, body[slider..], "\r\n") orelse return error.InvalidRequest;
                    const chunk_size = try std.fmt.parseInt(u64, body[slider .. chunk_pos + slider], 16);

                    const chunk_start = chunk_pos + slider + 2;
                    const chunk_end = chunk_start + chunk_size;

                    // Prevents segfaults
                    if (chunk_end > end_pos or chunk_size < 0) {
                        return error.InvalidRequest;
                    }
                    const chunk = body[chunk_start..chunk_end];

                    std.mem.copyForwards(u8, @constCast(body)[cursor..], chunk);
                    cursor += chunk.len;
                    slider = chunk_end + 2;

                    // There should be a "\r\n" between chunks
                    if (!std.mem.eql(u8, "\r\n", body[chunk_end..slider])) {
                        return error.InvalidRequest;
                    }
                }
                self.body = body[0..cursor];
            }
        }

        pub fn append_to_body(self: *Self, new_data: []const u8) void {
            if (self.*.body) |existing_body| {
                // If there's already a body, we just update it to include the new data
                // This works because the caller has already appended the new data to the buffer
                // and updated the slices to point to the new buffer
                self.*.body = existing_body.ptr[0 .. existing_body.len + new_data.len];
            } else {
                // If there's no body yet, set it to the new data
                self.*.body = new_data;
            }
        }

        pub fn parse_request(self: *Self, request_raw: []u8) !void {
            var i: usize = 0;

            const method_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
            self.method = request_raw[i .. i + method_end];
            i += method_end + 1;

            const path_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
            self.path = request_raw[i .. i + path_end];

            if (std.mem.indexOfScalar(u8, self.path, '?')) |query_start| {
                const path_part = self.path[0..query_start];
                const query_part = self.path[query_start + 1 ..];

                self.path = path_part;

                var query_iter = std.mem.splitScalar(u8, query_part, '&');
                while (query_iter.next()) |param| {
                    if (std.mem.indexOf(u8, param, "=")) |equals_pos| {
                        const name = param[0..equals_pos];
                        const value = param[equals_pos + 1 ..];
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

            var hasHostHeader = false;
            while (i < request_raw.len) {
                if (i + 1 < request_raw.len and request_raw[i] == '\r' and request_raw[i + 1] == '\n') {
                    i += 2;
                    break;
                }

                const line_end = std.mem.indexOfScalarPos(u8, request_raw, i, '\r') orelse return error.InvalidRequest;
                const colon_pos = std.mem.indexOfScalar(u8, request_raw[i..line_end], ':') orelse return error.InvalidHeader;

                const key = std.mem.trim(u8, request_raw[i .. i + colon_pos], " ");
                const value = std.mem.trim(u8, request_raw[i + colon_pos + 1 .. line_end], " ");

                capitalize_header_name(@constCast(key));
                if (std.mem.eql(u8, key, "Host")) {
                    hasHostHeader = is_valid_host(value);
                }

                try self.*.headers.*.put(key, value);
                i = line_end + 2;
            }

            if (!hasHostHeader) {
                return error.hostNotFound;
            }

            if (i < request_raw.len) {
                self.*.body = request_raw[i..];
            }
        }

        fn capitalize_header_name(name: []u8) void {
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

        fn is_valid_host(host: []const u8) bool {
            var iterator = std.mem.splitScalar(u8, host, ':');
            const first = iterator.next();
            if (first) |hostname| {
                if (std.net.Address.parseIp(hostname, @intCast(0))) |_| {
                    return true;
                } else |_| {
                    return is_valid_domain(hostname);
                }
            }
            return false;
        }

        fn is_valid_domain(domain: []const u8) bool {
            if (domain.len == 0 or domain.len > 253) {
                return false;
            }

            var labels = std.mem.splitScalar(u8, domain, '.');
            var label_count: usize = 0;

            while (labels.next()) |label| {
                label_count += 1;

                if (label.len == 0 or label.len > 63) {
                    return false;
                }

                if (label[0] == '-' or label[label.len - 1] == '-') {
                    return false;
                }

                for (label) |c| {
                    if (!ascii.isAlphanumeric(c) and c != '-') {
                        return false;
                    }
                }
            }

            return label_count > 0;
        }

        pub fn is_finished_reading(self: *Self) !bool {
            const content_length_header = self.*.get_header("Content-Length");
            const transfer_encoding_header = self.*.get_header("Transfer-Encoding");

            // A request should not have both Content-Length and Transfer-Encoding: chunked
            if (transfer_encoding_header) |header| {
                if (content_length_header != null and std.ascii.eqlIgnoreCase(header, "chunked")) {
                    return error.BadRequest;
                }
            }

            if (content_length_header) |header| {
                const content_length = try std.fmt.parseInt(u64, header, 10);
                if (self.*.body) |body| {
                    if (content_length == body.len) {
                        return true;
                    } else if (content_length < body.len) {
                        return error.BadRequest;
                    } else {
                        return false;
                    }
                } else if (content_length == 0 and self.*.body == null) {
                    return true;
                } else {
                    return false;
                }
            } else if (transfer_encoding_header != null and std.ascii.eqlIgnoreCase(transfer_encoding_header.?, "chunked")) {
                if (self.*.body) |body| {
                    if (std.mem.indexOf(u8, body, "0\r\n\r\n")) |_| {
                        return true;
                    } else {
                        return false;
                    }
                } else {
                    return false;
                }
            } else {
                if (self.*.body == null) {
                    return true;
                } else {
                    return error.BadRequest;
                }
            }
        }

        pub fn is_keep_alive(self: *Self) bool {
            const connection_header = self.*.get_header("Connection");

            if (connection_header) |header| {
                if (!std.ascii.eqlIgnoreCase(header, "keep-alive")) {
                    return false;
                }
            }

            return true;
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
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/index.html", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqual(@as(?[]const u8, null), request.body);

    try testing.expectEqualStrings("example.com", request.get_header("Host").?);
    try testing.expectEqualStrings("test-agent", request.get_header("User-Agent").?);

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
        "host: example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 18\r\n" ++
        "\r\n" ++
        "{\"key\": \"value\"}";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/submit", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqualStrings("{\"key\": \"value\"}", request.body.?);

    try testing.expectEqualStrings("application/json", request.get_header("Content-Type").?);
    try testing.expectEqualStrings("18", request.get_header("Content-Length").?);

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
        "host: example.com\r\n" ++
        "content-type: text/html\r\n" ++
        "user-AGENT: test-agent\r\n" ++
        "x-custom-header: value\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expect(request.get_header("Content-Type") != null);
    try testing.expect(request.get_header("User-Agent") != null);
    try testing.expect(request.get_header("X-Custom-Header") != null);

    try request.deinit(&map_pool);
}

test "invalid request format" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);

    try testing.expectError(error.InvalidRequest, request.parse_request(@constCast("/path HTTP/1.1\r\n\r\n")));

    try testing.expectError(error.InvalidRequest, request.parse_request(@constCast("GET HTTP/1.1\r\n\r\n")));

    try testing.expectError(error.UnsupportedVersion, request.parse_request(@constCast("GET /path HTTP/1\r\n\r\n")));

    try testing.expectError(error.InvalidHeader, request.parse_request(@constCast("GET /path HTTP/1.1\r\ninvalidheader\r\n\r\n")));

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
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expectEqual(@as(usize, 4), request.headers.*.count());
    try testing.expectEqualStrings("example.com", request.get_header("Host").?);
    try testing.expectEqualStrings("text/html", request.get_header("Accept").?);
    try testing.expectEqualStrings("en-US", request.get_header("Accept-Language").?);
    try testing.expectEqualStrings("keep-alive", request.get_header("Connection").?);

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
        "host: example.com\r\n" ++
        "Empty-Header: \r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expectEqual(@as(usize, 2), request.headers.*.count());
    try testing.expectEqualStrings("", request.get_header("Empty-Header").?);

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
    try request.parse_request(mutable_request);

    try request.parse_request(@constCast(mutable_request));

    try testing.expectEqualStrings("/path", request.path);

    try testing.expectEqual(@as(usize, 3), request.params.*.count());
    try testing.expectEqualStrings("value1", request.params.*.get("param1").?);
    try testing.expectEqualStrings("value2", request.params.*.get("param2").?);
    try testing.expectEqualStrings("", request.params.*.get("flag").?);

    try request.deinit(&map_pool);
}

test "test basic chunked body parsing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "7\r\n" ++
        "Mozilla\r\n" ++
        "9\r\n" ++
        "Developer\r\n" ++
        "7\r\n" ++
        "Network\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try request.parse_chunked_body();

    try testing.expectEqualStrings("MozillaDeveloperNetwork", request.body.?);
}

test "test with empty chunk in the middle" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "0\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "World\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidRequest, request.parse_chunked_body());
}

test "test with decimal chunk size" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "A\r\n" ++
        "0123456789\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try request.parse_chunked_body();

    try testing.expectEqualStrings("0123456789", request.body.?);
}

test "test with missing terminating chunk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "5\r\n" ++
        "World\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidRequest, request.parse_chunked_body());
}

test "test with invalid chunk size" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "XYZ\r\n" ++
        "Hello\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidCharacter, request.parse_chunked_body());
}

test "test with chunk size too large (would go beyond end of body)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "50\r\n" ++
        "Hello\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidRequest, request.parse_chunked_body());
}

test "test with missing CRLF after chunk data" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidRequest, request.parse_chunked_body());
}

test "test with content after final chunk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "0\r\n" ++
        "\r\n" ++
        "Extra content that shouldn't be here";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.InvalidRequest, request.parse_chunked_body());
}

test "is_finished_reading with Content-Length matching body length" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 11\r\n" ++
        "\r\n" ++
        "Hello World";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(try request.is_finished_reading());
}

test "is_finished_reading with Content-Length greater than body length" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 20\r\n" ++
        "\r\n" ++
        "Hello World";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(!try request.is_finished_reading());
}

test "is_finished_reading with Content-Length less than body length" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "Hello World";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.BadRequest, request.is_finished_reading());
}

test "is_finished_reading with Content-Length zero and no body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(try request.is_finished_reading());
}

test "is_finished_reading with Transfer-Encoding chunked and complete body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "6\r\n" ++
        " World\r\n" ++
        "0\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(try request.is_finished_reading());
}

test "is_finished_reading with Transfer-Encoding chunked and incomplete body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++
        "Hello\r\n" ++
        "6\r\n" ++
        " World\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(!try request.is_finished_reading());
}

test "is_finished_reading with both Content-Length and Transfer-Encoding chunked" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 11\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "Hello World";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.BadRequest, request.is_finished_reading());
}

test "is_finished_reading with no Content-Length or Transfer-Encoding and no body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(try request.is_finished_reading());
}

test "is_finished_reading with no Content-Length or Transfer-Encoding but with body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n" ++
        "Unexpected body";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expectError(error.BadRequest, request.is_finished_reading());
}

test "is_keep_alive with keep-alive header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(request.is_keep_alive());
}

test "is_keep_alive with close header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(!request.is_keep_alive());
}

test "is_keep_alive with no Connection header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(request.is_keep_alive());
}

test "is_keep_alive with mixed case Connection header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: Keep-Alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    try testing.expect(request.is_keep_alive());
}

test "host validation with valid IP address" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: 192.168.1.1\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with valid IP address and port" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: 192.168.1.1:8080\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with valid domain name" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with valid domain name and subdomain" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: sub.example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with valid domain name and port" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com:8080\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with domain containing hyphens" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: my-example-domain.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);
}

test "host validation with invalid domain starting with hyphen" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: -example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(error.hostNotFound, request.parse_request(mutable_request));
}

test "host validation with invalid domain ending with hyphen" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example-.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(error.hostNotFound, request.parse_request(mutable_request));
}

test "host validation with invalid domain containing invalid character" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example!.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(error.hostNotFound, request.parse_request(mutable_request));
}

test "host validation with empty host" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var request = try request_t(void).init(&map_pool);
    defer request.deinit(&map_pool) catch {};

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: \r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(error.hostNotFound, request.parse_request(mutable_request));
}
