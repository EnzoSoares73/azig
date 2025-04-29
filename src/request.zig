const std = @import("std");
const print = std.debug.print;
const StringHashMap = std.StringHashMap;
const mem = std.mem;
const ascii = std.ascii;
const header_t = @import("constants.zig").header_t;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: *StringHashMap([]const u8),
    body: ?[]const u8,

    const Self = @This();

    pub fn init(header_pool: *header_t) !Self {
        const map = try header_pool.*.create();
        return Self{
            .body = null,
            .headers = map,
            .method = undefined,
            .path = undefined,
            .version = undefined,
        };
    }

    pub fn deinit(self: *Self, header_pool: *header_t) !void {
        try header_pool.*.destroy(self.*.headers);
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

    pub fn getHeader(self: Self, name: []u8) ?[]const u8 {
        return self.headers.*.get(name);
    }

    pub fn parseRequest(self: *Self, request_raw: []u8) !void {
        var i: usize = 0;

        const method_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
        self.method = request_raw[i .. i + method_end];
        i += method_end + 1;

        const path_end = std.mem.indexOfScalar(u8, request_raw[i..], ' ') orelse return error.InvalidRequest;
        self.path = request_raw[i .. i + path_end];
        i += path_end + 1;

        const version_end = std.mem.indexOfScalar(u8, request_raw[i..], '\n') orelse return error.InvalidRequest;
        self.version = request_raw[i .. i + version_end];
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
