const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const uv = @import("imports/libuv.zig");
const Config = @import("config.zig").Config;
const request_t = @import("request.zig").request_t;
const Response = @import("response.zig").Response;
const Baton = @import("baton.zig").Baton;
const action_t = @import("action.zig").action_t;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const callback_t = @import("constants.zig").callback_t;
const thread_callback_t = @import("constants.zig").thread_callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const response_pool_t = @import("constants.zig").response_pool_t;
const client_pool_t = @import("constants.zig").client_pool_t;
const baton_pool_t = @import("constants.zig").baton_pool_t;
const work_pool_t = @import("constants.zig").work_pool_t;
const write_req_pool_t = @import("constants.zig").write_req_pool_t;
const arena_pool_t = @import("constants.zig").arena_pool_t;
const middleware_t = @import("constants.zig").middleware_t;
const map_t = @import("constants.zig").map_t;
const ThreadSafeMemoryPool = @import("pools/thread_safe_memory_pool.zig").ThreadSafeMemoryPool;

pub fn Server(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);

    const callback_fn = callback_t(AppContext, RequestContext);

    const Action = action_t(AppContext, RequestContext);

    const middleware = middleware_t(AppContext, RequestContext);

    const State = struct {
        context: *anyopaque,
        timer: uv.uv_timer_t,
        stream: [*c]uv.uv_stream_t,
        request_raw: ?[]u8,
    };

    const state_pool_t = ThreadSafeMemoryPool(State, .{
        .growable = true,
    });

    const request_pool_t = ThreadSafeMemoryPool(Request, .{
        .growable = true,
    });

    const Context = struct {
        allocator: *std.mem.Allocator,
        callback: callback_fn,
        buffer_allocator: *buffer_pool_t,
        request_allocator: *request_pool_t,
        response_allocator: *response_pool_t,
        client_allocator: *client_pool_t,
        write_req_allocator: *write_req_pool_t,
        baton_allocator: *baton_pool_t,
        arena_allocator: *arena_pool_t,
        state_allocator: *state_pool_t,
        map_allocator: *map_t,
        app_context: *AppContext,
        middleware_list: []const middleware,
        timeout: u64,
    };

    const init_request_t = struct { request: *Request, cleanup: *const fn (*Request, *map_t, *request_pool_t) anyerror!void };

    const init_response_t = struct { response: *Response, cleanup: *const fn (*Response, *map_t, *response_pool_t) anyerror!void };

    return struct {
        allocator: *mem.Allocator,
        config: Config = .{},
        callback: callback_fn,
        app_context: if (AppContext == void) void else *AppContext,
        middleware_list: []const middleware,
        loop: [*c]uv.uv_loop_t,

        const Self = @This();

        pub fn init(allocator: *mem.Allocator, comptime config: Config, callback: callback_fn, app_context: if (AppContext == void) void else *AppContext) Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .callback = callback,
                .app_context = app_context,
                .middleware_list = &.{},
                .loop = undefined,
            };
        }

        pub fn start(self: *Self) !void {
            const allocator = self.allocator;
            const config = self.config;
            const callback = self.callback;
            const app_context = if (AppContext == void) undefined else self.app_context;
            const middleware_list = self.middleware_list;

            const ctx: *Context = try allocator.*.create(Context);
            defer allocator.*.destroy(ctx);

            ctx.*.allocator = allocator;
            ctx.*.callback = callback;
            ctx.*.app_context = app_context;
            ctx.*.middleware_list = middleware_list;
            ctx.*.timeout = config.timeout;

            const cleanup = try init_pools(allocator.*, ctx, config.pool_size);
            defer cleanup(allocator.*, ctx);

            var loop: uv.uv_loop_t = undefined;
            _ = uv.uv_loop_init(&loop);
            self.loop = &loop;

            var server: uv.uv_tcp_t = undefined;
            _ = uv.uv_tcp_init(&loop, &server);
            server.data = @constCast(ctx);
            _ = uv.uv_tcp_nodelay(&server, @intCast(0));

            var addr: uv.struct_sockaddr_in = undefined;
            _ = uv.uv_ip4_addr(@ptrCast(config.listen_address), @intCast(config.port), &addr);
            _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

            _ = uv.uv_listen(@ptrCast(&server), config.backlog_size, on_connection);

            _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);
        }

        pub fn stop(self: *Self) void {
            uv.uv_stop(self.*.loop);

            _ = uv.uv_loop_close(self.loop);
        }

        pub fn register_middleware(self: *Self, middleware_list: []const middleware) void {
            self.middleware_list = middleware_list;
        }

        fn on_connection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            const ctx: *Context = @ptrCast(@alignCast(server.*.data));
            const client_pool = ctx.client_allocator;
            const state_pool = ctx.state_allocator;

            if (status < 0) {
                return;
            }

            const client = client_pool.create() catch {
                print("Failed to allocate client\n", .{});
                return;
            };

            const state = state_pool.create() catch {
                print("Failed to allocate state\n", .{});
                return;
            };

            const stream: [*c]uv.uv_stream_t = @ptrCast(client);

            state.* = .{ .context = @ptrCast(@alignCast(ctx)), .timer = undefined, .stream = stream, .request_raw = null };

            _ = uv.uv_tcp_init(server.*.loop, client);
            client.*.data = state;

            _ = uv.uv_timer_init(server.*.loop, &state.timer);
            state.timer.data = state;

            if (uv.uv_accept(server, stream) == 0) {
                _ = uv.uv_timer_start(&state.timer, on_timeout, ctx.*.timeout, 0);
                _ = uv.uv_read_start(stream, alloc_buffer, on_read);
            } else {
                _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
            }
        }

        fn after_process(req: [*c]uv.uv_work_t, status: c_int) callconv(.c) void {
            const baton: *Baton = @ptrCast(@alignCast(req.*.data));
            const stream = baton.*.stream;
            const state: *State = @ptrCast(@alignCast(stream.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            if (status < 0) {
                print("Operation cancelled\n", .{});
                return;
            }

            const allocator = ctx.*.allocator.*;
            var write_req_pool = ctx.*.write_req_allocator;
            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const baton_pool = ctx.*.baton_allocator;
            const arena_pool = ctx.*.arena_allocator;
            const buffer_pool = ctx.*.buffer_allocator;

            const response = baton.*.response;
            const on_write_cb = baton.*.on_write_cb;
            const cleanup_response_cb = baton.*.cleanup_response_cb;
            const buffer = baton.*.buffer;

            defer {
                const arena = response.*.arena;
                cleanup_response_cb(response, map_pool, response_pool) catch {
                    print("Failed to deinit response\n", .{});
                };
                arena_pool.destroy(arena);
                if (buffer != null) {
                    buffer_pool.destroy(@ptrCast(@alignCast(buffer)));
                } else {
                    ctx.*.allocator.free(baton.*.request_raw);
                }
                baton_pool.destroy(baton);
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
            const state: *State = @ptrCast(@alignCast(stream.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const request_pool = ctx.*.request_allocator;
            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const arena_pool = ctx.*.arena_allocator;
            const allocator = ctx.*.allocator.*;

            const request_raw = baton.*.request_raw;

            const arena = arena_pool.create() catch {
                print("There was an error initializing the arena\n", .{});
                return;
            };
            arena.* = std.heap.ArenaAllocator.init(allocator);

            const request_struct = start_request(request_raw, map_pool, request_pool) catch {
                print("There was an error initializing the request\n", .{});
                return;
            };
            const request = request_struct.request;
            defer request_struct.cleanup(request, map_pool, request_pool) catch {
                print("Failed to deinit request\n", .{});
            };

            const response_struct = start_response(arena, map_pool, response_pool) catch {
                print("There was an error initializing the response\n", .{});
                return;
            };
            const response = response_struct.response;

            handle_callback(ctx, request, response);

            baton.*.response = response;
            baton.*.on_write_cb = if (is_keep_alive(request)) on_write_complete_keep_alive else on_write_complete_no_keep_alive;
            baton.*.cleanup_response_cb = response_struct.cleanup;
        }

        fn handle_callback(ctx: *Context, request: *Request, response: *Response) void {
            const action: Action = .{
                .app_context = ctx.*.app_context,
                .index = 0,
                .middleware_list = ctx.*.middleware_list,
                .request = request,
                .response = response,
                .callback = ctx.*.callback,
            };
            action.next() catch {
                response.*.set_error_response();
            };
        }

        fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
            const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
            const state: *State = @ptrCast(@alignCast(stream.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            _ = uv.uv_timer_start(&state.*.timer, on_timeout, ctx.*.timeout, 0);

            const baton_pool = ctx.*.baton_allocator;
            const buffer_pool = ctx.*.buffer_allocator;

            if (nread < 0 or buf.*.base == null) {
                if (nread != uv.UV_EOF) {
                    print("Read error: {s}\n", .{uv.uv_strerror(@intCast(nread))});
                }
                _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                return;
            }

            if (nread >= 0) {
                const new_read: usize = @intCast(nread);
                const baton = baton_pool.create() catch {
                    print("Failed to allocate baton\n", .{});
                    return;
                };

                baton.*.req.data = @ptrCast(@alignCast(baton));
                baton.*.stream = stream;

                // if nread < suggested_buffer_size, this is the last read call for this request
                if (nread < suggested_buffer_size) {
                    // request_raw being not null means that this isn't the first read call for this request,
                    // and we need to pass it forward.
                    if (state.*.request_raw) |request_raw| {
                        baton.*.request_raw = append_buffer(
                            ctx.*.allocator.*,
                            request_raw,
                            buf.*.base[0..new_read],
                        ) catch {
                            return;
                        };
                        baton.*.buffer = null;
                    } else {
                        baton.*.request_raw = buf.*.base[0..@intCast(nread)];
                        baton.*.buffer = buf.*.base;
                    }

                    const res = uv.uv_queue_work(stream.*.loop, @ptrCast(@alignCast(&baton.*.req)), process, after_process);
                    if (res != 0) {
                        _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                    }
                } else {
                    // if this isn't the last read call of the request, we should copy (and concatenate) the buffer
                    // value to a new buffer stored in state.*.request_raw. Then, free buffer.
                    defer buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));

                    if (state.*.request_raw) |request_raw| {
                        state.*.request_raw = append_buffer(
                            ctx.*.allocator.*,
                            request_raw,
                            buf.*.base[0..new_read],
                        ) catch {
                            return;
                        };
                    } else {
                        state.*.request_raw = ctx.*.allocator.*.dupe(u8, buf.*.base[0..@intCast(nread)]) catch {
                            print("Failed to duplicate data\n", .{});
                            return;
                        };
                    }
                }
            }
        }

        fn is_keep_alive(request: *Request) bool {
            const connection_header = request.*.getHeader("Connection");

            if (connection_header) |header| {
                if (!std.ascii.eqlIgnoreCase(header, "keep-alive")) {
                    return false;
                }
            }

            return true;
        }

        fn on_write_complete_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            var write_req_pool = ctx.*.write_req_allocator;
            defer write_req_pool.destroy(req);

            if (status < 0) {
                print("Write error: {s}\n", .{uv.uv_strerror(status)});
            }

            _ = uv.uv_timer_start(&state.*.timer, on_timeout, ctx.*.timeout, 0);

            state.*.request_raw = null;
            _ = uv.uv_read_start(req.*.handle, alloc_buffer, on_read);
        }

        fn on_write_complete_no_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.C) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            var write_req_pool = ctx.*.write_req_allocator;
            defer write_req_pool.destroy(req);

            if (status < 0) {
                print("Write error: {s}\n", .{uv.uv_strerror(status)});
            }
            _ = uv.uv_close(@ptrCast(req.*.handle), on_close);
        }

        fn start_request(request_raw: []u8, map_pool: *map_t, request_pool: *request_pool_t) !init_request_t {
            const request = try request_pool.create();
            request.* = try Request.init(map_pool);
            try request.*.parseRequest(request_raw);

            return init_request_t{ .request = request, .cleanup = struct {
                fn clean(inner_request: *Request, inner_map_pool: *map_t, inner_request_pool: *request_pool_t) !void {
                    try inner_request.*.deinit(inner_map_pool);
                    inner_request_pool.destroy(inner_request);
                }
            }.clean };
        }

        fn start_response(arena: *std.heap.ArenaAllocator, map_pool: *map_t, response_pool: *response_pool_t) !init_response_t {
            const response = try response_pool.create();
            response.* = try Response.init(arena, map_pool);
            return init_response_t{ .response = response, .cleanup = struct {
                fn clean(inner_response: *Response, inner_map_pool: *map_t, inner_response_pool: *response_pool_t) !void {
                    inner_response.arena.*.deinit();
                    try inner_response.*.deinit(inner_map_pool);
                    inner_response_pool.destroy(inner_response);
                }
            }.clean };
        }

        fn on_timeout(timer: [*c]uv.uv_timer_t) callconv(.C) void {
            const state: *State = @ptrCast(@alignCast(timer.*.data));
            const stream = state.*.stream;

            _ = uv.uv_close(@ptrCast(stream), on_close);
        }

        fn on_close(handle: [*c]uv.uv_handle_t) callconv(.C) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            _ = uv.uv_timer_stop(&state.*.timer);

            const client_pool = ctx.client_allocator;
            const client: *uv.uv_tcp_t = @ptrCast(@alignCast(handle));
            client_pool.*.destroy(client);

            const state_pool = ctx.*.state_allocator;
            state_pool.*.destroy(state);
        }

        fn append_buffer(allocator: mem.Allocator, old_data: []u8, new_data: []u8) ![]u8 {
            const old_len = old_data.len;
            const new_len = old_len + new_data.len;

            const new_buf = try allocator.alloc(u8, new_len);

            @memcpy(new_buf[0..old_len], old_data);
            @memcpy(new_buf[old_len..], new_data);

            allocator.free(old_data);

            return new_buf;
        }

        fn alloc_buffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

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

            ctx.*.arena_allocator = try allocator.create(arena_pool_t);
            ctx.*.arena_allocator.* = try arena_pool_t.initPreheated(allocator, pool_size);

            ctx.*.state_allocator = try allocator.create(state_pool_t);
            ctx.*.state_allocator.* = try state_pool_t.initPreheated(allocator, pool_size);

            //The poolsize is multiplied by three because it is used by the
            // request headers, the request params and the response headers
            ctx.*.map_allocator = try allocator.create(map_t);
            ctx.*.map_allocator.* = try map_t.initPreheated(allocator, pool_size * 3);

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

                    ctx_inner.*.arena_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.arena_allocator);

                    ctx_inner.*.state_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.state_allocator);

                    ctx_inner.*.map_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.map_allocator);
                }
            }.clean;
        }
    };
}

const testing = std.testing;

test "should start and stop" {
    const azig = Server(void, void);
    const Request = request_t(void);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const on_response = struct {
        fn on_response(_: *Request, _: *Response) !void {}
    }.on_response;

    const run = struct {
        fn run(server_ptr: *azig) !void {
            try server_ptr.start();
        }
    }.run;

    var server = azig.init(&allocator, Config{}, on_response, {});
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        server.stop();
        thread.join();
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    const uri = try std.Uri.parse("http://localhost:2500");

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    try testing.expectEqual(req.response.status, std.http.Status.ok);
}
