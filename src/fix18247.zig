const std = @import("std");

pub fn main() !void {
    //fixes ziglang/zig#18247
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    const file = try std.fs.cwd().openFile(".zig-cache/o/c23aee56233546a4f7866a501ad826d8/cimport.zig", .{ .mode = .read_write });
    defer file.close();

    const file_size = try file.getEndPos();
    const file_contents = try file.readToEndAlloc(allocator, file_size);
    defer allocator.free(file_contents);

    const old_str = "pub const uv_read_cb = ?*const fn ([*c]uv_stream_t, isize, [*c]const uv_buf_t) callconv(.c) void;";
    const new_str = "pub const uv_read_cb = ?*const fn (*anyopaque, isize, [*c]const uv_buf_t) callconv(.c) void;";

    var replaced = try std.ArrayList(u8).initCapacity(allocator, file_contents.len);
    defer replaced.deinit();

    var remaining = file_contents;
    while (std.mem.indexOf(u8, remaining, old_str)) |pos| {
        try replaced.appendSlice(remaining[0..pos]);
        try replaced.appendSlice(new_str);
        remaining = remaining[pos + old_str.len ..];
    }
    try replaced.appendSlice(remaining);

    try file.seekTo(0);
    try file.setEndPos(0);
    try file.writeAll(replaced.items);
}