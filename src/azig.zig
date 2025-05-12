const std = @import("std");
const testing = std.testing;

pub fn Azig(comptime AppContext: type, comptime RequestContext: type) type {
    return struct {
        pub const Server = @import("server.zig").Server(AppContext, RequestContext);
        pub const Request = @import("request.zig").request_t(RequestContext);
        pub const Response = @import("response.zig").Response;
        pub const Config = @import("config.zig").Config;
        pub const Action = @import("action.zig").action_t(AppContext, RequestContext);
    };
}

test {
    testing.refAllDecls(@This());
}
