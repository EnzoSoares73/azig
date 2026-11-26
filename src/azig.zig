pub fn Azig(comptime AppContext: type, comptime RequestContext: type) type {
    return struct {
        pub const Server = @import("server.zig").Server(AppContext, RequestContext);
        pub const Request = @import("request.zig").GenericRequest(RequestContext);
        pub const Response = @import("response.zig").Response;
        pub const Config = @import("config.zig").Config;
        pub const Action = @import("action.zig").GenericAction(AppContext, RequestContext);
        pub const Router = @import("router.zig").GenericRouter(AppContext, RequestContext);
        /// Errors that handlers and middlewares can return to send the matching status code.
        pub const HttpError = @import("http_error.zig").HttpError;
    };
}
