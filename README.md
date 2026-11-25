# A fast, asynchronous HTTP server in Zig

This is an implementation of an HTTP/1.1 server in Zig built upon the amazing [libuv](https://github.com/libuv/libuv).

Handlers receive a standard `std.Io` and run as lightweight tasks on libuv's event loop, so a
handler waiting on I/O (a slow database query, say) doesn't hold up other requests. It requires Zig 0.17.

## Table of Contents

* [Installation](#installation)
* [Basic use](#basic-use)
* [Handlers and std.Io](#handlers-and-stdio)
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

    var server = try azig.Server.init(allocator, .{}, onResponse, {});
    defer server.deinit();
    try server.start();
}

fn onResponse(_: std.Io, _: *azig.Request, response: *azig.Response) !void {
    try response.addHeader("Content-Type", "text/plain");
    response.body = "Hello, World!";
}
```

`start()` blocks until the server is stopped. The allocator passed to `init` must be thread-safe:
blocking operations performed through the handlers' `io` run on worker threads.

## Handlers and std.Io

Every handler (and middleware) receives a `std.Io`. Use it as you would any other `Io`, for
I/O, sleeping, synchronization and concurrency, with the usual `io.async` / `await`:

```zig
fn getUser(io: std.Io, request: *azig.Request, response: *azig.Response) !void {
    const id = request.params.get("id") orelse return error.BadRequest;

    var user = io.async(db.fetchUser, .{ io, id });
    defer _ = user.cancel(io) catch {};
    var orders = io.async(db.fetchOrders, .{ io, id });
    defer _ = orders.cancel(io) catch {};

    response.body = try render(response.arena.allocator(), try user.await(io), try orders.await(io));
}
```

Each request's handler runs as a task with its own stack (a fiber) on the server's event loop.
When it waits through `io`, its task is suspended and the loop serves other requests, so slow
handlers don't stall the server, and thousands of waiting handlers cost memory rather than
threads. Tasks, groups, cancelation, sleeping and `Io.Mutex` / `Io.Condition` / `Io.Queue` are
handled on the loop itself; files, sockets, DNS and other blocking operations are performed by
worker threads (an internal `std.Io.Threaded`) while the task waits.

You must:

* **Do all waiting through `io`.** Handlers run on the event loop's thread: code that blocks the
  thread without going through `io` (like a DB call) holds up every request until it returns. This
  includes libraries that keep their own `Io` (for example, one created in `main`): pass them
  the `io` the handler received.
* **Use `io` only inside handlers**, not from other threads.
* **Timeouts cancel the handler.** If a handler runs longer than `timeout`, the client gets a
  `408` and the handler is canceled: its next (or current) `io` call returns `error.Canceled`.
  The same happens when the client disconnects or the server stops. Operations performed by the
  worker threads are not interrupted; the cancelation takes effect once they return. Use
  `io.swapCancelProtection` to protect code that must not be interrupted.

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
}, onResponse, {});
```

`start()` returns an error (for example `error.BindFailed` or `error.ListenFailed` when the port is
already in use) if the server cannot be set up.

## Responses and errors

Set `response.status_code` (defaults to `200`), `response.body` and headers through
`response.addHeader`. `Content-Length` is added automatically. `addHeader` returns
`error.InvalidHeader` for names that are not valid header names and for values containing CR,
LF or NUL, which would otherwise allow header injection.

Memory the response needs to outlive the handler, such as a formatted body, can be allocated
from `response.arena`, which is freed once the response has been sent:

```zig
fn onResponse(_: std.Io, request: *azig.Request, response: *azig.Response) !void {
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "You asked for {s}", .{request.path});
}
```

Returning an error from a handler or middleware sends an error response. Errors from
`azig.HttpError` map to their status code (`error.NotFound` becomes a `404`, and so on); any
other error becomes a `500`.

```zig
fn onResponse(_: std.Io, request: *azig.Request, _: *azig.Response) !void {
    if (!std.mem.eql(u8, request.path, "/")) return error.NotFound;
}
```

On the request side, `request.method`, `request.path`, `request.body`, `request.getHeader(name)`
and the query parameters in `request.params` are available. Header names are normalized
(`content-type` becomes `Content-Type`).

## Stopping the server

`stop()` can be called from any thread. It returns immediately; `start()` returns once open
connections have been closed and the handlers still running, which are canceled, have finished.

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, onResponse, {});
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

    var server = try azig.Server.init(allocator, .{}, onResponse, &app_context);
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

    var server = try azig.Server.init(allocator, .{}, onResponse, &app_context);
    defer server.deinit();
    server.registerMiddlewares(&.{authenticate});
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

To define middlewares, use the `server.registerMiddlewares` function:

```zig
const std = @import("std");
const azig = @import("azig").Azig(void, void);

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server = try azig.Server.init(allocator, .{}, onResponse, {});
    defer server.deinit();
    server.registerMiddlewares(&.{ middleware1, middleware2 });
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

The `action.next()` call runs the next middleware in the list, or the response callback when
there are none left. A middleware that doesn't call it stops the chain, and the response it set
is sent as is.
