const constants = @import("constants.zig");

pub const Config = struct {
    port: u16 = constants.DEFAULT_PORT,
};