const request_t = @import("request.zig").request_t;
const Response = @import("response.zig").Response;
const middleware_t = @import("constants.zig").middleware_t;
const callback_t = @import("constants.zig").callback_t;


pub fn action_t(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);
    const callback_fn = callback_t(AppContext, RequestContext);

    return struct {
        const Self = @This();

        request: *Request,
        response: *Response,
        index: u8,
        app_context: *AppContext,
        middleware_list: []const middleware_t(AppContext, RequestContext),
        callback: callback_fn,

        pub fn next(self: Self) !void {
            if (self.index == self.middleware_list.len) {
                if (AppContext == void) {
                    try self.callback(self.request, self.response);
                } else {
                    try self.callback(self.app_context, self.request, self.response);
                }
            } else {
                const middleware = self.middleware_list[self.index];
                const action: Self = .{
                    .index = self.index + 1,
                    .request = self.request,
                    .response = self.response,
                    .app_context = self.app_context,
                    .middleware_list = self.middleware_list,
                    .callback = self.callback,
                };
                if (AppContext == void) {
                    try middleware(self.request, self.response, action);
                } else {
                    try middleware(self.app_context, self.request, self.response, action);
                }
            }
        }
    };
}

const std = @import("std");
const testing = std.testing;
const map_t = @import("constants.zig").map_t;

test "action_t with void AppContext calls callback when no middlewares" {
    const TestRequestContext = void;
    const AppContext = void;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    const Request = request_t(TestRequestContext);
    var request = try Request.init(&map_pool);

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    const Callback = callback_t(AppContext, TestRequestContext);
    const callback: Callback = struct {
        fn cb(inner_request: *Request, _: *Response) !void {
            inner_request.version = "HTTP/1.2";
        }
    }.cb;

    var action = action_t(AppContext, TestRequestContext){
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
    const TestRequestContext = struct {
        counter: u8
    };
    const AppContext = void;
    const Action = action_t(AppContext, TestRequestContext);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    const Request = request_t(TestRequestContext);
    var request = try Request.init(&map_pool);
    request.context.counter = 0;

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    const Callback = callback_t(AppContext, TestRequestContext);
    const callback: Callback = struct {
        fn cb(inner_request: *Request, _: *Response) !void {
            inner_request.context.counter = 2;
        }
    }.cb;

    const middleware1 = struct {
        fn mw(inner_request: *Request, _: *Response, _: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 0);
            inner_request.context.counter = 1;
        }
    }.mw;

    const middlewares = [_]middleware_t(AppContext, TestRequestContext){ middleware1 };

    var action = Action{
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
    const TestRequestContext = struct {
        counter: u8
    };
    const AppContext = void;
    const Action = action_t(AppContext, TestRequestContext);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var map_pool = map_t.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    const Request = request_t(TestRequestContext);
    var request = try Request.init(&map_pool);
    request.context.counter = 0;

    const request_raw: []const u8 =
        "GET /index.html HTTP/1.1\r\n" ++
        "host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "\r\n";

    const mutable_request = try allocator.dupe(u8, request_raw);
    defer allocator.free(mutable_request);
    try request.parse_request(mutable_request);

    const Callback = callback_t(AppContext, TestRequestContext);
    const callback: Callback = struct {
        fn cb(inner_request: *Request, _: *Response) !void {
            try testing.expectEqual(inner_request.context.counter, 2);
            inner_request.context.counter = 3;
        }
    }.cb;

    const middleware1 = struct {
        fn mw(inner_request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 0);
            inner_request.context.counter = 1;
            try action.next();
            try testing.expectEqual(inner_request.context.counter, 4);
            inner_request.context.counter = 5;
        }
    }.mw;

    const middleware2 = struct {
        fn mw(inner_request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(inner_request.context.counter, 1);
            inner_request.context.counter = 2;
            try action.next();
            try testing.expectEqual(inner_request.context.counter, 3);
            inner_request.context.counter = 4;
        }
    }.mw;

    const middlewares = [_]middleware_t(AppContext, TestRequestContext){ middleware1, middleware2 };

    var action = Action{
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

    var map_pool = map_t.init(allocator);

    var response = try Response.init(&arena, &map_pool);

    const Request = request_t(TestRequestContext);
    var request = try Request.init(&map_pool);

    const Callback = callback_t(AppContext, TestRequestContext);
    const callback: Callback = struct {
        fn cb(_: *Request, _: *Response) !void {
            return error.TestError;
        }
    }.cb;

    var action = action_t(AppContext, TestRequestContext){
        .request = &request,
        .response = &response,
        .index = 0,
        .app_context = undefined,
        .middleware_list = &.{},
        .callback = callback,
    };

    try testing.expectError(error.TestError, action.next());
}
