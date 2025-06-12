/// Represents a HTTP server implementation using libuv
const std = @import("std");
const mem = std.mem;
const uv = @import("imports/libuv.zig");
const Config = @import("config.zig").Config;
const request_t = @import("request.zig").request_t;
const Response = @import("response.zig").Response;
const action_t = @import("action.zig").action_t;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const callback_t = @import("constants.zig").callback_t;
const thread_callback_t = @import("constants.zig").thread_callback_t;
const buffer_pool_t = @import("constants.zig").buffer_pool_t;
const response_pool_t = @import("constants.zig").response_pool_t;
const client_pool_t = @import("constants.zig").client_pool_t;
const work_pool_t = @import("constants.zig").work_pool_t;
const write_req_pool_t = @import("constants.zig").write_req_pool_t;
const arena_pool_t = @import("constants.zig").arena_pool_t;
const middleware_t = @import("constants.zig").middleware_t;
const map_t = @import("constants.zig").map_t;
const ThreadSafeMemoryPool = @import("pools/thread_safe_memory_pool.zig").ThreadSafeMemoryPool;

const logger = std.log.scoped(.server);

pub fn Server(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = request_t(RequestContext);

    const request_pool_t = ThreadSafeMemoryPool(Request, .{
        .growable = true,
    });

    const State = struct {
        context: *anyopaque,
        timer: uv.uv_timer_t,
        stream: [*c]uv.uv_stream_t,
        request_raw: ?[]u8,
        is_idle: bool,
        req: uv.uv_work_t,
        response: *Response,
        request: *Request,
        cleanup_response_cb: *const fn (*Response, *map_t, *response_pool_t) anyerror!void,
        cleanup_request_cb: *const fn (*Request, *map_t, *request_pool_t) anyerror!void,
        on_write_cb: *const fn([*c]uv.uv_write_t, c_int) callconv(.c) void,
    };

    const state_pool_t = ThreadSafeMemoryPool(State, .{
        .growable = true,
    });

    const callback_fn = callback_t(AppContext, RequestContext);

    const Action = action_t(AppContext, RequestContext);

    const middleware = middleware_t(AppContext, RequestContext);

    //Application-wide context
    const Context = struct {
        allocator: *std.mem.Allocator,
        callback: callback_fn,
        buffer_allocator: *buffer_pool_t,
        request_allocator: *request_pool_t,
        response_allocator: *response_pool_t,
        client_allocator: *client_pool_t,
        write_req_allocator: *write_req_pool_t,
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
            logger.info("Starting server", .{});

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
            logger.info("Pools allocated", .{});

            var loop: uv.uv_loop_t = undefined;
            const result = uv.uv_loop_init(&loop);
            if (result < 0) {
                return error.LoopInitFailed;
            }

            self.*.loop = &loop;

            var server: uv.uv_tcp_t = undefined;
            _ = uv.uv_tcp_init(&loop, &server);
            server.data = @constCast(ctx);
            _ = uv.uv_tcp_nodelay(&server, @intCast(0));

            var addr: uv.struct_sockaddr_in = undefined;
            _ = uv.uv_ip4_addr(@ptrCast(config.listen_address), @intCast(config.port), &addr);
            _ = uv.uv_tcp_bind(&server, @ptrCast(&addr), 0);

            _ = uv.uv_listen(@ptrCast(&server), config.backlog_size, on_connection);

            logger.info("Server started", .{});
            _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);
        }

        pub fn stop(self: *Self) void {
            // To stop the server, we must:
            // 1. Stop the loop
            // 2. Iterate over the open handles and close them
            // 3. How the loop again so the async operations can be terminated
            // 4. Close the loop

            uv.uv_stop(self.*.loop);

            uv.uv_walk(self.*.loop, struct {
                fn cb(handle: [*c]uv.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
                    uv.uv_close(handle, null);
                }
            }.cb, null);

            const result = uv.uv_loop_init(self.*.loop);
            if (result < 0) {
                logger.err("Error: {s}", .{uv.uv_strerror(result)});
            }

            _ = uv.uv_run(self.*.loop, uv.UV_RUN_DEFAULT);

            const status = uv.uv_loop_close(self.loop);
            if (status != 0) {
                logger.err("Error: {s}", .{uv.uv_strerror(status)});
            } else {
                logger.info("Server stopped", .{});
            }
        }

        pub fn register_middlewares(self: *Self, middleware_list: []const middleware) void {
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
                logger.err("Failed to allocate client", .{});
                return;
            };

            const state = state_pool.create() catch {
                logger.err("Failed to allocate state", .{});
                return;
            };

            const stream: [*c]uv.uv_stream_t = @ptrCast(client);

            state.* = .{
                .context = @ptrCast(@alignCast(ctx)),
                .timer = undefined,
                .stream = stream,
                .request = undefined,
                .response = undefined,
                .is_idle = true,
                .req = undefined,
                .cleanup_response_cb = undefined,
                .cleanup_request_cb = undefined,
                .on_write_cb = undefined,
                .request_raw = null,
            };

            _ = uv.uv_tcp_init(server.*.loop, client);
            client.*.data = state;

            _ = uv.uv_timer_init(server.*.loop, &state.timer);
            state.timer.data = state;

            if (uv.uv_accept(server, stream) == 0) {
                logger.info("Connection accepted", .{});
                _ = uv.uv_timer_start(&state.*.timer, on_timeout, ctx.*.timeout, 0);
                _ = uv.uv_read_start(stream, alloc_buffer, on_read);
            } else {
                logger.info("Connection refused", .{});
                _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
            }
        }

        fn send_response(response: *Response, state: *State, on_write_cb: uv.uv_write_cb) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const stream = state.*.stream;

            const allocator = ctx.*.allocator.*;
            const write_req_pool = ctx.*.write_req_allocator;

            const response_text = response.*.to_string(allocator) catch {
                logger.err("Failed to write response", .{});
                return;
            };
            if (response_text.in_heap) {
                defer allocator.free(response_text.string);
            }

            const write_req = write_req_pool.create() catch {
                logger.err("Failed to allocate write_req", .{});
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

        fn after_process(req: [*c]uv.uv_work_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.data));
            const stream = state.*.stream;
            const handle: [*c]uv.uv_handle_t = @ptrCast(@alignCast(stream));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const arena_pool = ctx.*.arena_allocator;

            const response = state.*.response;
            const on_write_cb = state.*.on_write_cb;
            const cleanup_response_cb = state.*.cleanup_response_cb;

            state.*.is_idle = true;

            defer {
                const arena = response.*.arena;
                cleanup_response_cb(response, map_pool, response_pool) catch {
                    logger.err("Failed to deinit response", .{});
                };
                arena_pool.destroy(arena);
            }

            if (status < 0) {
                logger.info("Operation cancelled", .{});
                if (uv.uv_is_active(handle) != 0) {
                    _ = uv.uv_close(handle, on_close);
                }
                return;
            }

            if (uv.uv_is_active(handle) != 0) {
                send_response(response, state, on_write_cb);
                if (state.*.request_raw) |request_raw| {
                    ctx.*.allocator.*.free(request_raw);
                }
            } else {
                // if the request timed out, then it is not possible to
                // write anything to the stream, nor is it needed to free the memory
            }
        }

        fn process(req: [*c]uv.uv_work_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const request_pool = ctx.*.request_allocator;
            const map_pool = ctx.*.map_allocator;

            const request = state.*.request;
            defer state.*.cleanup_request_cb(request, map_pool, request_pool) catch {
                logger.err("Failed to deinit request", .{});
            };

            const response_struct = create_response(ctx) catch |err| {
                logger.err("Error creating response: {}", .{err});
                return;
            };
            const response = response_struct.response;

            state.*.response = response;
            state.*.cleanup_response_cb = response_struct.cleanup;

            if (state.*.request_raw) |request_raw| {
                logger.info("{s}", .{request_raw});
            } else {
                unreachable;
            }

            handle_callback(ctx, request, response);
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

        fn transfer_buffer_slice(old_buffer: []u8, old_slice: []u8, new_buffer: []u8) []u8 {
            const old_buffer_pointer = @intFromPtr(old_buffer.ptr);
            const old_slice_pointer = @intFromPtr(old_slice.ptr);
            const offset = old_slice_pointer - old_buffer_pointer;
            return new_buffer[offset..offset + old_slice.len];
        }

        // When the request is too big for a single buffer, we copy the bytes already received
        // together with the new bytes into a new buffer.
        // This method recreates the slices so that they point to the new valid buffer
        fn transfer_buffer_slices(state: *State, old_buffer: []u8, new_buffer: []u8) void {
            state.*.request.*.method = transfer_buffer_slice(old_buffer, @constCast(state.*.request.*.method), new_buffer);
            state.*.request.*.path = transfer_buffer_slice(old_buffer, @constCast(state.*.request.*.path), new_buffer);
            state.*.request.*.version = transfer_buffer_slice(old_buffer, @constCast(state.*.request.*.version), new_buffer);
            if (state.*.request.*.body) |body| {
                 state.*.request.*.body = transfer_buffer_slice(old_buffer, @constCast(body), new_buffer);
            }

            var header_iter = state.*.request.*.headers.*.iterator();
            while (header_iter.next()) |entry| {
                const value = entry.value_ptr.*;
                entry.value_ptr.* = transfer_buffer_slice(old_buffer, @constCast(value), new_buffer);

                const key = entry.key_ptr.*;
                entry.key_ptr.* = transfer_buffer_slice(old_buffer, @constCast(key), new_buffer);
            }

            var param_iter = state.*.request.*.params.*.iterator();
            while (param_iter.next()) |entry| {
                const value = entry.value_ptr.*;
                entry.value_ptr.* = transfer_buffer_slice(old_buffer, @constCast(value), new_buffer);

                const key = entry.key_ptr.*;
                entry.key_ptr.* = transfer_buffer_slice(old_buffer, @constCast(key), new_buffer);
            }
        }


        fn is_finished_reading(request: *Request) !bool {
            const content_length_header = request.*.getHeader("Content-Length");
            if (content_length_header) |header| {
                const content_length = try std.fmt.parseInt(u64, header, 10);
                if (request.*.body) |body| {
                    if (content_length == body.len) {
                        return true;
                    } else if (content_length < body.len) {
                        return error.BadRequest;
                    } else {
                        return false;
                    }
                } else if (content_length == 0 and request.*.body == null) {
                    return true;
                } else {
                    return false;
                }
            } else {
                if (request.*.body == null) {
                    return true;
                } else {
                    return error.BadRequest;
                }
            }
        }

        fn on_read(client: *anyopaque, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
            const stream: [*c]uv.uv_stream_t = @ptrCast(@alignCast(client));
            const state: *State = @ptrCast(@alignCast(stream.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            _ = uv.uv_timer_start(&state.*.timer, on_timeout, ctx.*.timeout, 0);
            state.*.is_idle = false;
            state.*.req.data = @ptrCast(@alignCast(state));
            state.*.stream = stream;

            const buffer_pool = ctx.*.buffer_allocator;
            const request_pool = ctx.*.request_allocator;
            const map_pool = ctx.*.map_allocator;

            defer {
                if (buf.*.base != null) {
                    buffer_pool.destroy(@ptrCast(@alignCast(buf.*.base)));
                }
            }

            if (buf.*.base == null) {
                logger.info("Closing connection", .{});
                _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                return;
            }

            if (nread > 0) {
                const new_read: usize = @intCast(nread);
                //There is data to be read
                if (state.*.request_raw) |request_raw| {
                    const old_buffer = request_raw;
                    defer ctx.*.allocator.*.free(old_buffer);
                    const new_buffer = append_buffer(
                        ctx.*.allocator.*,
                        old_buffer,
                        buf.*.base[0..new_read],
                    ) catch |err| {
                        logger.err("There was an error appending buffers: {}", .{err});
                        return;
                    };

                    transfer_buffer_slices(state, old_buffer, new_buffer);

                    // since we now the first buffer must contain the headers,
                    // the following buffers will contain only the body, or parts of it
                    state.*.request.*.appendToBody(new_buffer[old_buffer.len..]);
                    state.*.request_raw = new_buffer;
                } else {
                    // First time on_read is being called for this request
                    const request_raw = ctx.*.allocator.*.dupe(u8, buf.*.base[0..new_read]) catch {
                        logger.err("Failed to duplicate data", .{});
                        return;
                    };

                    const request_struct = start_request(map_pool, request_pool) catch |err| {
                        logger.err("There was an error initializing the request: {}", .{err});
                        return;
                    };
                    const request = request_struct.request;

                    // The headers of the request must be included in the first buffer.
                    request.*.parseRequest(request_raw) catch |err| {
                        logger.err("{}", .{err});
                        set_response_and_send(state, Response.set_bad_request_response);
                        _ = uv.uv_read_stop(state.*.stream);
                        return;
                    };

                    state.*.request_raw = request_raw;
                    state.*.request = request_struct.request;
                    state.*.cleanup_request_cb = request_struct.cleanup;
                    state.*.on_write_cb = if (is_keep_alive(request)) on_write_complete_keep_alive else on_write_complete_no_keep_alive;
                }

                const has_finished_reading = is_finished_reading(state.*.request) catch {
                    set_response_and_send(state, Response.set_bad_request_response);
                    _ = uv.uv_read_stop(state.*.stream);
                    return;
                };
                if (has_finished_reading) {
                    const res = uv.uv_queue_work(stream.*.loop, @ptrCast(@alignCast(&state.*.req)), process, after_process);
                    if (res != 0) {
                        _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                    }
                }
            } else {
                switch (nread) {
                    // There is no more data to be read
                    uv.UV_EOF => {
                        _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                    },
                    uv.UV_ECONNRESET, uv.UV_ECONNABORTED => {
                        _ = uv.uv_close(@ptrCast(@alignCast(stream)), on_close);
                        if (state.*.request_raw) |request_raw| {
                            ctx.*.allocator.*.free(request_raw);
                        }
                    }, else => {

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

        fn on_write_complete_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            var write_req_pool = ctx.*.write_req_allocator;
            defer write_req_pool.destroy(req);

            if (status < 0) {
                logger.err("Write error: {s}", .{uv.uv_strerror(status)});
            }

            _ = uv.uv_timer_start(&state.*.timer, on_timeout, ctx.*.timeout, 0);

            state.*.request_raw = null;
            _ = uv.uv_read_start(req.*.handle, alloc_buffer, on_read);
        }

        fn on_write_complete_no_keep_alive(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            var write_req_pool = ctx.*.write_req_allocator;
            defer write_req_pool.destroy(req);

            if (status < 0) {
                logger.err("Write error: {s}", .{uv.uv_strerror(status)});
            }
            _ = uv.uv_close(@ptrCast(req.*.handle), on_close);
        }

        fn start_request(map_pool: *map_t, request_pool: *request_pool_t) !init_request_t {
            const request = try request_pool.create();
            request.* = try Request.init(map_pool);

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

        fn create_response(ctx: *Context) !init_response_t {
            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const arena_pool = ctx.*.arena_allocator;
            const allocator = ctx.*.allocator.*;

            const arena = arena_pool.create() catch {
                logger.err("There was an error initializing the arena", .{});
                return error.ArenaInitFailed;
            };
            arena.* = std.heap.ArenaAllocator.init(allocator);

            const response_struct = start_response(arena, map_pool, response_pool) catch {
                logger.err("There was an error initializing the response", .{});
                return error.ResponseInitFailed;
            };

            return response_struct;
        }

        fn set_response_and_send(state: *State, set_response_fn: ?*const fn(*Response) void) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const arena_pool = ctx.*.arena_allocator;

            const response_struct = create_response(ctx) catch |err| {
                logger.err("Error creating response: {}", .{err});
                return;
            };
            if (set_response_fn) |function| {
                function(response_struct.response);
            }
            defer {
                const arena = response_struct.response.*.arena;
                response_struct.cleanup(response_struct.response, map_pool, response_pool) catch {
                    logger.err("Failed to deinit response", .{});
                };
                arena_pool.destroy(arena);
            }

            send_response(response_struct.response, state, on_write_complete_no_keep_alive);
        }

        fn on_timeout(timer: [*c]uv.uv_timer_t) callconv(.c) void {
            logger.info("Connection closing due to inactivity", .{});

            const state: *State = @ptrCast(@alignCast(timer.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const stream = state.*.stream;

            if (state.*.request_raw) |request_raw| {
                ctx.*.allocator.free(request_raw);
            }

            if (state.*.is_idle) {
                _ = uv.uv_close(@ptrCast(stream), on_close);
            } else {
                set_response_and_send(state, Response.set_timeout_response);
            }
        }

        fn on_close(handle: [*c]uv.uv_handle_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            _ = uv.uv_timer_stop(&state.*.timer);

            if (state.*.is_idle) {
                logger.info("Connection closed", .{});
                const client_pool = ctx.client_allocator;
                const client: *uv.uv_tcp_t = @ptrCast(@alignCast(handle));
                client_pool.*.destroy(client);

                const state_pool = ctx.*.state_allocator;
                state_pool.*.destroy(state);
            }
        }

        fn append_buffer(allocator: mem.Allocator, old_data: []u8, new_data: []u8) ![]u8 {
            const old_len = old_data.len;
            const new_len = old_len + new_data.len;

            const new_buf = try allocator.alloc(u8, new_len);

            @memcpy(new_buf[0..old_len], old_data);
            @memcpy(new_buf[old_len..], new_data);

            return new_buf;
        }

        fn alloc_buffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            var buffer_pool = ctx.*.buffer_allocator;

            const memory: *[suggested_buffer_size]u8 = buffer_pool.create() catch |err| {
                logger.err("Error creating buffer: {}", .{err});
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

test "testing server" {
    const azig = Server(void, void);
    const Request = request_t(void);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const on_response = struct {
        fn on_response(request: *Request, response: *Response) !void {
            if (std.mem.eql(u8, request.path, "/")) {
                response.*.body = "Home Page";
                try response.*.addHeader("Content-Type", "text/plain");
            } else if (std.mem.eql(u8, request.path, "/error")) {
                response.*.set_error_response();
            } else if (std.mem.eql(u8, request.path, "/bad-request")) {
                response.*.set_bad_request_response();
            } else if (std.mem.eql(u8, request.path, "/timeout")) {
                response.*.set_timeout_response();
            } else if (std.mem.eql(u8, request.path, "/custom-status")) {
                response.*.status_code = 201;
                response.*.body = "Created";
            } else {
                response.*.status_code = 404;
                response.*.body = "Not Found";
            }
        }
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

    // Basic GET request to root path
    {
        const uri = try std.Uri.parse("http://localhost:2500");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.ok);

        const body = try req.reader().readAllAlloc(allocator, 1024);
        defer allocator.free(body);
        try testing.expectEqualStrings("Home Page", body);
    }

    // GET request to error endpoint
    {
        const uri = try std.Uri.parse("http://localhost:2500/error");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.internal_server_error);
    }

    // GET request to bad-request endpoint
    {
        const uri = try std.Uri.parse("http://localhost:2500/bad-request");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.bad_request);
    }

    // GET request to timeout endpoint
    {
        const uri = try std.Uri.parse("http://localhost:2500/timeout");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.request_timeout);
    }

    // GET request to custom status endpoint
    {
        const uri = try std.Uri.parse("http://localhost:2500/custom-status");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.created);

        const body = try req.reader().readAllAlloc(allocator, 1024);
        defer allocator.free(body);
        try testing.expectEqualStrings("Created", body);
    }

    // GET request to non-existent path
    {
        const uri = try std.Uri.parse("http://localhost:2500/not-found");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.not_found);

        const body = try req.reader().readAllAlloc(allocator, 1024);
        defer allocator.free(body);
        try testing.expectEqualStrings("Not Found", body);
    }

    // POST body bigger than buffer size
    {
        var buffer: [131072]u8 = undefined;
        for (0..buffer.len) |i| {
            buffer[i] = @intCast(i % 256);
        }

        const uri = try std.Uri.parse("http://localhost:2500");
        var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = 131072 };
        try req.send();
        _ = try req.write(&buffer);
        try req.finish();
        try req.wait();
    }

    // POST explicit content-length = 0 and no body
    {
        const uri = try std.Uri.parse("http://localhost:2500");
        var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = 0 };
        try req.send();
        try req.finish();
        try req.wait();
    }
}

test "should handle mid-request timeout gracefully" {
    const azig = Server(void, void);
    const Request = request_t(void);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const on_response = struct {
        fn on_response(_: *Request, _: *Response) !void {
            std.time.sleep(200 * std.time.ns_per_ms);
        }
    }.on_response;

    const run = struct {
        fn run(server_ptr: *azig) !void {
            try server_ptr.start();
        }
    }.run;

    var server = azig.init(&allocator, Config{
        .timeout = 100,
    }, on_response, {});
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.time.sleep(1_000 * std.time.ns_per_ms);
        server.stop();
        thread.join();
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    {
        const uri = try std.Uri.parse("http://localhost:2500");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.request_timeout);
    }
}

test "should call middlewares in order" {
    const RequestContext = struct {
      counter: u8,
    };
    const azig = Server(void, RequestContext);
    const Request = request_t(RequestContext);
    const Action = action_t(void, RequestContext);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const on_response = struct {
        fn on_response(request: *Request, _: *Response) !void {
            try testing.expectEqual(request.context.counter, 3);
            request.context.counter = 4;
        }
    }.on_response;

    const mid1 = struct {
        fn mid(request: *Request, _: *Response, action: Action) !void {
            request.context.counter = 1;
            try action.next();
            try testing.expectEqual(request.context.counter, 6);
            request.context.counter = 7;
        }
    }.mid;

    const mid2 = struct {
        fn mid(request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(request.context.counter, 1);
            request.context.counter = 2;
            try action.next();
            try testing.expectEqual(request.context.counter, 5);
            request.context.counter = 6;
        }
    }.mid;

    const mid3 = struct {
        fn mid(request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(request.context.counter, 2);
            request.context.counter = 3;
            try action.next();
            try testing.expectEqual(request.context.counter, 4);
            request.context.counter = 5;
        }
    }.mid;

    const run = struct {
        fn run(server_ptr: *azig) !void {
            try server_ptr.start();
        }
    }.run;

    var server = azig.init(&allocator, Config{}, on_response, {});
    server.register_middlewares(&.{mid1, mid2, mid3});
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        server.stop();
        thread.join();
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    {
        const uri = try std.Uri.parse("http://localhost:2500");
        var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        try testing.expectEqual(req.response.status, std.http.Status.ok);
    }
}
