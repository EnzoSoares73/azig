const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const mem = std.mem;

pub const DEFAULT_PORT: u16 = 2500;

pub const callback_t = * const fn (mem.Allocator, *Request, *Response) anyerror!void;