const std = @import("std");
const GenericRequest = @import("http/request.zig").GenericRequest;
const Response = @import("http/response.zig").Response;
const Middleware = @import("constants.zig").Middleware;
const Callback = @import("constants.zig").Callback;
const negotiation = @import("http/negotiation.zig");
const HttpError = @import("http/http_error.zig").HttpError;
const ResolvedRouteConfig = @import("router.zig").ResolvedRouteConfig;

pub fn GenericAction(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = GenericRequest(RequestContext);
    const CallbackFn = Callback(AppContext, RequestContext);

    return struct {
        const Self = @This();

        io: std.Io,
        request: *Request,
        response: *Response,
        index: u8,
        /// The `Allow` value of the request's path ("GET, HEAD, PUT")
        allow: []const u8 = "",
        app_context: *AppContext,
        middleware_list: []const Middleware(AppContext, RequestContext),
        callback: CallbackFn,
        /// The matched route's config; `consumes` and `produces` are checked once the middlewares have run.
        config: *const ResolvedRouteConfig = &ResolvedRouteConfig.default,

        pub fn next(self: Self) !void {
            if (self.index == self.middleware_list.len) {
                if (self.config.consumes.len > 0) try self.checkContentType();
                if (self.config.produces.len > 0) try self.negotiate();
                if (AppContext == void) {
                    try self.callback(self.io, self.request, self.response);
                } else {
                    try self.callback(self.app_context, self.io, self.request, self.response);
                }
            } else {
                const middleware = self.middleware_list[self.index];
                const action: Self = .{
                    .io = self.io,
                    .index = self.index + 1,
                    .request = self.request,
                    .response = self.response,
                    .app_context = self.app_context,
                    .middleware_list = self.middleware_list,
                    .callback = self.callback,
                    .allow = self.allow,
                    .config = self.config,
                };
                if (AppContext == void) {
                    try middleware(self.io, self.request, self.response, action);
                } else {
                    try middleware(self.app_context, self.io, self.request, self.response, action);
                }
            }
        }

        fn negotiate(self: Self) !void {
            const produces = self.config.produces;
            // Caches must not reuse a response for requests with another Accept.
            if (produces.len > 1) try self.response.addHeader("Vary", "Accept");
            const i = negotiation.select(produces, self.request.getHeaders("Accept")) orelse
                return HttpError.NotAcceptable;
            self.response.content_type = produces[i];
        }

        fn checkContentType(self: Self) !void {
            const body = self.request.body orelse return;
            if (body.len == 0) return;
            var values = self.request.getHeaders("Content-Type");
            // RFC 9110 §8.3: a body without a type may be treated as application/octet-stream.
            const value = values.next() orelse "application/octet-stream";
            while (values.next()) |other| {
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, other, " \t"), std.mem.trim(u8, value, " \t")))
                    return HttpError.BadRequest;
            }
            self.request.content_type = negotiation.matchContentType(self.config.consumes, value) catch |err| switch (err) {
                error.Malformed => return HttpError.BadRequest,
                error.Unsupported => {
                    // Tell the client what it may send instead.
                    const method = self.request.method;
                    if (std.mem.eql(u8, method, "POST")) try self.response.addHeader("Accept-Post", self.config.consumes_header);
                    if (std.mem.eql(u8, method, "PATCH")) try self.response.addHeader("Accept-Patch", self.config.consumes_header);
                    return HttpError.UnsupportedMediaType;
                },
            };
        }
    };
}

const testing = std.testing;
const test_allowed_methods: *const [6][]const u8 = &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD" };

test "GenericAction with void AppContext calls callback when no middlewares" {
    const TestRequestContext = void;
    const AppContext = void;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = Response.init(allocator);

    const Request = GenericRequest(TestRequestContext);
    var request = Request.init(allocator);

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    const CallbackFn = Callback(AppContext, TestRequestContext);
    const callback: CallbackFn = struct {
        fn cb(_: std.Io, inner_request: *Request, _: *Response) !void {
            inner_request.version = "HTTP/1.2";
        }
    }.cb;

    var action = GenericAction(AppContext, TestRequestContext){
        .io = testing.io,
        .request = &request,
        .response = &response,
        .index = 0,
        .app_context = undefined,
        .middleware_list = &.{},
        .callback = callback,
    };

    try action.next();

    try testing.expectEqualStrings("HTTP/1.2", request.version);
}

test "should return early if middleware does not call next()" {
    const TestRequestContext = struct { counter: u8 };
    const AppContext = void;
    const Action = GenericAction(AppContext, TestRequestContext);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = Response.init(allocator);

    const Request = GenericRequest(TestRequestContext);
    var request = Request.init(allocator);
    request.context.counter = 0;

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    const CallbackFn = Callback(AppContext, TestRequestContext);
    const callback: CallbackFn = struct {
        fn cb(_: std.Io, inner_request: *Request, _: *Response) !void {
            inner_request.context.counter = 2;
        }
    }.cb;

    const middleware1 = struct {
        fn mw(_: std.Io, inner_request: *Request, _: *Response, _: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 0);
            inner_request.context.counter = 1;
        }
    }.mw;

    const middlewares = [_]Middleware(AppContext, TestRequestContext){middleware1};

    var action = Action{
        .io = testing.io,
        .request = &request,
        .response = &response,
        .index = 0,
        .app_context = undefined,
        .middleware_list = &middlewares,
        .callback = callback,
    };

    try action.next();
    try testing.expectEqual(request.context.counter, 1);
}

test "should call middlewares in order" {
    const TestRequestContext = struct { counter: u8 };
    const AppContext = void;
    const Action = GenericAction(AppContext, TestRequestContext);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = Response.init(allocator);

    const Request = GenericRequest(TestRequestContext);
    var request = Request.init(allocator);
    request.context.counter = 0;

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parseRequest(mutable_request, test_allowed_methods);

    const CallbackFn = Callback(AppContext, TestRequestContext);
    const callback: CallbackFn = struct {
        fn cb(_: std.Io, inner_request: *Request, _: *Response) !void {
            try testing.expectEqual(inner_request.context.counter, 2);
            inner_request.context.counter = 3;
        }
    }.cb;

    const middleware1 = struct {
        fn mw(_: std.Io, inner_request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 0);
            inner_request.context.counter = 1;
            try action.next();
            try testing.expectEqual(inner_request.context.counter, 4);
            inner_request.context.counter = 5;
        }
    }.mw;

    const middleware2 = struct {
        fn mw(_: std.Io, inner_request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 1);
            inner_request.context.counter = 2;
            try action.next();
            try testing.expectEqual(inner_request.context.counter, 3);
            inner_request.context.counter = 4;
        }
    }.mw;

    const middlewares = [_]Middleware(AppContext, TestRequestContext){ middleware1, middleware2 };

    var action = Action{
        .io = testing.io,
        .request = &request,
        .response = &response,
        .index = 0,
        .app_context = undefined,
        .middleware_list = &middlewares,
        .callback = callback,
    };

    try action.next();
    try testing.expectEqual(request.context.counter, 5);
}

test "error raised by callback is captured" {
    const TestRequestContext = void;
    const AppContext = void;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var response = Response.init(allocator);

    const Request = GenericRequest(TestRequestContext);
    var request = Request.init(allocator);

    const CallbackFn = Callback(AppContext, TestRequestContext);
    const callback: CallbackFn = struct {
        fn cb(_: std.Io, _: *Request, _: *Response) !void {
            return error.TestError;
        }
    }.cb;

    var action = GenericAction(AppContext, TestRequestContext){
        .io = testing.io,
        .request = &request,
        .response = &response,
        .index = 0,
        .app_context = undefined,
        .middleware_list = &.{},
        .callback = callback,
    };

    try testing.expectError(error.TestError, action.next());
}
