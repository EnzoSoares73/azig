# A fast, asynchronous HTTP server in Zig

This is an implementation of an HTTP server in Zig built upon the amazing [libuv](https://github.com/libuv/libuv). It
works on the latest version of Zig.

## Table of Contents

* [Installation](#installation)
* [Basic use](#basic-use)
* [Global Context](#global-context)

### Instalation

Run

```
zig fetch --save git+https://github.com/EnzoSoares73/azig.git
```

and add the following to your ```build.zig```:

```zig
const azig = b.dependency("azig", .{
    .target = target,
    .optimize = optimize,
}).module("azig");
exe.root_module.addImport("azig", azig);
```

### Basic use

```zig
const std = @import("std");
const azig = @import("azig.zig").Azig(void, void);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = azig.Server.init(&allocator, azig.Config{}, on_response, {});
    try server.start();
}

fn on_response(_: *azig.Request, _: *azig.Response) !void {
}
```

### Global Context

In case you want to pass data to all the requests, you can use the global AppContext.

```zig
const std = @import("std");
const azig = @import("azig.zig").Azig(AppContext, void);

const AppContext = struct {
  db_connection: u16,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app_context = try allocator.create(AppContext);
    app_context.*.db_connection = 123;
    defer allocator.destroy(app_context);

    const server = azig.Server.init(&allocator, azig.Config{}, on_response, app_context);
    try server.start();
}

fn on_response(_: *AppContext, _: *azig.Request, _: *azig.Response) !void {}
```

### Request Context

For data that is only meant to be accessed by a single request, use the RequestContext. The data here will be set by middleware.

```zig
const std = @import("std");
const azig = @import("azig.zig").Azig(AppContext, RequestContext);

const AppContext = struct {
  db_connection: u16,
};

const RequestContext = struct {
    user: []u8
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app_context = try allocator.create(AppContext);
    app_context.*.db_connection = 123;
    defer allocator.destroy(app_context);

    const server = azig.Server.init(&allocator, azig.Config{}, on_response, app_context);
    try server.start();
}

fn on_response(_: *AppContext, request: *azig.Request, _: *azig.Response) !void {
    _ = request.context;
}
```

### Middlewares

To define a middleware, use the server.register_middleware function:

```zig
const std = @import("std");
const azig = @import("azig.zig").Azig(void, void);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = azig.Server.init(&allocator, azig.Config{}, on_response, {});
    server.register_middleware(&.{middleware1, middleware2});
    try server.start();
}

fn on_response(request: *azig.Request, _: *azig.Response) !void {
    request.printSelf();
}

fn middleware1(_: *azig.Request, _: *azig.Response, action: azig.Action) !void {
    std.debug.print("Mid 1 start\n", .{});
    try action.next();
    std.debug.print("Mid 1 end\n", .{});
}

fn middleware2(_: *azig.Request, _: *azig.Response, action: azig.Action) !void {
    std.debug.print("Mid 2 start\n", .{});
    try action.next();
    std.debug.print("Mid 2 end\n", .{});
}
```

The action.next() call simply calls the next middleware on the list or the on_response callback, in case there are none left.