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
const azig = @import("azig.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server(void, void).init(&allocator, azig.Config{}, on_response, {});
    try server.start();
}

fn on_response(_: *azig.Request, _: *azig.Response) !void {
}
```

### Global Context

In case you want to pass data to all the requests, you can use the global AppContext.

```zig
const std = @import("std");
const azig = @import("azig.zig");

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

    const server = azig.Server(AppContext, void).init(&allocator, azig.Config{}, on_response, app_context);
    try server.start();
}

fn on_response(_: *AppContext, _: *azig.Request, _: *azig.Response) !void {}
```

### Request Context

For data that is only meant to be accessed by a single request, use the RequestContext. The data herer will be set by middleware.

```zig
const std = @import("std");
const azig = @import("azig.zig");

const AppContext = struct {
  db_connection: u16,
};

const RequestContext = struct {
    user: []u8
};

const Request = azig.request_t(RequestContext);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app_context = try allocator.create(AppContext);
    app_context.*.db_connection = 123;
    defer allocator.destroy(app_context);

    const server = azig.Server(AppContext, RequestContext).init(&allocator, azig.Config{}, on_response, app_context);
    try server.start();
}

fn on_response(_: *AppContext, request: *Request, _: *azig.Response) !void {
    _ = request.context;
}
```