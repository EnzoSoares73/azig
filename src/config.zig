const constants = @import("constants.zig");

pub const Config = struct {
    port: u16 = constants.DEFAULT_PORT,
    pool_size: u16 = constants.DEFAULT_POOL_SIZE,
    timeout: u64 = constants.DEFAULT_INACTIVITY_TIMEOUT,
    backlog_size: u16 = constants.DEFAULT_BACKLOG_SIZE,
    listen_address: []const u8 = constants.DEFAULT_LISTEN_ADDRESS,
};