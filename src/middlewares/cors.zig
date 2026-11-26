const std = @import("std");
const Middleware = @import("../constants.zig").Middleware;
const Response = @import("../response.zig").Response;
const GenericRequest = @import("../request.zig").GenericRequest;
const GenericAction = @import("../action.zig").GenericAction;

pub const CorsOptions = struct {
    origins: []const []const u8 = &.{"*"},
    credentials: bool = false,
    // In case this is empty, just echo requested headers back
    allow_headers: ?[]const []const u8 = null,
    expose_headers: []const []const u8 = &.{},
    max_age: ?u32 = null,
};

/// This should be the first middleware
pub fn CorsMiddleware(
    comptime AppContext: type,
    comptime RequestContext: type,
    comptime opts: CorsOptions,
) Middleware(AppContext, RequestContext) {
    const Request = GenericRequest(RequestContext);
    const Action = GenericAction(AppContext, RequestContext);

    const Cors = struct {
        const wildcard = for (opts.origins) |o| {
            if (std.mem.eql(u8, o, "*")) break true;
        } else false;

        comptime {
            if (opts.origins.len == 0) @compileError("CorsOptions.origins is empty; no origin would be allowed");
            if (wildcard and opts.credentials)
                @compileError("CorsOptions: browsers reject the \"*\" origin with credentials; list the origins instead");
        }

        const allow_headers: ?[]const u8 = if (opts.allow_headers) |h| join(h) else null;
        const expose_headers = join(opts.expose_headers);
        const max_age: ?[]const u8 = if (opts.max_age) |s| std.fmt.comptimePrint("{d}", .{s}) else null;
        const preflight_vary: ?[]const u8 = if (!wildcard and allow_headers == null)
            "Origin, Access-Control-Request-Headers"
        else if (!wildcard)
            "Origin"
        else if (allow_headers == null)
            "Access-Control-Request-Headers"
        else
            null;

        fn join(comptime list: []const []const u8) []const u8 {
            var out: []const u8 = "";
            for (list) |item| out = out ++ (if (out.len == 0) "" else ", ") ++ item;
            return out;
        }

        fn allowedOrigin(origin: []const u8) ?[]const u8 {
            if (wildcard) return "*";
            for (opts.origins) |o| {
                if (std.mem.eql(u8, o, origin)) return origin;
            }
            return null;
        }

        fn handle(request: *Request, response: *Response, action: Action) !void {
            if (!wildcard) try response.addHeader("Vary", "Origin");

            const origin = request.getHeader("Origin") orelse return action.next();
            const preflight = std.mem.eql(u8, request.method, "OPTIONS") and
                request.getHeader("Access-Control-Request-Method") != null;

            // Unknown path: let the router answer 404.
            if (preflight and action.allow.len == 0) return action.next();

            const allowed = allowedOrigin(origin) orelse return action.next();

            try response.addHeader("Access-Control-Allow-Origin", allowed);
            if (opts.credentials) try response.addHeader("Access-Control-Allow-Credentials", "true");

            if (!preflight) {
                if (expose_headers.len > 0) try response.addHeader("Access-Control-Expose-Headers", expose_headers);
                return action.next();
            }

            response.status_code = 204;
            try response.addHeader("Access-Control-Allow-Methods", action.allow);
            if (allow_headers) |h| {
                if (h.len > 0) try response.addHeader("Access-Control-Allow-Headers", h);
            } else if (request.getHeader("Access-Control-Request-Headers")) |h| {
                try response.addHeader("Access-Control-Allow-Headers", h);
            }
            if (max_age) |s| try response.addHeader("Access-Control-Max-Age", s);
            if (preflight_vary) |v| try response.addHeader("Vary", v);
        }
    };

    return if (AppContext == void) struct {
        fn cb(_: std.Io, request: *Request, response: *Response, action: Action) anyerror!void {
            return Cors.handle(request, response, action);
        }
    }.cb else struct {
        fn cb(_: *AppContext, _: std.Io, request: *Request, response: *Response, action: Action) anyerror!void {
            return Cors.handle(request, response, action);
        }
    }.cb;
}

const testing = std.testing;
const StringMapPool = @import("../constants.zig").StringMapPool;
const Callback = @import("../constants.zig").Callback;
const test_allowed_methods: []const []const u8 = &.{ "GET", "PUT", "OPTIONS" };

const TestRequest = GenericRequest(void);
const TestAction = GenericAction(void, void);

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    map_pool: StringMapPool,
    request: TestRequest,
    response: Response,
    called: bool = false,

    var handler_called = false;

    fn callback(_: std.Io, _: *TestRequest, _: *Response) anyerror!void {
        handler_called = true;
    }

    fn run(self: *Harness, middleware: Middleware(void, void), raw: []const u8, allow: []const u8) !void {
        self.arena = .init(testing.allocator);
        const allocator = self.arena.allocator();
        self.map_pool = try StringMapPool.init(allocator);
        self.response = try Response.init(&self.arena, &self.map_pool);
        self.request = try TestRequest.init(&self.map_pool);
        try self.request.parseRequest(try allocator.dupe(u8, raw), test_allowed_methods);

        handler_called = false;
        const action: TestAction = .{
            .io = testing.io,
            .request = &self.request,
            .response = &self.response,
            .index = 0,
            .app_context = undefined,
            .middleware_list = &.{middleware},
            .callback = callback,
            .allow = allow,
        };
        try action.next();
        self.called = handler_called;
    }

    fn header(self: *Harness, name: []const u8) ?[]const u8 {
        return self.response.headers.get(name);
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }
};

const preflight_raw =
    "OPTIONS /v1/api HTTP/1.1\r\n" ++
    "Host: example.com\r\n" ++
    "Origin: https://app.example.com\r\n" ++
    "Access-Control-Request-Method: PUT\r\n" ++
    "Access-Control-Request-Headers: content-type, authorization\r\n" ++
    "\r\n";

test "preflight from a listed origin is answered without reaching the handler" {
    var h: Harness = undefined;
    try h.run(CorsMiddleware(void, void, .{ .origins = &.{"https://app.example.com"}, .credentials = true, .max_age = 300 }), preflight_raw, "GET, HEAD, PUT");
    defer h.deinit();

    try testing.expect(!h.called);
    try testing.expectEqual(@as(u16, 204), h.response.status_code);
    try testing.expectEqualStrings("https://app.example.com", h.header("Access-Control-Allow-Origin").?);
    try testing.expectEqualStrings("true", h.header("Access-Control-Allow-Credentials").?);
    try testing.expectEqualStrings("GET, HEAD, PUT", h.header("Access-Control-Allow-Methods").?);
    try testing.expectEqualStrings("content-type, authorization", h.header("Access-Control-Allow-Headers").?);
    try testing.expectEqualStrings("300", h.header("Access-Control-Max-Age").?);
    try testing.expectEqualStrings("Origin, Access-Control-Request-Headers", h.header("Vary").?);
}

test "preflight uses the configured header list and the wildcard origin" {
    var h: Harness = undefined;
    try h.run(CorsMiddleware(void, void, .{ .allow_headers = &.{ "Content-Type", "X-Id" }, .max_age = null }), preflight_raw, "GET, HEAD, PUT");
    defer h.deinit();

    try testing.expectEqualStrings("*", h.header("Access-Control-Allow-Origin").?);
    try testing.expectEqualStrings("Content-Type, X-Id", h.header("Access-Control-Allow-Headers").?);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Credentials"));
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Max-Age"));
    try testing.expectEqual(@as(?[]const u8, null), h.header("Vary"));
}

test "preflight from an unlisted origin gets no CORS headers" {
    var h: Harness = undefined;
    try h.run(CorsMiddleware(void, void, .{ .origins = &.{"https://other.example.com"} }), preflight_raw, "GET, HEAD, PUT");
    defer h.deinit();

    try testing.expect(h.called);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Origin"));
    try testing.expectEqualStrings("Origin", h.header("Vary").?);
}

test "preflight to an unknown path is left to the router" {
    var h: Harness = undefined;
    try h.run(CorsMiddleware(void, void, .{}), preflight_raw, "");
    defer h.deinit();

    try testing.expect(h.called);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Origin"));
}

test "cross-origin request gets CORS headers and reaches the handler" {
    var h: Harness = undefined;
    try h.run(
        CorsMiddleware(void, void, .{ .origins = &.{"https://app.example.com"}, .expose_headers = &.{"X-Total"} }),
        "GET /v1/api HTTP/1.1\r\nHost: example.com\r\nOrigin: https://app.example.com\r\n\r\n",
        "GET, HEAD, PUT",
    );
    defer h.deinit();

    try testing.expect(h.called);
    try testing.expectEqual(@as(u16, 200), h.response.status_code);
    try testing.expectEqualStrings("https://app.example.com", h.header("Access-Control-Allow-Origin").?);
    try testing.expectEqualStrings("X-Total", h.header("Access-Control-Expose-Headers").?);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Methods"));
    try testing.expectEqualStrings("Origin", h.header("Vary").?);
}

test "plain OPTIONS and same-origin requests pass through" {
    var h: Harness = undefined;
    try h.run(CorsMiddleware(void, void, .{}), "OPTIONS /v1/api HTTP/1.1\r\nHost: example.com\r\nOrigin: https://app.example.com\r\n\r\n", "GET, HEAD, PUT");
    try testing.expect(h.called);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Methods"));
    h.deinit();

    try h.run(CorsMiddleware(void, void, .{}), "GET /v1/api HTTP/1.1\r\nHost: example.com\r\n\r\n", "GET, HEAD, PUT");
    defer h.deinit();
    try testing.expect(h.called);
    try testing.expectEqual(@as(?[]const u8, null), h.header("Access-Control-Allow-Origin"));
}
