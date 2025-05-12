const request_t = @import("request.zig").request_t;
const Response = @import("response.zig").Response;
const middleware_t = @import("constants.zig").middleware_t;
const callback_t = @import("constants.zig").callback_t;


pub fn action_t(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);
    const callback_fn = callback_t(AppContext, RequestContext);

    return struct {
        const Self = @This();

        request: *Request,
        response: *Response,
        index: u8,
        app_context: *AppContext,
        middleware_list: []const middleware_t(AppContext, RequestContext),
        callback: callback_fn,

        pub fn next(self: Self) !void {
            if (self.index == self.middleware_list.len) {
                if (AppContext == void) {
                    try self.callback(self.request, self.response);
                } else {
                    try self.callback(self.app_context, self.request, self.response);
                }
            } else {
                const middleware = self.middleware_list[self.index];
                const action: Self = .{
                    .index = self.index + 1,
                    .request = self.request,
                    .response = self.response,
                    .app_context = self.app_context,
                    .middleware_list = self.middleware_list,
                    .callback = self.callback,
                };
                if (AppContext == void) {
                    try middleware(self.request, self.response, action);
                } else {
                    try middleware(self.app_context, self.request, self.response, action);
                }
            }
        }
    };
}
