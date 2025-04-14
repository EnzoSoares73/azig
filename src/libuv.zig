const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const request_lib = @import("request.zig");
const uv = @import("imports/libuv.zig");
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const actual_buffer_size = @import("constants.zig").actual_buffer_size;
const Context = @import("context.zig").Context;
const callback_t = @import("constants.zig").callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const request_pool_t = @import("constants.zig").request_pool_t;
const response_pool_t = @import("constants.zig").response_pool_t;
const client_pool_t = @import("constants.zig").client_pool_t;
const context_pool_t = @import("constants.zig").context_pool_t;
const write_req_pool_t = @import("constants.zig").write_req_pool_t;

fn on_connection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(server.*.data));
    const client_pool = ctx.client_allocator;

    if (status < 0) {
        print("New connection error {s}\n", .{uv.uv_strerror(status)});
        return;
    }

    const client: [*c]uv.uv_tcp_t = client_pool.create() catch {
        print("Failed to allocate client\n", .{});
        return;
    };

    _ = uv.uv_tcp_init(server.*.loop, client);
    client.*.data = ctx;

    if (uv.uv_accept(server, @ptrCast(client)) == 0) {
        _ = uv.uv_read_start(@ptrCast(client), alloc_buffer, on_read);
    }
}

fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
    const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
    const ctx: *Context = @ptrCast(@alignCast(stream.*.data));
    const main_allocator = ctx.*.allocator;
    var buffer_pool = ctx.*.buffer_allocator;
    var request_pool = ctx.*.request_allocator;
    var response_pool = ctx.*.response_allocator;
    var write_req_pool = ctx.*.write_req_allocator;

    defer {
        if (buf.*.base != null) {
            buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));
        }
    }

    if (nread < 0) {
        if (nread != uv.UV_EOF) {
            print("Read error: {s}\n", .{uv.uv_strerror(@intCast(nread))});
        }
        _ = uv.uv_close(@ptrCast(@alignCast(client)), on_close);
    }

    if (nread > 0) {
        var arena = std.heap.ArenaAllocator.init(main_allocator.*);
        defer arena.deinit();
        const allocator = arena.allocator();

        const request_raw = buf.*.base[0..@intCast(nread)];

        const request = request_pool.create() catch {
            print("Failed to allocate request\n", .{});
            return;
        };
        request.* = Request.init(allocator, request_raw) catch {
            print("Failed to parse request\n", .{});
            return;
        };
        defer {
            request.*.deinit();
            request_pool.destroy(request);
        }

        const response = response_pool.create() catch {
            print("Failed to allocate response\n", .{});
            return;
        };
        response.* = Response.init(allocator);
        defer {
            response.*.deinit();
            response_pool.destroy(response);
        }

        ctx.*.callback(allocator, request, response) catch {
            return;
        };

        const response_text = response.to_string(allocator) catch {
            print("Failed to write response\n", .{});
            return;
        };

        const write_req = write_req_pool.create() catch {
            print("Failed to allocate write_req\n", .{});
            return;
        };

        const connection_header = request.*.getHeader(@constCast("Connection"));
        var is_keep_alive: bool = true;

        if (connection_header) |header| {
            if (!std.ascii.eqlIgnoreCase(header, "keep-alive")) {
                is_keep_alive = false;
            }
        }

        var buf_resp = uv.uv_buf_init(@ptrCast(@constCast(response_text)), @intCast(response_text.len));
        _ = uv.uv_write(
            write_req,
            stream,
            &buf_resp,
            1,
            if (is_keep_alive) on_write_complete_keep_alive else on_write_complete_no_keep_alive,
        );
    }
}

fn on_write_complete_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
    const ctx: *Context = @ptrCast(@alignCast(req.*.handle.*.data));
    var write_req_pool = ctx.*.write_req_allocator;
    defer write_req_pool.destroy(req);

    if (status < 0) {
        print("Write error: {s}\n", .{uv.uv_strerror(status)});
    }
    _ = uv.uv_read_start(req.*.handle, alloc_buffer, on_read);
}

fn on_write_complete_no_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
    const ctx: *Context = @ptrCast(@alignCast(req.*.handle.*.data));
    var write_req_pool = ctx.*.write_req_allocator;
    defer write_req_pool.destroy(req);

    if (status < 0) {
        print("Write error: {s}\n", .{uv.uv_strerror(status)});
    }
    _ = uv.uv_close(@ptrCast(req.*.handle), on_close);
}

fn on_close(handle: [*c]uv.uv_handle_t) callconv(.C) void {
    const ctx: *Context = @ptrCast(@alignCast(handle.*.data));

    const client_pool = ctx.client_allocator;
    const client: *uv.uv_tcp_t = @alignCast(@ptrCast(handle));
    client_pool.*.destroy(client);
}

fn alloc_buffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(handle.*.data));
    var buffer_pool = ctx.*.buffer_allocator;

    const memory: *[suggested_buffer_size]u8 = buffer_pool.create() catch {
        buf.* = uv.uv_buf_init(null, 0);
        return;
    };

    buf.* = uv.uv_buf_init(memory.ptr, @intCast(suggested_buffer_size));
}

pub fn libuv_execute(allocator: *mem.Allocator, config: Config, callback: callback_t) !void {
    const ctx: *Context = try allocator.*.create(Context);
    ctx.*.allocator = allocator;
    ctx.*.callback = callback;

    ctx.*.buffer_allocator = try allocator.*.create(buffer_pool_t);
    ctx.*.buffer_allocator.* = try buffer_pool_t.initPreheated(allocator.*, 1024);
    defer {
        ctx.*.buffer_allocator.deinit();
        allocator.*.destroy(ctx.*.buffer_allocator);
    }

    ctx.*.request_allocator = try allocator.*.create(request_pool_t);
    ctx.*.request_allocator.* = try request_pool_t.initPreheated(allocator.*, 1024);
    defer {
        ctx.*.request_allocator.deinit();
        allocator.*.destroy(ctx.*.request_allocator);
    }

    ctx.*.response_allocator = try allocator.*.create(response_pool_t);
    ctx.*.response_allocator.* = try response_pool_t.initPreheated(allocator.*, 1024);
    defer {
        ctx.*.response_allocator.deinit();
        allocator.*.destroy(ctx.*.response_allocator);
    }

    ctx.*.client_allocator = try allocator.*.create(client_pool_t);
    ctx.*.client_allocator.* = try client_pool_t.initPreheated(allocator.*, 1024);
    defer {
        ctx.*.client_allocator.deinit();
        allocator.*.destroy(ctx.*.client_allocator);
    }

    ctx.*.write_req_allocator = try allocator.*.create(write_req_pool_t);
    ctx.*.write_req_allocator.* = try write_req_pool_t.initPreheated(allocator.*, 1024);
    defer {
        ctx.*.write_req_allocator.deinit();
        allocator.*.destroy(ctx.*.write_req_allocator);
    }

    print("Started server\n", .{});

    const loop = uv.uv_default_loop();

    var server: uv.uv_tcp_t = undefined;
    _ = uv.uv_tcp_init(loop, &server);
    server.data = @constCast(ctx);
    _ = uv.uv_tcp_nodelay(&server, @intCast(0));

    var addr: uv.struct_sockaddr_in = undefined;
    _ = uv.uv_ip4_addr("0.0.0.0", @intCast(config.port), &addr);
    _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

    _ = uv.uv_listen(@ptrCast(&server), 128, on_connection);

    print("Listening on http://0.0.0.0:{d}\n", .{config.port});

    _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
}
