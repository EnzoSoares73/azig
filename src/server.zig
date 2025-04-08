const std = @import("std");
const libuv_execute = @import("libuv.zig").libuv_execute;
const mem = std.mem;
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const callback_t = @import("constants.zig").callback_t;

pub const Server = struct {
    allocator: *mem.Allocator,
    config: Config = .{},
    callback: callback_t,

    const Self = @This();

    pub fn init(allocator: *mem.Allocator, config: Config, callback: callback_t) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .callback = callback,
        };
    }

    pub fn start(self: Self) !void {
        try libuv_execute(self.allocator, self.config, self.callback);
    }
};
