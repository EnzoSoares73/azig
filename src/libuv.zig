const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const request_lib = @import("request.zig");
const uv = @import("imports/libuv.zig");
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Baton = @import("baton.zig").Baton;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const actual_buffer_size = @import("constants.zig").actual_buffer_size;
const callback_t = @import("constants.zig").callback_t;
const thread_callback_t = @import("constants.zig").thread_callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const request_pool_t = @import("constants.zig").request_pool_t;
const response_pool_t = @import("constants.zig").response_pool_t;
const client_pool_t = @import("constants.zig").client_pool_t;
const baton_pool_t = @import("constants.zig").baton_pool_t;
const work_pool_t = @import("constants.zig").work_pool_t;
const write_req_pool_t = @import("constants.zig").write_req_pool_t;
const header_t = @import("constants.zig").header_t;

pub fn libuv(comptime AppContext: type) type {
    const Context = struct {
        allocator: *std.mem.Allocator,
        callback: callback_t(AppContext),
        buffer_allocator: *buffer_pool_t,
        request_allocator: *request_pool_t,
        response_allocator: *response_pool_t,
        client_allocator: *client_pool_t,
        write_req_allocator: *write_req_pool_t,
        baton_allocator: *baton_pool_t,
        header_allocator: *header_t,
        app_context: *AppContext
    };

    const init_request_t = struct { request: *Request, cleanup: *const fn (*Request, *header_t, *request_pool_t) anyerror!void };

    const init_response_t = struct { response: *Response, cleanup: *const fn (*Response, *header_t, *response_pool_t) anyerror!void };

    return struct {
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

        fn after_process(req: [*c]uv.uv_work_t, status: c_int) callconv(.c) void {
            const baton: *Baton = @ptrCast(@alignCast(req.*.data));
            const stream = baton.*.stream;
            const ctx: *Context = @ptrCast(@alignCast(stream.*.data));

            if (status < 0) {
                print("Operation cancelled\n", .{});
                return;
            }

            const allocator = ctx.*.allocator.*;
            var write_req_pool = ctx.*.write_req_allocator;
            const response_pool = ctx.*.response_allocator;
            const header_pool = ctx.*.header_allocator;
            const baton_pool = ctx.*.baton_allocator;

            const response = baton.*.response;
            const on_write_cb = baton.*.on_write_cb;
            const cleanup_response_cb = baton.*.cleanup_response_cb;
            const buf = baton.*.buf;

            defer {
                cleanup_response_cb(response, header_pool, response_pool) catch {
                    print("Failed to deinit response\n", .{});
                };
                baton_pool.destroy(baton);
                allocator.free(buf);
            }

            const response_text = response.*.to_string(allocator) catch {
                print("Failed to write response\n", .{});
                return;
            };
            if (response_text.in_heap) {
                defer allocator.free(response_text.string);
            }

            const write_req = write_req_pool.create() catch {
                print("Failed to allocate write_req\n", .{});
                return;
            };

            var buf_resp = uv.uv_buf_init(@ptrCast(@constCast(response_text.string)), @intCast(response_text.string.len));
            _ = uv.uv_write(
                write_req,
                stream,
                &buf_resp,
                1,
                on_write_cb,
            );
        }

        fn process(req: [*c]uv.uv_work_t) callconv(.c) void {
            const baton: *Baton = @ptrCast(@alignCast(req.*.data));
            const stream = baton.*.stream;
            const ctx: *Context = @ptrCast(@alignCast(stream.*.data));

            const request_pool = ctx.*.request_allocator;
            const response_pool = ctx.*.response_allocator;
            const header_pool = ctx.*.header_allocator;
            const app_context = ctx.*.app_context;

            const allocator = ctx.*.allocator.*;
            const request_raw = baton.*.buf;

            const request_struct = start_request(request_raw, header_pool, request_pool) catch {
                print("There was an error initializing the request\n", .{});
                return;
            };
            const request = request_struct.request;
            defer request_struct.cleanup(request, header_pool, request_pool) catch {
                print("Failed to deinit request\n", .{});
            };

            const response_struct = start_response(header_pool, response_pool) catch {
                print("There was an error initializing the response\n", .{});
                return;
            };
            const response = response_struct.response;

            if (AppContext == void) {
                ctx.*.callback(allocator, request, response) catch {
                    return;
                };
            } else {
                ctx.*.callback(allocator, app_context, request, response) catch {
                    return;
                };
            }
            baton.*.response = response;
            baton.*.on_write_cb = if (is_keep_alive(request)) on_write_complete_keep_alive else on_write_complete_no_keep_alive;
            baton.*.cleanup_response_cb = response_struct.cleanup;
        }

        fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
            const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
            const ctx: *Context = @ptrCast(@alignCast(stream.*.data));
            const baton_pool = ctx.*.baton_allocator;
            const buffer_pool = ctx.*.buffer_allocator;

            defer {
                if (buf.*.base != null) {
                    buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));
                }
            }

            if (nread < 0 or buf.*.base == null) {
                if (nread != uv.UV_EOF) {
                    print("Read error: {s}\n", .{uv.uv_strerror(@intCast(nread))});
                }
                _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
            }

            if (nread > 0) {
                const baton = baton_pool.create() catch {
                    print("Failed to allocate baton\n", .{});
                    return;
                };
                const request_raw = ctx.*.allocator.*.dupe(u8, buf.*.base[0..@intCast(nread)]) catch {
                    baton_pool.destroy(baton);
                    std.debug.print("Failed to copy request data\n", .{});
                    return;
                };

                baton.*.req.data = @ptrCast(@alignCast(baton));
                baton.*.stream = stream;
                baton.*.buf = request_raw;

                const res = uv.uv_queue_work(stream.*.loop, @ptrCast(@alignCast(&baton.*.req)), process, after_process);
                if (res != 0) {
                    _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                }
            }
        }

        fn is_keep_alive(request: *Request) bool {
            const connection_header = request.*.getHeader(@constCast("Connection"));

            if (connection_header) |header| {
                if (!std.ascii.eqlIgnoreCase(header, "keep-alive")) {
                    return false;
                }
            }

            return true;
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

        fn start_request(request_raw: []u8, header_pool: *header_t, request_pool: *request_pool_t) !init_request_t {
            const request = try request_pool.create();
            request.* = try Request.init(header_pool);
            try request.*.parseRequest(request_raw);

            return init_request_t{ .request = request, .cleanup = struct {
                fn clean(inner_request: *Request, inner_header_pool: *header_t, inner_request_pool: *request_pool_t) !void {
                    try inner_request.*.deinit(inner_header_pool);
                    inner_request_pool.destroy(inner_request);
                }
            }.clean };
        }

        fn start_response(header_pool: *header_t, response_pool: *response_pool_t) !init_response_t {
            const response = try response_pool.create();
            response.* = try Response.init(header_pool);
            return init_response_t{ .response = response, .cleanup = struct {
                fn clean(inner_response: *Response, inner_header_pool: *header_t, inner_response_pool: *response_pool_t) !void {
                    try inner_response.*.deinit(inner_header_pool);
                    inner_response_pool.destroy(inner_response);
                }
            }.clean };
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

        fn init_pools(allocator: mem.Allocator, ctx: *Context, pool_size: u16) !*const fn (allocator: mem.Allocator, ctx: *Context) void {
            ctx.*.buffer_allocator = try allocator.create(buffer_pool_t);
            ctx.*.buffer_allocator.* = try buffer_pool_t.initPreheated(allocator, pool_size);

            ctx.*.request_allocator = try allocator.create(request_pool_t);
            ctx.*.request_allocator.* = try request_pool_t.initPreheated(allocator, pool_size);

            ctx.*.response_allocator = try allocator.create(response_pool_t);
            ctx.*.response_allocator.* = try response_pool_t.initPreheated(allocator, pool_size);

            ctx.*.client_allocator = try allocator.create(client_pool_t);
            ctx.*.client_allocator.* = try client_pool_t.initPreheated(allocator, pool_size);

            ctx.*.write_req_allocator = try allocator.create(write_req_pool_t);
            ctx.*.write_req_allocator.* = try write_req_pool_t.initPreheated(allocator, pool_size);

            ctx.*.baton_allocator = try allocator.create(baton_pool_t);
            ctx.*.baton_allocator.* = try baton_pool_t.initPreheated(allocator, pool_size);

            ctx.*.header_allocator = try allocator.create(header_t);
            ctx.*.header_allocator.* = try header_t.initPreheated(allocator, pool_size * 2);

            return struct {
                fn clean(allocator_inner: mem.Allocator, ctx_inner: *Context) void {
                    ctx_inner.*.buffer_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.buffer_allocator);

                    ctx_inner.*.request_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.request_allocator);

                    ctx_inner.*.response_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.response_allocator);

                    ctx_inner.*.client_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.client_allocator);

                    ctx_inner.*.write_req_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.write_req_allocator);

                    ctx_inner.*.baton_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.baton_allocator);

                    ctx_inner.*.header_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.header_allocator);
                }
            }.clean;
        }

        pub fn libuv_execute(allocator: *mem.Allocator, config: Config, callback: callback_t(AppContext), app_context: *AppContext) !void {
            const ctx: *Context = try allocator.*.create(Context);
            ctx.*.allocator = allocator;
            ctx.*.callback = callback;
            ctx.*.app_context = app_context;

            const cleanup = try init_pools(allocator.*, ctx, config.pool_size);
            defer cleanup(allocator.*, ctx);

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
    };
}
