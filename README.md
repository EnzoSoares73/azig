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
const azig = @import("azig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server(void).init(&allocator, azig.Config{}, on_response, undefined);
    try server.start();
}

fn on_response(_: std.mem.Allocator, _: *void, _: *azig.Request, _: *azig.Response) !void {}
```

### Global Context

```zig
const std = @import("std");
const azig = @import("azig");

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

    const server = azig.Server(AppContext).init(&allocator, azig.Config{}, on_response, app_context);
    try server.start();
}

fn on_response(_: std.mem.Allocator, _: *AppContext, _: *azig.Request, _: *azig.Response) !void {}
```

### Asynchronous tasks

```zig
const std = @import("std");
const azig = @import("azig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server(void).init(&allocator, azig.Config{}, on_response, undefined);
    try server.start();
}

fn on_response(_: std.mem.Allocator, _: *void, _: *azig.Request, _: *azig.Response) !void {
    azig.act_blocking(cb, null);
    azig.act_non_blocking(cb, null);
}

fn cb(_: ?*anyopaque) callconv(.C) void {
    std.time.sleep( * std.time.ns_per_s);
    std.debug.print("{d}\n", .{1});
}
```