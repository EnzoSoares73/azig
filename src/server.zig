const std = @import("std");
const libuv = @import("libuv.zig").libuv;
const mem = std.mem;
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const callback_t = @import("constants.zig").callback_t;

pub fn Server(comptime AppContext: type) type {
    return struct {
        allocator: *mem.Allocator,
        config: Config = .{},
        callback: callback_t(AppContext),
        app_context: if (AppContext == void) void else *AppContext,

        const Self = @This();

        pub fn init(allocator: *mem.Allocator, config: Config, callback: callback_t(AppContext), app_context: if (AppContext == void) void else *AppContext) Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .callback = callback,
                .app_context = app_context,
            };
        }

        pub fn start(self: Self) !void {
            try libuv(AppContext).libuv_execute(self.allocator, self.config, self.callback, if (AppContext == void) undefined else self.app_context);
        }
    };
}
