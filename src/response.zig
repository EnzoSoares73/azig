const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const header_t = @import("constants.zig").header_t;

pub const ResponseString = struct {
    string: []const u8,
    in_heap: bool,
};

pub const Response = struct {
    status_code: u16,
    headers: *StringHashMap([]const u8),
    body: ?[]const u8,

    const Self = @This();

    pub fn init(header_pool: *header_t) !Self {
        const map = try header_pool.*.create();
        return Self{
            .body = null,
            .headers = map,
            .status_code = 200,
        };
    }

    pub fn deinit(self: *Self, header_pool: *header_t) !void {
        try header_pool.*.destroy(self.*.headers);
        self.* = undefined;
    }

    pub fn addHeader(self: *Self, name: []u8, value: []u8) !void {
        try self.*.headers.*.put(name, value);
    }

    pub fn to_string(self: *Self, allocator: std.mem.Allocator) !ResponseString {
        const size = try self.calculate_serialized_size();

        if (size < 4096) {
            var buffer: [4096]u8 = undefined;
            return .{
                .string = try self.write_to_buffer(&buffer),
                .in_heap = false
            };
        } else {
            const buffer = try allocator.alloc(u8, size);
            errdefer allocator.free(buffer);

            var stream = std.io.fixedBufferStream(buffer);
            try self.write_to_stream(stream.writer());

            return .{
                .string = buffer,
                .in_heap = true
            };
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
            try writer.print("{s}: {s}\r\n", .{entry.key_ptr.*, entry.value_ptr.*});
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