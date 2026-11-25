const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const ascii = std.ascii;
const StringMapPool = @import("constants.zig").StringMapPool;
const testing = std.testing;
const supported_versions = @import("constants.zig").supported_versions;
const HttpError = @import("http_error.zig").HttpError;
const http_header = @import("header.zig");

pub fn GenericRequest(comptime RequestContext: type) type {
    return struct {
        method: []const u8,
        path: []const u8,
        version: []const u8,
        headers: *StringHashMap([]const u8),
        params: *StringHashMap([]const u8),
        body: ?[]const u8,
        context: RequestContext,

        const Self = @This();

        pub fn init(map_pool: *StringMapPool) !Self {
            const headers = try map_pool.*.create();
            errdefer map_pool.*.destroy(headers);
            const params = try map_pool.*.create();

            return Self{
                .body = null,
                .headers = headers,
                .params = params,
                .method = undefined,
                .path = undefined,
                .version = undefined,
                .context = undefined,
            };
        }

        pub fn deinit(self: *Self, map_pool: *StringMapPool) void {
            map_pool.*.destroy(self.*.headers);
            map_pool.*.destroy(self.*.params);
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

        /// Decodes a chunked body in place. `self.body` must hold exactly one complete chunked
        /// message (as delimited by `bodyLength`); anything after the last chunk is an error.
        pub fn parseChunkedBody(self: *Self) !void {
            const body = self.body orelse return;
            const out = @constCast(body);

            var pos: usize = 0;
            var cursor: usize = 0;
            while (true) {
                const chunk = (try nextChunk(body, pos)) orelse return HttpError.BadRequest;
                if (chunk.len == 0) {
                    if (chunk.next != body.len) {
                        return HttpError.BadRequest;
                    }
                    break;
                }

                // cursor <= chunk.start, so the copy never overwrites framing that is still unread.
                std.mem.copyForwards(u8, out[cursor..], body[chunk.start..][0..chunk.len]);
                cursor += chunk.len;
                pos = chunk.next;
            }
            self.body = body[0..cursor];
        }

        /// Returns how many of the bytes following the request head belong to this request's
        /// body (for a chunked body, including its framing), or null if `data` does not hold the
        /// whole body yet. Bytes after that belong to the next (pipelined) request.
        pub fn bodyLength(self: *Self, data: []const u8) !?usize {
            const content_length_header = self.*.getHeader("Content-Length");
            const transfer_encoding_header = self.*.getHeader("Transfer-Encoding");

            if (transfer_encoding_header) |transfer_encoding| {
                // A request must not have both (RFC 9112 §6.3); accepting it enables request smuggling.
                if (content_length_header != null) {
                    return HttpError.BadRequest;
                }
                if (!ascii.eqlIgnoreCase(transfer_encoding, "chunked")) {
                    return HttpError.BadRequest;
                }

                var pos: usize = 0;
                while (try nextChunk(data, pos)) |chunk| {
                    if (chunk.len == 0) {
                        return chunk.next;
                    }
                    pos = chunk.next;
                }
                return null;
            }

            if (content_length_header) |header| {
                if (header.len == 0) return HttpError.BadRequest;
                for (header) |c| {
                    if (!ascii.isDigit(c)) return HttpError.BadRequest;
                }
                const content_length = std.fmt.parseInt(usize, header, 10) catch return HttpError.BadRequest;
                return if (data.len >= content_length) content_length else null;
            }

            // Without Content-Length or Transfer-Encoding a request has no body.
            return 0;
        }

        const Chunk = struct {
            /// Offset of the chunk data.
            start: usize,
            /// Length of the chunk data; 0 for the last chunk.
            len: usize,
            /// Offset right after this chunk. For the last chunk, the end of the message
            /// (after the trailer section, which is ignored).
            next: usize,
        };

        /// Parses the chunk starting at `pos`. Returns null if `data` doesn't hold all of it yet.
        fn nextChunk(data: []const u8, pos: usize) !?Chunk {
            const line_end = mem.indexOfPos(u8, data, pos, "\r\n") orelse return null;

            var size_str = data[pos..line_end];
            // Chunk extensions (";name=value") are allowed and ignored.
            if (mem.indexOfScalar(u8, size_str, ';')) |extension_start| {
                size_str = mem.trim(u8, size_str[0..extension_start], " \t");
            }
            if (size_str.len == 0) return error.InvalidCharacter;
            // std.fmt.parseInt also accepts signs and underscores, which are not valid here.
            for (size_str) |c| {
                if (!ascii.isHex(c)) return error.InvalidCharacter;
            }
            const size = try std.fmt.parseInt(usize, size_str, 16);

            const start = line_end + 2;

            if (size == 0) {
                // Last chunk: an optional trailer section, then an empty line.
                if (data.len < start + 2) return null;
                if (mem.eql(u8, data[start .. start + 2], "\r\n")) {
                    return .{ .start = start, .len = 0, .next = start + 2 };
                }
                const trailer_end = mem.indexOfPos(u8, data, start, "\r\n\r\n") orelse return null;
                return .{ .start = start, .len = 0, .next = trailer_end + 4 };
            }

            // Written to avoid overflowing on huge chunk sizes.
            const available = data.len - start;
            if (size > available or available - size < 2) return null;
            if (!mem.eql(u8, data[start + size ..][0..2], "\r\n")) {
                return HttpError.BadRequest;
            }
            return .{ .start = start, .len = size, .next = start + size + 2 };
        }

        /// Returns the length of the request head (request line + headers + the empty line),
        /// or null if the head is not complete yet.
        pub fn headLength(data: []const u8) ?usize {
            const end = mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
            return end + 4;
        }

        fn isValidMethod(method: []const u8, allowed_methods: []const []const u8) bool {
            for (allowed_methods) |allowed_method| {
                if (std.mem.eql(u8, method, allowed_method)) {
                    return true;
                }
            }
            return false;
        }

        pub fn parseRequest(self: *Self, request_raw: []u8, allowed_methods: []const []const u8) !void {
            var i: usize = 0;

            const method_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return HttpError.BadRequest;
            self.method = request_raw[i .. i + method_end];
            i += method_end + 1;

            if (!isValidMethod(self.method, allowed_methods)) {
                return HttpError.MethodNotAllowed;
            }

            const path_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return HttpError.BadRequest;
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

            const version_end = std.mem.indexOfScalar(u8, request_raw[i..], '\r') orelse return HttpError.BadRequest;
            self.version = request_raw[i .. i + version_end];
            for (supported_versions) |supported_version| {
                if (mem.eql(u8, self.version, supported_version)) {
                    break;
                }
            } else {
                return HttpError.HttpVersionNotSupported;
            }
            i += version_end + 2;

            var has_host_header = false;
            while (i < request_raw.len) {
                if (i + 1 < request_raw.len and request_raw[i] == '\r' and request_raw[i + 1] == '\n') {
                    i += 2;
                    break;
                }

                const line_end = std.mem.indexOfScalarPos(u8, request_raw, i, '\r') orelse return HttpError.BadRequest;
                if (line_end + 1 >= request_raw.len or request_raw[line_end + 1] != '\n') {
                    return HttpError.BadRequest;
                }
                const colon_pos = std.mem.indexOfScalar(u8, request_raw[i..line_end], ':') orelse return HttpError.BadRequest;

                // No trimming of the name: whitespace before the colon must be rejected
                // (RFC 9112 §5.1), otherwise proxies and this server may disagree on the headers.
                const key = request_raw[i .. i + colon_pos];
                if (!http_header.isValidName(key)) {
                    return HttpError.BadRequest;
                }
                const value = std.mem.trim(u8, request_raw[i + colon_pos + 1 .. line_end], " \t");

                capitalizeHeaderName(@constCast(key));

                const entry = try self.*.headers.*.getOrPut(key);
                if (entry.found_existing) {
                    // These decide how the request is routed and framed, so a repeated value is
                    // ambiguous (and a request smuggling vector). Other repeated headers keep the
                    // last value.
                    if (isSingletonHeader(key)) {
                        return HttpError.BadRequest;
                    }
                }
                entry.key_ptr.* = key;
                entry.value_ptr.* = value;

                if (std.mem.eql(u8, key, "Host")) {
                    has_host_header = isValidHost(value);
                }

                i = line_end + 2;
            }

            if (!has_host_header) {
                return HttpError.BadRequest;
            }

            if (i < request_raw.len) {
                self.*.body = request_raw[i..];
            }
        }

        fn isSingletonHeader(name: []const u8) bool {
            return std.mem.eql(u8, name, "Host") or
                std.mem.eql(u8, name, "Content-Length") or
                std.mem.eql(u8, name, "Transfer-Encoding");
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

        fn isValidHost(host: []const u8) bool {
            if (std.Io.net.IpAddress.parseLiteral(host)) |_| {
                return true;
            } else |_| {
                var iterator = std.mem.splitScalar(u8, host, ':');
                if (iterator.next()) |hostname| {
                    if (!isValidDomain(hostname)) return false;
                    if (iterator.next()) |port| {
                        return isValidPort(port);
                    }
                    return true;
                }
                return false;
            }
        }

        fn isValidPort(port: []const u8) bool {
            if (port.len == 0) return false;
            const p = std.fmt.parseInt(u16, port, 10) catch return false;
            return p > 0;
        }

        fn isValidDomain(domain: []const u8) bool {
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

        pub fn isKeepAlive(self: *Self) bool {
            const connection_header = self.*.getHeader("Connection");

            if (connection_header) |header| {
                if (!std.ascii.eqlIgnoreCase(header, "keep-alive")) {
                    return false;
                }
            }

            return true;
        }
    };
}

const test_allowed_methods: *const [6][]const u8 = &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD" };

test "Request initialization and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    try testing.expect(request.body == null);

    request.deinit(&map_pool);
}

test "parse simple GET request" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectEqualStrings("GET", request.method);
    try testing.expectEqualStrings("/index.html", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqual(@as(?[]const u8, null), request.body);

    try testing.expectEqualStrings("example.com", request.getHeader("Host").?);
    try testing.expectEqualStrings("test-agent", request.getHeader("User-Agent").?);

    request.deinit(&map_pool);
}

test "parse POST request with body" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw =
        "POST /submit HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 18\r\n" ++
        "\r\n" ++
        "{\"key\": \"value\"}";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectEqualStrings("POST", request.method);
    try testing.expectEqualStrings("/submit", request.path);
    try testing.expectEqualStrings("HTTP/1.1", request.version);
    try testing.expectEqualStrings("{\"key\": \"value\"}", request.body.?);

    try testing.expectEqualStrings("application/json", request.getHeader("Content-Type").?);
    try testing.expectEqualStrings("18", request.getHeader("Content-Length").?);

    request.deinit(&map_pool);
}

test "header name capitalization" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "content-type: text/html\r\n" ++
        "user-AGENT: test-agent\r\n" ++
        "x-custom-header: value\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expect(request.getHeader("Content-Type") != null);
    try testing.expect(request.getHeader("User-Agent") != null);
    try testing.expect(request.getHeader("X-Custom-Header") != null);

    request.deinit(&map_pool);
}

test "invalid request format" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    try testing.expectError(HttpError.BadRequest, request.parseRequest(@constCast("GET HTTP/1.1\r\n\r\n"), test_allowed_methods));

    try testing.expectError(HttpError.HttpVersionNotSupported, request.parseRequest(@constCast("GET /path HTTP/1\r\n\r\n"), test_allowed_methods));

    try testing.expectError(HttpError.BadRequest, request.parseRequest(@constCast("GET /path HTTP/1.1\r\ninvalidheader\r\n\r\n"), test_allowed_methods));

    request.deinit(&map_pool);
}

test "request with multiple headers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Accept: text/html\r\n" ++
        "Accept-Language: en-US\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectEqual(@as(usize, 4), request.headers.*.count());
    try testing.expectEqualStrings("example.com", request.getHeader("Host").?);
    try testing.expectEqualStrings("text/html", request.getHeader("Accept").?);
    try testing.expectEqualStrings("en-US", request.getHeader("Accept-Language").?);
    try testing.expectEqualStrings("keep-alive", request.getHeader("Connection").?);

    request.deinit(&map_pool);
}

test "request with empty headers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "Empty-Header: \r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectEqual(@as(usize, 2), request.headers.*.count());
    try testing.expectEqualStrings("", request.getHeader("Empty-Header").?);

    request.deinit(&map_pool);
}

test "request with query parameters" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);

    const request_raw =
        "GET /path?param1=value1&param2=value2&flag HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectEqualStrings("/path", request.path);

    try testing.expectEqual(@as(usize, 3), request.params.*.count());
    try testing.expectEqualStrings("value1", request.params.*.get("param1").?);
    try testing.expectEqualStrings("value2", request.params.*.get("param2").?);
    try testing.expectEqualStrings("", request.params.*.get("flag").?);

    request.deinit(&map_pool);
}

test "test basic chunked body parsing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try request.parseChunkedBody();

    try testing.expectEqualStrings("MozillaDeveloperNetwork", request.body.?);
}

test "test with empty chunk in the middle" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(HttpError.BadRequest, request.parseChunkedBody());
}

test "test with decimal chunk size" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try request.parseChunkedBody();

    try testing.expectEqualStrings("0123456789", request.body.?);
}

test "test with missing terminating chunk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(HttpError.BadRequest, request.parseChunkedBody());
}

test "test with invalid chunk size" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(error.InvalidCharacter, request.parseChunkedBody());
}

test "test with chunk size too large (would go beyond end of body)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(HttpError.BadRequest, request.parseChunkedBody());
}

test "test with missing CRLF after chunk data" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(HttpError.BadRequest, request.parseChunkedBody());
}

test "test with content after final chunk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

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
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expectError(HttpError.BadRequest, request.parseChunkedBody());
}

/// Parses `head` and returns `bodyLength(data)` for it.
fn testBodyLength(head: []const u8, data: []const u8) !?usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const mutable_head = try allocator.dupe(u8, head);
    try request.parseRequest(mutable_head, test_allowed_methods);

    return request.bodyLength(data);
}

const content_length_head =
    "POST / HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "Content-Length: 5\r\n" ++
    "\r\n";

const chunked_head =
    "POST / HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "\r\n";

const next_request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";

test "bodyLength with Content-Length matching the data" {
    try testing.expectEqual(@as(?usize, 5), try testBodyLength(content_length_head, "Hello"));
}

test "bodyLength with Content-Length greater than the data waits for more" {
    try testing.expectEqual(@as(?usize, null), try testBodyLength(content_length_head, "Hel"));
}

test "bodyLength with Content-Length less than the data leaves the rest for the next request" {
    try testing.expectEqual(@as(?usize, 5), try testBodyLength(content_length_head, "Hello" ++ next_request));
}

test "bodyLength with Content-Length zero" {
    const head = "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n";
    try testing.expectEqual(@as(?usize, 0), try testBodyLength(head, ""));
}

test "bodyLength rejects a Content-Length that is not a plain number" {
    const head = "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: +5\r\n\r\n";
    try testing.expectError(HttpError.BadRequest, testBodyLength(head, "Hello"));
}

test "bodyLength with a complete chunked body" {
    const body = "5\r\nHello\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, body.len), try testBodyLength(chunked_head, body));
}

test "bodyLength with a chunked body followed by a pipelined request" {
    const body = "5\r\nHello\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, body.len), try testBodyLength(chunked_head, body ++ next_request));
}

test "bodyLength with an incomplete chunked body waits for more" {
    try testing.expectEqual(@as(?usize, null), try testBodyLength(chunked_head, "5\r\nHello\r\n"));
}

test "bodyLength is not fooled by a terminator inside chunk data" {
    // The chunk data is "0\r\n\r\n", which the old implementation mistook for the last chunk.
    try testing.expectEqual(@as(?usize, null), try testBodyLength(chunked_head, "5\r\n0\r\n\r\n\r\n"));

    const body = "5\r\n0\r\n\r\n\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, body.len), try testBodyLength(chunked_head, body));
}

test "bodyLength with chunk extensions and trailers" {
    const body = "5;name=value\r\nHello\r\n0\r\nX-Trailer: 1\r\n\r\n";
    try testing.expectEqual(@as(?usize, body.len), try testBodyLength(chunked_head, body));
}

test "bodyLength with both Content-Length and Transfer-Encoding chunked" {
    const head =
        "POST / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Content-Length: 5\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    try testing.expectError(HttpError.BadRequest, testBodyLength(head, "5\r\nHello\r\n0\r\n\r\n"));
}

test "bodyLength rejects unsupported transfer encodings" {
    const head = "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\n";
    try testing.expectError(HttpError.BadRequest, testBodyLength(head, "data"));
}

test "bodyLength without Content-Length or Transfer-Encoding is zero, even with more data" {
    const head = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    try testing.expectEqual(@as(?usize, 0), try testBodyLength(head, ""));
    try testing.expectEqual(@as(?usize, 0), try testBodyLength(head, next_request));
}

test "headLength waits for the empty line" {
    const Request = GenericRequest(void);
    try testing.expectEqual(@as(?usize, null), Request.headLength("GET / HTTP/1.1\r\nHost: exa"));
    try testing.expectEqual(@as(?usize, null), Request.headLength("GET / HTTP/1.1\r\nHost: example.com\r\n"));
    try testing.expectEqual(@as(?usize, next_request.len), Request.headLength(next_request ++ "GET"));
}

/// Parses `raw` as a request head and returns the result of parseRequest.
fn testParse(raw: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    try request.parseRequest(try allocator.dupe(u8, raw), test_allowed_methods);
}

test "parseRequest rejects duplicated framing and routing headers" {
    try testing.expectError(HttpError.BadRequest, testParse("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n"));
    try testing.expectError(HttpError.BadRequest, testParse("GET / HTTP/1.1\r\nHost: example.com\r\nHost: other.com\r\n\r\n"));
    try testing.expectError(HttpError.BadRequest, testParse("POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n\r\n"));
}

test "parseRequest keeps the last value of other repeated headers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const raw = "GET / HTTP/1.1\r\nHost: example.com\r\nAccept: text/html\r\naccept: application/json\r\n\r\n";
    try request.parseRequest(try allocator.dupe(u8, raw), test_allowed_methods);

    try testing.expectEqual(@as(usize, 2), request.headers.*.count());
    try testing.expectEqualStrings("application/json", request.getHeader("Accept").?);
}

test "parseRequest rejects invalid header names and line endings" {
    // Whitespace between the name and the colon.
    try testing.expectError(HttpError.BadRequest, testParse("POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length : 5\r\n\r\n"));
    // Empty name.
    try testing.expectError(HttpError.BadRequest, testParse("GET / HTTP/1.1\r\nHost: example.com\r\n: value\r\n\r\n"));
    // Bare CR inside the head.
    try testing.expectError(HttpError.BadRequest, testParse("GET / HTTP/1.1\r\nHost: example.com\rX-Other: 1\r\n\r\n"));
}

test "isKeepAlive with keep-alive header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expect(request.isKeepAlive());
}

test "isKeepAlive with close header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expect(!request.isKeepAlive());
}

test "isKeepAlive with no Connection header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expect(request.isKeepAlive());
}

test "isKeepAlive with mixed case Connection header" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Connection: Keep-Alive\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    try testing.expect(request.isKeepAlive());
}

test "host validation with valid IP address" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: 192.168.1.1\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with valid IP address and port" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: 192.168.1.1:8080\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with valid domain name" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with valid domain name and subdomain" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: sub.example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with valid domain name and port" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.com:8080\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with domain containing hyphens" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: my-example-domain.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);
}

test "host validation with invalid domain starting with hyphen" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: -example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(HttpError.BadRequest, request.parseRequest(mutable_request, test_allowed_methods));
}

test "host validation with invalid domain ending with hyphen" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example-.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(HttpError.BadRequest, request.parseRequest(mutable_request, test_allowed_methods));
}

test "host validation with invalid domain containing invalid character" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: example!.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(HttpError.BadRequest, request.parseRequest(mutable_request, test_allowed_methods));
}

test "host validation with empty host" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "GET / HTTP/1.1\r\n" ++
        "Host: \r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(HttpError.BadRequest, request.parseRequest(mutable_request, test_allowed_methods));
}

test "validate method function with invalid method" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = try StringMapPool.init(allocator);

    var request = try GenericRequest(void).init(&map_pool);
    defer request.deinit(&map_pool);

    const request_raw =
        "INVALID / HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try testing.expectError(HttpError.MethodNotAllowed, request.parseRequest(mutable_request, test_allowed_methods));
}
