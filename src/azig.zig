const std = @import("std");
const testing = std.testing;
const server_t = @import("server.zig").Server;
const request_t = @import("request.zig").request_t;
const response_t = @import("response.zig").Response;
const config_t = @import("config.zig").Config;
const action_t = @import("action.zig");

pub fn Azig(comptime AppContext: type, comptime RequestContext: type) type {
    return struct {
        pub const Server = server_t(AppContext, RequestContext);
        pub const Request = @import("request.zig").request_t(RequestContext);
        pub const Response = response_t;
        pub const Config = config_t;
        pub const Action = @import("action.zig").action_t(AppContext, RequestContext);
    };
}

test {
    testing.refAllDecls(@This());
}
