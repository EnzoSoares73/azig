# A fast, asynchronous HTTP server in Zig

This is an implementation of an HTTP server in Zig built upon the amazing [libuv](https://github.com/libuv/libuv). It
works on the latest version of Zig.

## Table of Contents

* [Installation](#installation)
* [How to use](#How to use)

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

### How to use

```zig
const std = @import("std");
const azig = @import("azig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const server = azig.Server.init(&allocator, azig.Config{}, on_response);
    try server.start();
}

fn on_response(_: std.mem.Allocator, _: *azig.Request, _: *azig.Response) !void {}
```