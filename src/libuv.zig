const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const uv = @cImport({
    @cInclude("uv.h");
});

fn on_connection(allocator: mem.Allocator, server: [*c]uv.uv_stream_t, status: c_int) void {
    if (status < 0) {
        print("New connection error {s}\n", .{uv.uv_strerror(status)});
        return;
    }

    const client: [*c]uv.uv_tcp_t = allocator.create(uv.uv_tcp_t) catch return;

    _ = uv.uv_tcp_init(server.*.loop, client);
    client.*.data = @constCast(&allocator);

    if (uv.uv_accept(server, @ptrCast(client)) == 0) {
        _ = uv.uv_read_start(@ptrCast(client), struct {
            fn callback(handle: [*c]uv.uv_handle_t, suggested_size: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
                const allocator_ptr: *mem.Allocator = @ptrCast(@alignCast(handle.*.data));
                alloc_buffer(allocator_ptr.*, handle, suggested_size, buf);
            }
        }.callback, struct {
            fn callback(local_client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
                const temp: [*c]uv.uv_stream_t = @ptrCast(@alignCast(local_client));
                const allocator_ptr: *mem.Allocator = @ptrCast(@alignCast(temp.*.data));
                on_read(allocator_ptr.*, local_client, nread, buf);
            }
        }.callback);
    }
}

fn on_read(allocator: mem.Allocator, client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) void {
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

        // Simple HTTP response
        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, libuv!";
        const write_req = allocator.create(uv.uv_write_t) catch return;
        defer allocator.destroy(write_req);

        var buf_resp = uv.uv_buf_init(@ptrCast(@constCast(response)), @intCast(response.len));
        _ = uv.uv_write(
            write_req,
            @ptrCast(@alignCast(client)),
            &buf_resp,
            1,
            on_write_complete,
        );
    }

    // Free the buffer
    if (buf.*.base != null) {
        allocator.free(buf.*.base[0..buf.*.len]);
    }
}

fn on_write_complete(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
    if (status < 0) {
        print("Write error: {s}\n", .{uv.uv_strerror(status)});
    }
    _ = uv.uv_close(@ptrCast(req.*.handle), null);
}

fn alloc_buffer(allocator: mem.Allocator, _: [*c]uv.uv_handle_t, suggested_size: usize, buf: [*c]uv.uv_buf_t) void {
    buf.* = uv.uv_buf_init(
        @ptrCast(allocator.alloc(u8, suggested_size) catch return),
        @intCast(suggested_size),
    );
}

pub fn libuv_execute(allocator: mem.Allocator) void {
    const loop = uv.uv_default_loop();

    var server: uv.uv_tcp_t = undefined;
    _ = uv.uv_tcp_init(loop, &server);
    server.data = @constCast(&allocator);

    var addr: uv.struct_sockaddr_in = undefined;
    _ = uv.uv_ip4_addr("0.0.0.0", 2500, &addr);
    _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

    _ = uv.uv_listen(@ptrCast(&server), 128, struct {
        fn callback(local_server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            const allocator_ptr: *mem.Allocator = @ptrCast(@alignCast(local_server.*.data));
            on_connection(allocator_ptr.*, local_server, status);
        }
    }.callback);

    print("Server running at http://0.0.0.0:2500\n", .{});

    _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
}
