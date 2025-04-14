const std = @import("std");
const callback_t = @import("constants.zig").callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const request_pool_t = @import("constants.zig").request_pool_t;
const response_pool_t = @import("constants.zig").response_pool_t;
const client_pool_t = @import("constants.zig").client_pool_t;
const write_req_pool_t = @import("constants.zig").write_req_pool_t;
const context_pool_t = @import("constants.zig").context_pool_t;

pub const Context = struct {
    allocator: *std.mem.Allocator,
    callback: callback_t,
    buffer_allocator: *buffer_pool_t,
    request_allocator: *request_pool_t,
    response_allocator: *response_pool_t,
    client_allocator: *client_pool_t,
    write_req_allocator: *write_req_pool_t,
};