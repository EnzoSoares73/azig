const std = @import("std");
const parse_data = @import("parse_data.zig").parse_data;
const serve = @import("server.zig").serve;
const print = std.debug.print;
const mem = std.mem;
const net = std.net;
const StringHashMap = std.StringHashMap;
const uv = @cImport({
    @cInclude("uv.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //try run_naive(allocator);
    //try run_threaded(allocator);
    try run_eloop(allocator);
}

fn run_naive(allocator: mem.Allocator) !void {
    var server = try serve();

    while (server.accept()) |connection| {
        print("Accepted connection from: {}\n\n", .{connection.address});
        try parse_data(allocator, connection);
    } else |err| {
        return err;
    }
}

fn run_threaded(allocator: mem.Allocator) !void {
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = try std.Thread.getCpuCount() / 2,
    });
    defer pool.deinit();
    var wg: std.Thread.WaitGroup = .{};

    var server = try serve();

    while (server.accept()) |connection| {
        print("Accepted connection from: {}\n\n", .{connection.address});

        pool.spawnWg(&wg, struct {
            fn f(local_allocator: std.mem.Allocator, conn: net.Server.Connection) void {
                parse_data(local_allocator, conn) catch |err| {
                    std.log.err("Thread failed: {}", .{err});
                };
            }
        }.f, .{ allocator, connection });
    } else |err| {
        return err;
    }
}

fn run_eloop(_: mem.Allocator) !void {
    const loop = uv.uv_default_loop();
    print("LibUV loop: {*}\n", .{loop});

    var timer: uv.uv_timer_t = undefined;
    if (uv.uv_timer_init(loop, &timer) != 0) {
        print("Timer init failed!\n", .{});
        return;
    }

    _ = uv.uv_timer_start(&timer, struct {
        fn callback(_: [*c]uv.uv_timer_t) callconv(.C) void {
            print("Timer fired!\n", .{});
        }
    }.callback, 1000, 0);

    _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
}