pub fn Azig(comptime AppContext: type, comptime RequestContext: type) type {
    return struct {
        pub const Server = @import("server.zig").Server(AppContext, RequestContext);
        pub const Request = @import("http/request.zig").GenericRequest(RequestContext);
        pub const Response = @import("http/response.zig").Response;
        pub const Config = @import("config.zig").Config;
        pub const Action = @import("action.zig").GenericAction(AppContext, RequestContext);
        pub const Router = @import("router.zig").GenericRouter(AppContext, RequestContext);
        /// Errors that handlers and middlewares can return to send the matching status code.
        pub const HttpError = @import("http/http_error.zig").HttpError;
        pub const CorsOptions = @import("middlewares/cors.zig").CorsOptions;

        /// CORS middleware; register it first on the root router. See `CorsOptions`.
        pub fn cors(comptime opts: CorsOptions) @import("constants.zig").Middleware(AppContext, RequestContext) {
            return @import("middlewares/cors.zig").CorsMiddleware(AppContext, RequestContext, opts);
        }
    };
}
