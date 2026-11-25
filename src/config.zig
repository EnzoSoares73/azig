const constants = @import("constants.zig");

pub const Config = struct {
    port: u16 = constants.default_port,
    pool_size: u16 = constants.default_pool_size,
    timeout: u64 = constants.default_inactivity_timeout,
    backlog_size: u16 = constants.default_backlog_size,
    listen_address: []const u8 = constants.default_listen_address,
    max_payload_size: u64 = constants.default_max_payload_size,
    allowed_methods: []const []const u8 = constants.default_allowed_methods,
    /// Stack size of each request handler. Handlers run as fibers on the event loop; on POSIX
    /// systems the stack is only committed as it is used.
    task_stack_size: usize = constants.default_task_stack_size,
};
