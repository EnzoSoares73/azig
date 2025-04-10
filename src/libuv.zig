const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const request_lib = @import("request.zig");
const uv = @import("imports/libuv.zig");
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const callback_t = @import("constants.zig").callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const actual_buffer_size = @import("constants.zig").actual_buffer_size;

const Context = struct {
    callback: callback_t,
    arena: *std.heap.ArenaAllocator,
    buffer_allocator: buffer_pool_t,
};

const InitialContext = struct {
    allocator: *mem.Allocator,
    callback: callback_t,
    buffer_allocator: buffer_pool_t,
};

fn on_connection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
    const initial_ctx: *InitialContext = @ptrCast(@alignCast(server.*.data));
    const main_allocator = initial_ctx.*.allocator;

    const ctx = main_allocator.*.create(Context) catch {
        print("Failed to create context\n", .{});
        return;
    };

    ctx.*.callback = initial_ctx.*.callback;
    ctx.*.buffer_allocator = initial_ctx.*.buffer_allocator;

    const arena = main_allocator.*.create(std.heap.ArenaAllocator) catch {
        print("Failed to create arena allocator\n", .{});
        return;
    };
    arena.* = std.heap.ArenaAllocator.init(main_allocator.*);
    const allocator = arena.allocator();

    if (status < 0) {
        print("New connection error {s}\n", .{uv.uv_strerror(status)});
        arena.deinit();
        main_allocator.*.destroy(arena);
        return;
    }

    const client: [*c]uv.uv_tcp_t = allocator.create(uv.uv_tcp_t) catch {
        print("Failed to allocate client\n", .{});
        arena.deinit();
        main_allocator.*.destroy(arena);
        return;
    };

    _ = uv.uv_tcp_init(server.*.loop, client);
    ctx.*.arena = arena;
    client.*.data = ctx;

    if (uv.uv_accept(server, @ptrCast(client)) == 0) {
        _ = uv.uv_read_start(@ptrCast(client), alloc_buffer, on_read);
    } else {
        arena.deinit();
        main_allocator.destroy(arena);
    }
}

fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
    const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
    const ctx: *Context = @ptrCast(@alignCast(stream.*.data));
    const arena_ptr: *std.heap.ArenaAllocator = ctx.*.arena;
    const allocator = arena_ptr.*.allocator();
    var buffer_pool = ctx.*.buffer_allocator;

    if (nread < 0) {
        if (nread != uv.UV_EOF) {
            print("Read error: {s}\n", .{uv.uv_strerror(@intCast(nread))});
        }
        _ = uv.uv_close(@ptrCast(@alignCast(client)), null);
        buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));
    }

    if (nread > 0) {
        const request_raw = buf.*.base[0..@intCast(nread)];

        const request = allocator.create(Request) catch {
            print("Failed to allocate request\n", .{});
            return;
        };
        request.* = Request.init(allocator);
        request.*.parseRequest(request_raw) catch {
            print("Failed to parse request\n", .{});
            return;
        };

        const response = allocator.create(Response) catch {
            print("Failed to allocate response\n", .{});
            return;
        };
        response.* = Response.init(allocator);

        ctx.*.callback(allocator, request, response) catch {
            return;
        };

        const response_text = response.to_string(allocator) catch {
            print("Failed to write response\n", .{});
            return;
        };

        const write_req = allocator.create(uv.uv_write_t) catch {
            print("Failed to allocate write_req\n", .{});
            return;
        };

        var buf_resp = uv.uv_buf_init(@ptrCast(@constCast(response_text)), @intCast(response_text.len));
        _ = uv.uv_write(
            write_req,
            stream,
            &buf_resp,
            1,
            on_write_complete,
        );
        buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));
    }
}

fn on_write_complete(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
    if (status < 0) {
        print("Write error: {s}\n", .{uv.uv_strerror(status)});
    }
    _ = uv.uv_close(@ptrCast(req.*.handle), on_close);
}

fn on_close(handle: [*c]uv.uv_handle_t) callconv(.C) void {
    const ctx: *Context = @ptrCast(@alignCast(handle.*.data));
    const arena_ptr: *std.heap.ArenaAllocator = ctx.*.arena;
    _ = arena_ptr.*.deinit();
}

fn alloc_buffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(handle.*.data));
    var buffer_pool = ctx.*.buffer_allocator;

    const memory: *[suggested_buffer_size]u8 = buffer_pool.create() catch {
        buf.* = uv.uv_buf_init(null, 0);
        return;
    };

    buf.* = uv.uv_buf_init(memory.ptr,@intCast(suggested_buffer_size));
}

pub fn libuv_execute(allocator: *mem.Allocator, config: Config, callback: callback_t) !void {
    const ctx: *InitialContext = try allocator.*.create(InitialContext);
    ctx.*.allocator = allocator;
    ctx.*.callback = callback;
    ctx.*.buffer_allocator = try buffer_pool_t.initPreheated(allocator.*, 1024);

    print("Started server\n", .{});

    const loop = uv.uv_default_loop();

    var server: uv.uv_tcp_t = undefined;
    _ = uv.uv_tcp_init(loop, &server);
    server.data = @constCast(ctx);

    var addr: uv.struct_sockaddr_in = undefined;
    _ = uv.uv_ip4_addr("0.0.0.0", @intCast(config.port), &addr);
    _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

    _ = uv.uv_listen(@ptrCast(&server), 128, on_connection);

    print("Listening on http://0.0.0.0:{d}\n", .{config.port});

    _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
}
