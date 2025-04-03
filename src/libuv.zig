const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const uv = @cImport({
    @cInclude("uv.h");
});

fn on_connection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
    const arena = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch return;
    arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    if (status < 0) {
        print("New connection error {s}\n", .{uv.uv_strerror(status)});
        return;
    }

    const client: [*c]uv.uv_tcp_t = allocator.create(uv.uv_tcp_t) catch return;

    _ = uv.uv_tcp_init(server.*.loop, client);
    client.*.data = @constCast(arena);

    if (uv.uv_accept(server, @ptrCast(client)) == 0) {
        _ = uv.uv_read_start(@ptrCast(client), alloc_buffer, on_read);
    }
}

fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
    const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
    const arena_ptr: *std.heap.ArenaAllocator = @ptrCast(@alignCast(stream.*.data));
    const allocator = arena_ptr.*.allocator();

    if (nread < 0) {
        if (nread != uv.UV_EOF) {
            print("Read error: {s}\n", .{uv.uv_strerror(@intCast(nread))});
        }
        _ = uv.uv_close(@ptrCast(@alignCast(client)), null);
        return;
    }

    if (nread > 0) {
        const request = buf.*.base[0..@intCast(nread)];
        print("Received request:\n{s}\n", .{request});

        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, libuv!";
        const write_req = allocator.create(uv.uv_write_t) catch {
            print("Failed to allocate write_req\n", .{});
            return;
        };

        var buf_resp = uv.uv_buf_init(@ptrCast(@constCast(response)), @intCast(response.len));
        _ = uv.uv_write(
            write_req,
            stream,
            &buf_resp,
            1,
            on_write_complete,
        );
    }
}

fn on_write_complete(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
    if (status < 0) {
        print("Write error: {s}\n", .{uv.uv_strerror(status)});
    }
    _ = uv.uv_close(@ptrCast(req.*.handle), on_close);
}

fn on_close(handle: [*c]uv.uv_handle_t) callconv(.C) void {
    const arena_ptr: *std.heap.ArenaAllocator = @ptrCast(@alignCast(handle.*.data));
    _ = arena_ptr.*.deinit();
}

fn alloc_buffer(handle: [*c]uv.uv_handle_t, suggested_size: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
    const arena_ptr: *std.heap.ArenaAllocator = @ptrCast(@alignCast(handle.*.data));
    const allocator = arena_ptr.*.allocator();
    const actual_size = suggested_size + @sizeOf(usize);

    const memory = allocator.alloc(u8, actual_size) catch {
        buf.* = uv.uv_buf_init(null, 0);
        return;
    };

    @as(*usize, @ptrCast(@alignCast(memory.ptr))).* = actual_size;

    buf.* = uv.uv_buf_init(
        @ptrCast(@alignCast(memory.ptr + @sizeOf(usize))),
        @intCast(suggested_size),
    );
}

pub fn libuv_execute() void {
    const loop = uv.uv_default_loop();

    var server: uv.uv_tcp_t = undefined;
    _ = uv.uv_tcp_init(loop, &server);

    var addr: uv.struct_sockaddr_in = undefined;
    _ = uv.uv_ip4_addr("0.0.0.0", 2500, &addr);
    _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

    _ = uv.uv_listen(@ptrCast(&server), 128, on_connection);

    print("Server running at http://0.0.0.0:2500\n", .{});

    _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
}
