# A fast, asynchronous HTTP server in Zig, using the new std.Io interface

This is an implementation of an HTTP/1.1 server in Zig built upon the amazing [libuv](https://github.com/libuv/libuv).

It requires Zig 0.17.1

## Table of Contents

* [Installation](#installation)
* [Basic use](#basic-use)
* [Handlers and std.Io](#handlers-and-stdio)
* [Routing](#routing)
* [Configuration](#configuration)
* [Responses and errors](#responses-and-errors)
* [Stopping the server](#stopping-the-server)
* [Global Context](#global-context)
* [Request Context](#request-context)
* [Middlewares](#middlewares)

## Installation

Run

```
zig fetch --save git+https://github.com/EnzoSoares73/azig.git
```

and add the following to your `build.zig`:

```zig
const azig = b.dependency("azig", .{
    .target = target,
    .optimize = optimize,
}).module("azig");
exe.root_module.addImport("azig", azig);
```

## Basic use

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, .{ .handlers = &.{.get("/", onResponse)} }, {});
    defer server.deinit();
    try server.start();
}

fn onResponse(_: std.Io, _: *azig.Request, response: *azig.Response) !void {
    try response.addHeader("Content-Type", "text/plain");
    response.body = "Hello, World!";
}
```

`start()` blocks until the server is stopped. The allocator passed to `init` must be thread-safe:

## Handlers and std.Io

Every handler (and middleware) receives a `std.Io`. Use it as you would any other `Io`, for
I/O, sleeping, synchronization and concurrency, with the usual `io.async` / `await`:

```zig
fn getUser(io: std.Io, request: *azig.Request, response: *azig.Response) !void {
    const id = request.query_params.get("id") orelse return error.BadRequest;

    var user = io.async(db.fetchUser, .{ io, id });
    defer _ = user.cancel(io) catch {};
    var orders = io.async(db.fetchOrders, .{ io, id });
    defer _ = orders.cancel(io) catch {};

    response.body = try render(response.arena.allocator(), try user.await(io), try orders.await(io));
}
```

You must:

* **Do all waiting through `io`.** Handlers run on the event loop's thread: code that blocks the
  thread without going through `io` (like a DB call) holds up every request until it returns. This
  includes libraries that keep their own `Io` (for example, one created in `main`): pass them
  the `io` the handler received.
* **Use `io` only inside handlers**, not from other threads.

## Routing

Routes are declared as a tree of `azig.Router` values. A router has a `path`, `middlewares`, its
`handlers` and nested routers in `routes`; every field is optional. A handler is a `path`
(relative to its router), the `method` it answers and a `callback`. `.get(path, callback)`.

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

const router: azig.Router = .{
    .middlewares = &.{logRequest},
    .handlers = &.{.get("/", home)},
    .routes = &.{.{
        .path = "/api/v1",
        .middlewares = &.{authenticate},
        .handlers = &.{
            .get("/users", listUsers),
            .{ .path = "/users", .method = .POST, .callback = createUser, .middlewares = &.{requireAdmin} },
            .get("/users/me", getMe),
            .get("/users/:id", getUser),
            .get("/users/:id/posts/:post", getPost),
            .get("/users/me/posts/:post", getPost),
        },
    }},
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, router, {});
    defer server.deinit();
    try server.start();
}

fn getPost(_: std.Io, request: *azig.Request, response: *azig.Response) !void {
    const user_id = request.path_params.get("id").?;
    const post_id = request.path_params.get("post").?;
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "post {s} of user {s}", .{ post_id, user_id });
}
```

* A router's middlewares run for every route below it, from the root down: in the example,
  `GET /api/v1/users/42` runs `logRequest`, then `authenticate`, then `getUser`, while `GET /`
  only runs `logRequest`, then `home`. A handler's own `middlewares` run last, for that handler
  only: `POST /api/v1/users` also runs `requireAdmin`.
* This includes paths that match no route: their `404` (or `405`) comes after the middlewares of
  the deepest router the path is under. `GET /api/v1/nope` runs `logRequest` and `authenticate`, so
  an unauthenticated client gets the `401` from `authenticate` rather than learning which routes
  exist, while `GET /nope` only runs `logRequest`. A middleware that doesn't call `action.next()`
  stops the chain before the `404`, as usual.
* A root router without `routes`, whose handlers have no path (`.any("", onRequest)`), handles every path.
* The router must be known at compile time.

### Route config

Routers and handlers take an optional `config` (`azig.RouteConfig`). A router's config covers every
route below it; for each field, the value set closest to the handler wins:

```zig
const router: azig.Router = .{ .routes = &.{.{
    .path = "/jobs",
    .config = .{ .status = .accepted },
    .handlers = &.{
        .post("", enqueueJob), // 202
        .{ .path = "/:id", .method = .PUT, .callback = replaceJob, .config = .{ .status = .ok } }, // 200
    },
}} };
```

| Field      | Default | Description                                                                                                             |
|------------|---------|-------------------------------------------------------------------------------------------------------------------------|
| `status`   | `200`   | Status the response starts with, before middlewares and the handler run; they may still change it. Must be 2xx or 3xx. |
| `produces` | none    | Media types the route can send, most preferred first. See [Content negotiation](#content-negotiation).                  |
| `consumes` | none    | Media ranges a request body may have. See [Content negotiation](#content-negotiation).                                  |

### Content negotiation

Content negotiation is how a client and a route agree on the format of what they exchange. The
client says what it sends in `Content-Type` and what it wants back in `Accept`. The route declares
what it handles in its config:

| Config     | Checks the request's | Fails with | The handler finds the result in |
|------------|----------------------|------------|---------------------------------|
| `consumes` | `Content-Type`       | `415`      | `request.content_type`          |
| `produces` | `Accept`             | `406`      | `response.content_type`         |

Both run after the middlewares and right before the handler, `consumes` first. A failed check stops
the request there, so the handler only runs when both sides agree. Like every config field, both
are inherited by the routes below a router, and `&.{}` turns them off for a subtree.

```zig
const router: azig.Router = .{ .routes = &.{.{
    .path = "/api",
    .config = .{ .consumes = &.{"application/json"}, .produces = &.{ "application/json", "text/csv" } },
    .handlers = &.{ .get("/orders", listOrders), .post("/orders", createOrder) },
}} };
```

#### Response types (`produces`)

With `produces`, the request's `Accept` header picks one of the types after the middlewares run
and before the handler does. The handler finds it in `response.content_type`:

```zig
const router: azig.Router = .{
    .config = .{ .produces = &.{ "application/json", "text/html" } },
    .handlers = &.{.get("/report", report)},
};

fn report(_: std.Io, _: *azig.Request, response: *azig.Response) !void {
    response.body = if (std.mem.eql(u8, response.content_type.?, "text/html")) "<h1>Report</h1>" else "{\"report\":1}";
}
```

* Without `Accept`, the first type is chosen. Otherwise each type gets the q-value of the most
  specific range that matches it (`text/html` > `text/*` > `*/*`), and the highest wins; ties
  go to the order in `produces`. Parameters other than `q` are ignored.
* If `Accept` allows none of the types, the response is a `406`. Middlewares run first, so for
  example an unauthenticated client still gets `authenticate`'s `401`.
* `response.content_type` is sent as `Content-Type` when the response has a body, unless the
  handler sets a `Content-Type` header itself. Error responses have no body, so they never claim it.
* With more than one type, `Vary: Accept` is added so caches keep the variants apart.
* Entries must be concrete `type/subtype` values, without wildcards or parameters; this is checked at compile time.

#### Request body types (`consumes`)

With `consumes`, a request body's `Content-Type` must match one of the listed ranges before the
handler runs. The handler finds the body's media type, without parameters, in `request.content_type`:

```zig
const router: azig.Router = .{
    .config = .{ .consumes = &.{ "application/json", "image/*" } },
    .handlers = &.{ .get("/files", listFiles), .post("/files", upload) },
};

fn upload(_: std.Io, request: *azig.Request, response: *azig.Response) !void {
    // "application/json" for `Content-Type: application/json; charset=utf-8`, "image/png", ...
    const kind = request.content_type.?;
    ...
}
```

* Ranges can be `type/subtype`, `type/*` or `*/*`, without parameters; this is checked at compile time.
* Requests without a body (or with an empty one) are not checked, so `GET /files` passes.
* A body whose type matches no range gets a `415`. A body without `Content-Type` counts as
  `application/octet-stream`, so it gets a `415` too unless that type is accepted.
* On a `415`, `POST` responses list the accepted ranges in `Accept-Post`, and `PATCH` responses in `Accept-Patch`.
* A malformed `Content-Type`, or several different ones, gets a `400`.
* Like `produces`, the check runs after the middlewares; when both fail, the `415` wins over the `406`.

## Configuration

`Server.init` takes a `Config` (known at compile time); call `deinit` on the server once `start()` has returned. Every field has a default:

| Field              | Default                                          | Description                                                                                             |
|--------------------|--------------------------------------------------|---------------------------------------------------------------------------------------------------------|
| `port`             | `2500`                                           | Port to listen on.                                                                                      |
| `listen_address`   | `"0.0.0.0"`                                      | IPv4 address to listen on.                                                                              |
| `backlog_size`     | `128`                                            | Maximum number of pending connections.                                                                  |
| `pool_size`        | `1024`                                           | Number of objects (buffers, requests, responses, ...) preallocated per pool. The pools grow as needed.   |
| `timeout`          | `15000`                                          | Milliseconds a connection may stay idle, or a handler may run, before the client gets a `408` (and the handler is canceled). |
| `max_payload_size` | `1048576`                                        | Largest accepted request body, in bytes. Larger bodies get a `413`.                                     |
| `allowed_methods`  | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`  | Requests with any other method get a `405`.                                                             |
| `task_stack_size`  | `4194304`                                        | Stack size of each handler task, in bytes. On Linux and macOS it is only committed as it is used.       |

```zig
var server = try azig.Server.init(allocator, .{
    .port = 8080,
    .listen_address = "127.0.0.1",
    .timeout = 5_000,
}, router, {});
```

`start()` returns an error (for example `error.BindFailed` or `error.ListenFailed` when the port is
already in use) if the server cannot be set up.

## Responses and errors

Memory the response needs to outlive the handler, such as a formatted body, can be allocated
from `response.arena`, which is freed once the response has been sent:

```zig
fn onResponse(_: std.Io, request: *azig.Request, response: *azig.Response) !void {
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "You asked for {s}", .{request.path});
}
```

Returning an error from a handler or middleware sends an error response. Errors from
`azig.HttpError` map to their status code (`error.NotFound` becomes a `404`, and so on); any
other error becomes a `500`. The body is dropped, but the headers set so far are kept, so headers
a middleware adds before calling `action.next()` (CORS, request IDs, ...) are sent with error
responses too.

```zig
fn onResponse(_: std.Io, request: *azig.Request, _: *azig.Response) !void {
    if (!std.mem.eql(u8, request.path, "/")) return error.NotFound;
}
```

`response.addHeader(name, value)` appends a header, so a name can be sent several times (e.g.
`Set-Cookie`); `response.setHeader(name, value)` replaces every previous value.

On the request side, `request.method`, `request.path`, `request.body`, `request.getHeader(name)`,
`request.getHeaders(name)` (every value of a repeated header) and the query parameters in
`request.query_params` are available. Header names are normalized (`content-type` becomes
`Content-Type`), and lookups only match that canonical form: `getHeader("Content-Type")`.

## Stopping the server

`stop()` can be called from any thread. It returns immediately; `start()` returns once open
connections have been closed

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, .{ .handlers = &.{.get("/", onResponse)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, azig.Server.start, .{&server});

    // ...later
    server.stop();
    thread.join();
}

fn onResponse(_: std.Io, _: *azig.Request, _: *azig.Response) !void {}
```

## Global Context

In case you want to pass data to all the requests, you can use the global AppContext.
Handlers then receive it as their first argument.

```zig
const std = @import("std");
const azig = @import("azig").Azig(AppContext, void);

const AppContext = struct {
    db_connection: u16,
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app_context = AppContext{ .db_connection = 123 };

    var server = try azig.Server.init(allocator, .{}, .{ .handlers = &.{.get("/", onResponse)} }, &app_context);
    defer server.deinit();
    try server.start();
}

fn onResponse(_: *AppContext, _: std.Io, _: *azig.Request, _: *azig.Response) !void {}
```

## Request Context

For data that is only meant to be accessed by a single request, use the RequestContext. The data
here will be set by middleware.

```zig
const std = @import("std");
const azig = @import("azig").Azig(AppContext, RequestContext);

const AppContext = struct {
    db_connection: u16,
};

const RequestContext = struct {
    user: []const u8,
};

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var app_context = AppContext{ .db_connection = 123 };

    var server = try azig.Server.init(allocator, .{}, .{
        .middlewares = &.{authenticate},
        .handlers = &.{.get("/", onResponse)},
    }, &app_context);
    defer server.deinit();
    try server.start();
}

fn authenticate(_: *AppContext, _: std.Io, request: *azig.Request, _: *azig.Response, action: azig.Action) !void {
    request.context = .{ .user = request.getHeader("X-User") orelse return error.Unauthorized };
    try action.next();
}

fn onResponse(_: *AppContext, _: std.Io, request: *azig.Request, response: *azig.Response) !void {
    response.body = request.context.user;
}
```

## Middlewares

Middlewares are set on a [`Router`](#routing), and apply to every route below it:

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, .{
        .middlewares = &.{ middleware1, middleware2 },
        .handlers = &.{.get("/", onResponse)},
    }, {});
    defer server.deinit();
    try server.start();
}

fn onResponse(_: std.Io, request: *azig.Request, _: *azig.Response) !void {
    request.printSelf();
}

fn middleware1(_: std.Io, _: *azig.Request, _: *azig.Response, action: azig.Action) !void {
    std.debug.print("Mid 1 start\n", .{});
    try action.next();
    std.debug.print("Mid 1 end\n", .{});
}

fn middleware2(_: std.Io, _: *azig.Request, _: *azig.Response, action: azig.Action) !void {
    std.debug.print("Mid 2 start\n", .{});
    try action.next();
    std.debug.print("Mid 2 end\n", .{});
}
```

The `action.next()` call runs the next middleware, or the route's handler when there are none
left. Middlewares of nested routers come after their parents' ones. A middleware that doesn't call it stops the chain, and the response it set
is sent as is.
