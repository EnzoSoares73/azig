const std = @import("std");
const parse_data = @import("parse_data.zig").parse_data;
const serve = @import("server.zig").serve;
const libuv_execute = @import("libuv.zig").libuv_execute;
const print = std.debug.print;
const mem = std.mem;
const net = std.net;
const StringHashMap = std.StringHashMap;

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

fn run_eloop(allocator: mem.Allocator) !void {
    libuv_execute(allocator);
}