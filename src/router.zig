const std = @import("std");
const Middleware = @import("constants.zig").Middleware;
const Callback = @import("constants.zig").Callback;
const Response = @import("response.zig").Response;
const GenericRequest = @import("request.zig").GenericRequest;

/// Maximum number of `:param` segments a single route may capture.
pub const max_params = 8;

/// Path parameters captured by `match`. Values are slices into the matched path.
pub const Params = struct {
    names: [max_params][]const u8 = undefined,
    values: [max_params][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.names[0..self.len], self.values[0..self.len]) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }
};

pub fn GenericRouter(comptime AppContext: type, comptime RequestContext: type) type {
    const MiddlewareFn = Middleware(AppContext, RequestContext);
    const CallbackFn = Callback(AppContext, RequestContext);
    const Request = GenericRequest(RequestContext);

    return struct {
        const Self = @This();

        path: []const u8 = "",
        middlewares: []const MiddlewareFn = &.{},
        handlers: []const Handler = &.{},
        routes: []const Self = &.{},

        pub const Handler = struct {
            /// Relative to the router's path; "" is the router's path itself. Segments starting
            /// with ':' are params: "/users/:id".
            path: []const u8 = "",
            /// The method this handler answers. `null` answers every method.
            method: ?std.http.Method = .GET,
            callback: CallbackFn,
            /// Run after the routers' middlewares, for this handler only.
            middlewares: []const MiddlewareFn = &.{},

            pub fn get(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .GET, .callback = callback };
            }
            pub fn post(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .POST, .callback = callback };
            }
            pub fn put(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .PUT, .callback = callback };
            }
            pub fn patch(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .PATCH, .callback = callback };
            }
            pub fn delete(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .DELETE, .callback = callback };
            }
            pub fn head(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .HEAD, .callback = callback };
            }
            pub fn options(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = .OPTIONS, .callback = callback };
            }
            /// Answers every method.
            pub fn any(path: []const u8, callback: CallbackFn) Handler {
                return .{ .path = path, .method = null, .callback = callback };
            }
        };

        /// A resolved route: its handler plus every middleware from the root down to it, in order.
        pub const Entry = struct {
            handler: Handler,
            middlewares: []const MiddlewareFn,
        };

        pub const MatchError = error{
            NotFound,
            MethodNotAllowed,
        };

        pub const Miss = struct {
            /// Middlewares of the deepest router whose path the request is under
            middlewares: []const MiddlewareFn,
            /// The value of the `Allow` header ("GET, HEAD, POST") when the path exists, "" otherwise.
            allow: []const u8,
        };

        /// `method` is null for methods `std.http.Method` does not know; only handlers with a
        /// `null` method answer those.
        pub const MatchFn = *const fn (method: ?std.http.Method, path: []const u8, params: *Params) MatchError!*const Entry;

        pub const RouteInfo = struct {
            /// `null` for handlers that answer every method.
            method: ?std.http.Method,
            /// Full path from the root: "/api/v1/users/:id". "*" for a root that handles every path.
            path: []const u8,
        };

        /// Runtime handle to a compiled router, independent of the comptime tree it came from.
        pub const Table = struct {
            match: MatchFn,
            /// Called once `match` failed for `path`.
            miss: *const fn (path: []const u8) Miss,
            /// Every handler, in declaration order.
            list: []const RouteInfo,
        };

        pub fn failWith(err: MatchError) CallbackFn {
            return switch (err) {
                error.NotFound => failCallback(error.NotFound),
                error.MethodNotAllowed => failCallback(error.MethodNotAllowed),
            };
        }

        fn failCallback(comptime err: MatchError) CallbackFn {
            return if (AppContext == void) struct {
                fn f(_: std.Io, _: *Request, _: *Response) anyerror!void {
                    return err;
                }
            }.f else struct {
                fn f(_: *AppContext, _: std.Io, _: *Request, _: *Response) anyerror!void {
                    return err;
                }
            }.f;
        }

        /// Compiles the router tree into a segment radix tree at comptime.
        ///
        /// Matching never backtracks: at each segment a static child wins over a `:param` child.
        /// So that this never causes a false 404, any static segment that sits beside a `:param`
        /// must provide every route the param branch provides below it; otherwise compilation fails.
        ///
        /// A root router without `routes` whose handlers all have an empty path handles every path.
        pub fn Compiled(comptime root: Self) type {
            return struct {
                const nodes: []const CNode = build(root);
                const catch_all = isCatchAll(root);

                pub const list: []const RouteInfo = listRoutes(root);

                pub const table: Table = .{ .match = match, .miss = miss, .list = list };

                pub fn match(method: ?std.http.Method, path: []const u8, params: *Params) MatchError!*const Entry {
                    const n, _ = walk(path, params);
                    return pick(n orelse {
                        params.len = 0;
                        return error.NotFound;
                    }, method);
                }

                pub fn miss(path: []const u8) Miss {
                    var params: Params = .{};
                    const n, const middlewares = walk(path, &params);
                    return .{ .middlewares = middlewares, .allow = if (n) |found| found.allow else "" };
                }

                fn walk(path: []const u8, params: *Params) struct { ?*const CNode, []const MiddlewareFn } {
                    params.len = 0;
                    var middlewares = nodes[0].mount.?;
                    if (comptime catch_all) return .{ &nodes[0], middlewares };
                    var cur: u16 = 0;
                    var it = std.mem.tokenizeScalar(u8, path, '/');
                    while (it.next()) |seg| {
                        const n = &nodes[cur];
                        if (n.static.get(seg)) |next| {
                            cur = next;
                        } else if (n.param) |p| {
                            // Cannot overflow: param depth is checked against max_params at comptime.
                            params.names[params.len] = p.name;
                            params.values[params.len] = seg;
                            params.len += 1;
                            cur = p.child;
                        } else return .{ null, middlewares };
                        if (nodes[cur].mount) |m| middlewares = m;
                    }
                    const n = &nodes[cur];
                    return .{ if (n.entries.len == 0) null else n, middlewares };
                }
            };
        }

        fn listRoutes(comptime root: Self) []const RouteInfo {
            comptime {
                @setEvalBranchQuota(1_000_000);
                var out = collectRoutes(root, "");
                if (isCatchAll(root)) {
                    var all: [out.len]RouteInfo = undefined;
                    for (out, 0..) |r, i| all[i] = .{ .method = r.method, .path = "*" };
                    out = &all;
                }
                const final = out[0..out.len].*;
                return &final;
            }
        }

        fn collectRoutes(comptime router: Self, comptime prefix: []const u8) []const RouteInfo {
            const base = normalize(prefix ++ "/" ++ router.path);
            var out: []const RouteInfo = &.{};
            for (router.handlers) |h| {
                out = out ++ &[_]RouteInfo{.{ .method = h.method, .path = normalize(base ++ "/" ++ h.path) }};
            }
            for (router.routes) |r| out = out ++ collectRoutes(r, base);
            return out;
        }

        fn isCatchAll(comptime root: Self) bool {
            if (root.routes.len != 0 or root.handlers.len == 0 or root.path.len != 0) return false;
            for (root.handlers) |h| {
                if (h.path.len != 0) return false;
            }
            return true;
        }

        fn pick(n: *const CNode, method: ?std.http.Method) MatchError!*const Entry {
            for (n.entries) |*e| {
                const m = e.handler.method orelse return e;
                if (method == m) return e;
            }
            // HEAD is answered by the GET handler; the server drops the body.
            if (method == .HEAD) for (n.entries) |*e| {
                if (e.handler.method == .GET) return e;
            };
            return error.MethodNotAllowed;
        }

        /// "GET, HEAD, POST": the methods of `entries`, plus HEAD when GET answers it. Every
        /// method when one handler answers them all.
        fn allowHeader(comptime entries: []const Entry) []const u8 {
            var has_get = false;
            var has_head = false;
            for (entries) |e| {
                const m = e.handler.method orelse return allowHeaderAll();
                if (m == .GET) has_get = true;
                if (m == .HEAD) has_head = true;
            }
            var out: []const u8 = "";
            for (std.meta.tags(std.http.Method)) |m| {
                var listed = m == .HEAD and has_get and !has_head;
                for (entries) |e| {
                    if (e.handler.method.? == m) listed = true;
                }
                if (listed) out = out ++ (if (out.len == 0) "" else ", ") ++ @tagName(m);
            }
            return out;
        }

        fn allowHeaderAll() []const u8 {
            var out: []const u8 = "";
            for (std.meta.tags(std.http.Method)) |m| out = out ++ (if (out.len == 0) "" else ", ") ++ @tagName(m);
            return out;
        }

        const CNode = struct {
            static: std.StaticStringMap(u16),
            param: ?struct { name: []const u8, child: u16 },
            /// One per method, or a single one with a `null` method.
            entries: []const Entry,
            /// `Allow` header value for this path.
            allow: []const u8,
            /// Middlewares (from the root down) that every router mounted on this node shares, if any.
            mount: ?[]const MiddlewareFn,
        };

        const max_nodes = 512;
        const max_children = 32;
        const max_methods = @typeInfo(std.http.Method).@"enum".field_names.len;

        const BuildNode = struct {
            keys: [max_children][]const u8 = undefined,
            vals: [max_children]u16 = undefined,
            len: usize = 0,
            param_name: ?[]const u8 = null,
            param_child: u16 = 0,
            entries: [max_methods]Entry = undefined,
            entries_len: usize = 0,
            mount: ?[]const MiddlewareFn = null,
            /// Route that created this node, for error messages.
            path: []const u8 = "/",
            /// Number of params captured on the way to this node.
            depth: usize = 0,

            fn handlers(self: *const BuildNode) []const Entry {
                return self.entries[0..self.entries_len];
            }

            /// Whether a request with `method` reaches a handler here (not a 405).
            fn answers(self: *const BuildNode, method: ?std.http.Method) bool {
                for (self.handlers()) |e| {
                    const m = e.handler.method orelse return true;
                    if (method == m) return true;
                }
                return false;
            }

            fn find(self: *const BuildNode, seg: []const u8) ?u16 {
                for (self.keys[0..self.len], self.vals[0..self.len]) |k, v| {
                    if (std.mem.eql(u8, k, seg)) return v;
                }
                return null;
            }
        };

        fn build(comptime root: Self) []const CNode {
            comptime {
                @setEvalBranchQuota(1_000_000);
                var nodes: [max_nodes]BuildNode = undefined;
                // The root's middlewares cover every path, even outside a root `path`.
                nodes[0] = .{ .mount = root.middlewares };
                var count: u16 = 1;
                insert(&nodes, &count, 0, root, &.{});
                checkShadowing(nodes[0..count], 0);

                var out: [count]CNode = undefined;
                for (nodes[0..count], 0..) |*b, i| {
                    var kvs: [b.len]struct { []const u8, u16 } = undefined;
                    for (0..b.len) |j| kvs[j] = .{ b.keys[j], b.vals[j] };
                    const entries = b.entries[0..b.entries_len].*;
                    out[i] = .{
                        .static = .initComptime(kvs),
                        .param = if (b.param_name) |name| .{ .name = name, .child = b.param_child } else null,
                        .entries = &entries,
                        .allow = allowHeader(&entries),
                        .mount = b.mount,
                    };
                }
                const final = out; // const copy, so the pointer may escape to runtime
                return &final;
            }
        }

        fn insert(
            comptime nodes: *[max_nodes]BuildNode,
            comptime count: *u16,
            comptime parent: u16,
            comptime router: Self,
            comptime inherited: []const MiddlewareFn,
        ) void {
            const at = descend(nodes, count, parent, router.path);
            const mws: []const MiddlewareFn = inherited ++ router.middlewares;
            mount(&nodes[at], mws);

            for (router.handlers) |h| {
                const n = &nodes[descend(nodes, count, at, h.path)];
                for (n.handlers()) |e| {
                    if (e.handler.method == null or h.method == null)
                        @compileError("route " ++ n.path ++ " has a handler for any method and another one; keep only one");
                    if (e.handler.method == h.method)
                        @compileError("duplicate route: " ++ @tagName(h.method.?) ++ " " ++ n.path);
                }
                n.entries[n.entries_len] = .{ .handler = h, .middlewares = mws ++ h.middlewares };
                n.entries_len += 1;
            }

            for (router.routes, 0..) |r, i| {
                // Routers without a path only group handlers; any number of them may sit side by side.
                for (router.routes[0..i]) |prev| {
                    if (r.path.len != 0 and prev.path.len != 0 and std.mem.eql(u8, normalize(prev.path), normalize(r.path)))
                        @compileError("routers with the same path under " ++ nodes[at].path ++ ": \"" ++
                            prev.path ++ "\" and \"" ++ r.path ++ "\"; merge them into one");
                }
                insert(nodes, count, at, r, mws);
            }
        }

        /// The node `path` leads to from `at`, created as needed.
        fn descend(comptime nodes: *[max_nodes]BuildNode, comptime count: *u16, comptime at: u16, comptime path: []const u8) u16 {
            var cur = at;
            var it = std.mem.tokenizeScalar(u8, path, '/');
            while (it.next()) |seg| cur = childOf(nodes, count, cur, seg);
            return cur;
        }

        /// Records that a router whose middlewares are `mws` covers the paths below `n`. When
        /// several routers cover the same node (a router without a path, or "/a/b" next to "/a"
        /// then "/b"), misses there run only the middlewares they all share.
        fn mount(comptime n: *BuildNode, comptime mws: []const MiddlewareFn) void {
            const existing = n.mount orelse {
                n.mount = mws;
                return;
            };
            var shared: usize = 0;
            while (shared < existing.len and shared < mws.len and existing[shared] == mws[shared]) shared += 1;
            n.mount = existing[0..shared];
        }

        /// "/a//b/" -> "/a/b", "" -> "/".
        fn normalize(comptime path: []const u8) []const u8 {
            var out: []const u8 = "";
            var it = std.mem.tokenizeScalar(u8, path, '/');
            while (it.next()) |seg| out = out ++ "/" ++ seg;
            return if (out.len == 0) "/" else out;
        }

        fn childOf(comptime nodes: *[max_nodes]BuildNode, comptime count: *u16, comptime at: u16, comptime seg: []const u8) u16 {
            const n = &nodes[at];
            const sep = if (std.mem.eql(u8, n.path, "/")) "" else "/";
            if (seg[0] == ':') {
                const name = seg[1..];
                if (name.len == 0) @compileError("empty param name under " ++ n.path);
                var ancestors = std.mem.tokenizeScalar(u8, n.path, '/');
                while (ancestors.next()) |prev| {
                    if (prev[0] == ':' and std.mem.eql(u8, prev[1..], name))
                        @compileError("param :" ++ name ++ " appears twice in route " ++ n.path ++ sep ++ seg);
                }
                if (n.param_name) |existing| {
                    if (!std.mem.eql(u8, existing, name))
                        @compileError("conflicting params under " ++ n.path ++ ": :" ++ existing ++ " vs :" ++ name);
                    return n.param_child;
                }
                if (n.depth + 1 > max_params) @compileError("too many params in route " ++ n.path ++ sep ++ seg);
                const id = newNode(nodes, count, n.path ++ sep ++ seg, n.depth + 1);
                n.param_name = name;
                n.param_child = id;
                return id;
            }
            if (n.find(seg)) |v| return v;
            if (n.len == max_children) @compileError("too many static children under " ++ n.path);
            const id = newNode(nodes, count, n.path ++ sep ++ seg, n.depth);
            n.keys[n.len] = seg;
            n.vals[n.len] = id;
            n.len += 1;
            return id;
        }

        fn newNode(comptime nodes: *[max_nodes]BuildNode, comptime count: *u16, comptime path: []const u8, comptime depth: usize) u16 {
            if (count.* == max_nodes) @compileError("too many route nodes; raise max_nodes in router.zig");
            nodes[count.*] = .{ .path = path, .depth = depth };
            count.* += 1;
            return count.* - 1;
        }

        /// Rejects trees where "static beats param" would make a param route unreachable.
        fn checkShadowing(comptime nodes: []const BuildNode, comptime at: u16) void {
            const n = &nodes[at];
            for (n.vals[0..n.len]) |v| checkShadowing(nodes, v);
            if (n.param_name != null) {
                for (n.vals[0..n.len]) |v| covers(nodes, v, n.param_child);
                checkShadowing(nodes, n.param_child);
            }
        }

        /// Every path that reaches an entry through `p` must also reach one through `s`.
        fn covers(comptime nodes: []const BuildNode, comptime s: u16, comptime p: u16) void {
            const sn = &nodes[s];
            const pn = &nodes[p];
            const msg = "route " ++ sn.path ++ " shadows " ++ pn.path ++ " (no backtracking): ";
            for (pn.handlers()) |e| {
                if (!sn.answers(e.handler.method))
                    @compileError(msg ++ "add a " ++ (if (e.handler.method) |m| @tagName(m) else "any-method") ++
                        " handler at " ++ sn.path);
            }
            for (pn.keys[0..pn.len], pn.vals[0..pn.len]) |k, v| {
                const sv = sn.find(k) orelse @compileError(msg ++ "add " ++ sn.path ++ "/" ++ k);
                covers(nodes, sv, v);
            }
            if (pn.param_name) |name| {
                if (sn.param_name == null) @compileError(msg ++ "add " ++ sn.path ++ "/:" ++ name);
                covers(nodes, sn.param_child, pn.param_child);
            }
        }
    };
}

const testing = std.testing;
const TestRouter = GenericRouter(void, void);
const TestRequest = @import("request.zig").GenericRequest(void);
const TestAction = @import("action.zig").GenericAction(void, void);

fn cb(comptime tag: u8) Callback(void, void) {
    return struct {
        fn f(_: std.Io, _: *TestRequest, _: *Response) anyerror!void {
            _ = tag;
        }
    }.f;
}

fn testMiddleware(_: std.Io, _: *TestRequest, _: *Response, action: TestAction) anyerror!void {
    try action.next();
}

fn testMiddleware2(_: std.Io, _: *TestRequest, _: *Response, action: TestAction) anyerror!void {
    try action.next();
}

const test_root: TestRouter = .{
    .middlewares = &.{testMiddleware},
    .handlers = &.{ .get("/", cb(0)), .get("/health", cb(1)) },
    .routes = &.{.{
        .path = "/api/v1",
        .middlewares = &.{testMiddleware2},
        .handlers = &.{
            .get("/users", cb(2)),
            .get("/users/me", cb(3)),
            .get("/users/:id", cb(4)),
            .get("/users/:id/posts/:post", cb(5)),
            .get("/users/me/posts/:post", cb(6)),
        },
    }},
};

const TestCompiled = TestRouter.Compiled(test_root);

fn expectHandler(path: []const u8, comptime tag: u8) !*const TestRouter.Entry {
    var params: Params = .{};
    const entry = try TestCompiled.match(.GET, path, &params);
    try testing.expectEqual(cb(tag), entry.handler.callback);
    return entry;
}

test "router: static routes and root" {
    _ = try expectHandler("/", 0);
    _ = try expectHandler("", 0);
    _ = try expectHandler("/health", 1);
    _ = try expectHandler("/health/", 1);
    _ = try expectHandler("/api/v1/users", 2);
}

test "router: static beats param" {
    _ = try expectHandler("/api/v1/users/me", 3);
    _ = try expectHandler("/api/v1/users/me/posts/9", 6);
    _ = try expectHandler("/api/v1/users/2/posts/9", 5);
}

test "router: params are captured" {
    var params: Params = .{};
    const entry = try TestCompiled.match(.GET, "/api/v1/users/42/posts/7", &params);
    try testing.expectEqual(cb(5), entry.handler.callback);
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("42", params.get("id").?);
    try testing.expectEqualStrings("7", params.get("post").?);
    try testing.expectEqual(@as(?[]const u8, null), params.get("missing"));

    _ = try expectHandler("/api/v1/users/42", 4);
}

test "router: middlewares are joined root to leaf" {
    const top = try expectHandler("/health", 1);
    try testing.expectEqual(@as(usize, 1), top.middlewares.len);

    const nested = try expectHandler("/api/v1/users/42", 4);
    try testing.expectEqual(@as(usize, 2), nested.middlewares.len);
    try testing.expectEqual(nested.middlewares[0], &testMiddleware);
    try testing.expectEqual(nested.middlewares[1], &testMiddleware2);
}

test "router: unknown paths are not found" {
    var params: Params = .{};
    try testing.expectError(error.NotFound, TestCompiled.match(.GET, "/nope", &params));
    try testing.expectError(error.NotFound, TestCompiled.match(.GET, "/api", &params));
    try testing.expectError(error.NotFound, TestCompiled.match(.GET, "/api/v1/users/1/posts", &params));
    try testing.expectEqualStrings("", TestCompiled.miss("/nope").allow);
}

test "router: a miss runs the middlewares of the deepest router the path is under" {
    // Root: [testMiddleware]; "/api/v1": [testMiddleware, testMiddleware2].
    try testing.expectEqual(@as(usize, 1), TestCompiled.miss("/nope").middlewares.len);
    // "/api" is only a step of the "/api/v1" router: no router is mounted there.
    try testing.expectEqual(@as(usize, 1), TestCompiled.miss("/api").middlewares.len);
    const nested = TestCompiled.miss("/api/v1/nope");
    try testing.expectEqual(@as(usize, 2), nested.middlewares.len);
    try testing.expectEqual(nested.middlewares[1], &testMiddleware2);
    try testing.expectEqual(@as(usize, 2), TestCompiled.miss("/api/v1/users/1/posts").middlewares.len);

    // A 405 runs the middlewares of the router the handlers belong to.
    var params: Params = .{};
    try testing.expectError(error.MethodNotAllowed, TestCompiled.match(.PUT, "/api/v1/users", &params));
    const not_allowed = TestCompiled.miss("/api/v1/users");
    try testing.expectEqual(@as(usize, 2), not_allowed.middlewares.len);
    try testing.expectEqualStrings("GET, HEAD", not_allowed.allow);
}

test "router: params are cleared when nothing is found" {
    var params: Params = .{};
    try testing.expectError(error.NotFound, TestCompiled.match(.GET, "/api/v1/users/42/nope", &params));
    try testing.expectEqual(@as(usize, 0), params.len);
    try testing.expectError(error.MethodNotAllowed, TestCompiled.match(.POST, "/api/v1/users/42", &params));
    try testing.expectEqualStrings("42", params.get("id").?);
}

test "router: failWith ends the chain with the lookup error" {
    var request: TestRequest = undefined;
    var response: Response = undefined;
    try testing.expectError(error.NotFound, TestRouter.failWith(error.NotFound)(testing.io, &request, &response));
    try testing.expectError(error.MethodNotAllowed, TestRouter.failWith(error.MethodNotAllowed)(testing.io, &request, &response));
}

test "router: a root with only path-less handlers handles every path" {
    const Catch = TestRouter.Compiled(.{ .handlers = &.{.get("", cb(7))} });
    var params: Params = .{};
    try testing.expectEqual(cb(7), (try Catch.match(.GET, "/", &params)).handler.callback);
    try testing.expectEqual(cb(7), (try Catch.match(.GET, "/any/thing", &params)).handler.callback);

    // "/" is an ordinary path.
    const Root = TestRouter.Compiled(.{ .handlers = &.{.get("/", cb(7))} });
    try testing.expectEqual(cb(7), (try Root.match(.GET, "/", &params)).handler.callback);
    try testing.expectError(error.NotFound, Root.match(.GET, "/any/thing", &params));
}

test "router: handler paths are relative to their router" {
    const Nested = TestRouter.Compiled(.{
        .path = "/api",
        .routes = &.{.{
            .path = "/users",
            .handlers = &.{ .get("", cb(1)), .get("/:id", cb(2)), .post("/", cb(3)) },
        }},
    });
    var params: Params = .{};
    try testing.expectEqual(cb(1), (try Nested.match(.GET, "/api/users", &params)).handler.callback);
    try testing.expectEqual(cb(2), (try Nested.match(.GET, "/api/users/5", &params)).handler.callback);
    try testing.expectEqual(cb(3), (try Nested.match(.POST, "/api/users", &params)).handler.callback);
    try testing.expectError(error.NotFound, Nested.match(.GET, "/users", &params));
}

test "router: handler middlewares run last, and only for that handler" {
    const Admin = TestRouter.Compiled(.{
        .middlewares = &.{testMiddleware},
        .handlers = &.{
            .get("/admin", cb(1)),
            .{ .path = "/admin", .method = .DELETE, .callback = cb(2), .middlewares = &.{testMiddleware2} },
        },
    });
    var params: Params = .{};
    const get = try Admin.match(.GET, "/admin", &params);
    try testing.expectEqual(@as(usize, 1), get.middlewares.len);
    const delete = try Admin.match(.DELETE, "/admin", &params);
    try testing.expectEqual(@as(usize, 2), delete.middlewares.len);
    try testing.expectEqual(delete.middlewares[1], &testMiddleware2);
    // A 405 on that path runs the router's middlewares, not the handlers' own.
    try testing.expectError(error.MethodNotAllowed, Admin.match(.PUT, "/admin", &params));
    try testing.expectEqual(@as(usize, 1), Admin.miss("/admin").middlewares.len);
}

test "router: a router without a path groups handlers under extra middlewares" {
    const Grouped = TestRouter.Compiled(.{
        .middlewares = &.{testMiddleware},
        .handlers = &.{.get("/public", cb(1))},
        .routes = &.{.{ .middlewares = &.{testMiddleware2}, .handlers = &.{.get("/secret", cb(2))} }},
    });
    var params: Params = .{};
    try testing.expectEqual(@as(usize, 1), (try Grouped.match(.GET, "/public", &params)).middlewares.len);
    try testing.expectEqual(@as(usize, 2), (try Grouped.match(.GET, "/secret", &params)).middlewares.len);
    // Both routers cover the root: misses run only the middlewares they share.
    try testing.expectEqual(@as(usize, 1), Grouped.miss("/nope").middlewares.len);
}

const method_root: TestRouter = .{ .middlewares = &.{testMiddleware}, .handlers = &.{
    .get("/users", cb(1)),
    .post("/users", cb(2)),
    .delete("/users/:id", cb(3)),
    .any("/any", cb(4)),
    .head("/head", cb(5)),
    .get("/head", cb(6)),
} };

const MethodCompiled = TestRouter.Compiled(method_root);

fn expectMethodHandler(method: ?std.http.Method, path: []const u8, comptime tag: u8) !void {
    var params: Params = .{};
    const entry = try MethodCompiled.match(method, path, &params);
    try testing.expectEqual(cb(tag), entry.handler.callback);
}

fn expectNotAllowed(method: ?std.http.Method, path: []const u8, allow: []const u8) !void {
    var params: Params = .{};
    try testing.expectError(error.MethodNotAllowed, MethodCompiled.match(method, path, &params));
    try testing.expectEqualStrings(allow, MethodCompiled.miss(path).allow);
    try testing.expectEqualStrings(allow, MethodCompiled.table.miss(path).allow);
}

test "router: handlers default to GET, and the constructors set the method" {
    const handler: TestRouter.Handler = .{ .callback = cb(0) };
    try testing.expectEqual(@as(?std.http.Method, .GET), handler.method);
    try testing.expectEqualStrings("", handler.path);
    const constructors = [_]struct { TestRouter.Handler, ?std.http.Method }{
        .{ .get("/x", cb(0)), .GET },         .{ .post("/x", cb(0)), .POST },
        .{ .put("/x", cb(0)), .PUT },         .{ .patch("/x", cb(0)), .PATCH },
        .{ .delete("/x", cb(0)), .DELETE },   .{ .head("/x", cb(0)), .HEAD },
        .{ .options("/x", cb(0)), .OPTIONS }, .{ .any("/x", cb(0)), null },
    };
    for (constructors) |c| {
        try testing.expectEqual(c[1], c[0].method);
        try testing.expectEqualStrings("/x", c[0].path);
    }
}

test "router: the same path routes by method" {
    try expectMethodHandler(.GET, "/users", 1);
    try expectMethodHandler(.POST, "/users", 2);
    try expectMethodHandler(.DELETE, "/users/7", 3);
}

test "router: HEAD falls back to GET unless it has its own handler" {
    try expectMethodHandler(.HEAD, "/users", 1);
    try expectMethodHandler(.HEAD, "/head", 5);
    try expectMethodHandler(.GET, "/head", 6);
}

test "router: a null method answers every method" {
    for (std.meta.tags(std.http.Method)) |m| try expectMethodHandler(m, "/any", 4);
    try expectMethodHandler(null, "/any", 4);
}

test "router: a known path with another method is not allowed" {
    try expectNotAllowed(.PUT, "/users", "GET, HEAD, POST");
    try expectNotAllowed(null, "/users", "GET, HEAD, POST");
    try expectNotAllowed(.GET, "/users/7", "DELETE");
    try expectNotAllowed(.POST, "/head", "GET, HEAD");
    try testing.expectEqualStrings("GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH, QUERY", MethodCompiled.miss("/any").allow);
}

test "router: unknown paths are not found whatever the method" {
    var params: Params = .{};
    try testing.expectError(error.NotFound, MethodCompiled.match(.POST, "/nope", &params));
    try testing.expectError(error.NotFound, MethodCompiled.match(.GET, "/users/7/extra", &params));
}

test "router: a catch-all root answers only its methods" {
    const PostOnly = TestRouter.Compiled(.{ .handlers = &.{.post("", cb(8))} });
    var params: Params = .{};
    try testing.expectEqual(cb(8), (try PostOnly.match(.POST, "/some/path", &params)).handler.callback);
    try testing.expectError(error.MethodNotAllowed, PostOnly.match(.GET, "/some/path", &params));
    try testing.expectEqualStrings("POST", PostOnly.miss("/some/path").allow);

    const Guarded = TestRouter.Compiled(.{ .middlewares = &.{testMiddleware}, .handlers = &.{.post("", cb(9))} });
    try testing.expectEqual(@as(usize, 1), Guarded.miss("/some/path").middlewares.len);
}

test "router: lists every route in declaration order" {
    const expected = [_]TestRouter.RouteInfo{
        .{ .method = .GET, .path = "/" },
        .{ .method = .GET, .path = "/health" },
        .{ .method = .GET, .path = "/api/v1/users" },
        .{ .method = .GET, .path = "/api/v1/users/me" },
        .{ .method = .GET, .path = "/api/v1/users/:id" },
        .{ .method = .GET, .path = "/api/v1/users/:id/posts/:post" },
        .{ .method = .GET, .path = "/api/v1/users/me/posts/:post" },
    };
    try testing.expectEqual(expected.len, TestCompiled.table.list.len);
    for (expected, TestCompiled.table.list) |e, r| {
        try testing.expectEqual(e.method, r.method);
        try testing.expectEqualStrings(e.path, r.path);
    }

    const Nested = TestRouter.Compiled(.{
        .path = "api",
        .routes = &.{.{ .path = "/users/", .handlers = &.{ .get("", cb(1)), .any("/:id", cb(2)) } }},
    });
    try testing.expectEqualStrings("/api/users", Nested.list[0].path);
    try testing.expectEqualStrings("/api/users/:id", Nested.list[1].path);
    try testing.expectEqual(@as(?std.http.Method, null), Nested.list[1].method);

    const Catch = TestRouter.Compiled(.{ .handlers = &.{ .get("", cb(1)), .post("", cb(2)) } });
    try testing.expectEqual(@as(usize, 2), Catch.list.len);
    try testing.expectEqualStrings("*", Catch.list[1].path);
    try testing.expectEqual(@as(?std.http.Method, .POST), Catch.list[1].method);
}
