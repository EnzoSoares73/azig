/// Represents a HTTP server implementation using libuv
const std = @import("std");
const mem = std.mem;
const uv = @import("uv");
const Config = @import("config.zig").Config;
const GenericRequest = @import("request.zig").GenericRequest;
const Response = @import("response.zig").Response;
const GenericAction = @import("action.zig").GenericAction;
const suggested_buffer_size = @import("constants.zig").suggested_buffer_size;
const Callback = @import("constants.zig").Callback;
const read_chunk_size = @import("constants.zig").read_chunk_size;
const ResponsePool = @import("constants.zig").ResponsePool;
const ClientPool = @import("constants.zig").ClientPool;
const WriteReqPool = @import("constants.zig").WriteReqPool;
const ArenaPool = @import("constants.zig").ArenaPool;
const Middleware = @import("constants.zig").Middleware;
const StringMapPool = @import("constants.zig").StringMapPool;
const errorToStatusCode = @import("http_error.zig").errorToStatusCode;
const HttpError = @import("http_error.zig").HttpError;
const toHttpError = @import("http_error.zig").toHttpError;

const Mutex = @import("pools/mutex.zig").Mutex;
const logger = std.log.scoped(.server);

/// Largest accepted request head (request line + headers). Larger heads get a 431.
const max_head_size: usize = suggested_buffer_size;
/// Read and write buffers whose capacity grew past this (a large request or response) are
/// freed once they are empty, so one big message does not pin memory for the whole connection.
const max_retained_buffer_size: usize = suggested_buffer_size;

pub fn Server(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = GenericRequest(RequestContext);

    // Requests are created and released on the loop thread only (the worker thread uses a
    // request, but never creates or destroys one).
    const RequestPool = std.heap.MemoryPool(Request);

    const State = struct {
        context: *anyopaque,
        timer: uv.uv_timer_t,
        stream: [*c]uv.uv_stream_t,
        /// Bytes read from the connection that have not been consumed yet: the request being
        /// read or processed, possibly followed by the start of the next (pipelined) request.
        /// The parsed request points into this buffer. libuv reads straight into its spare
        /// capacity (see allocBuffer), and it is kept across keep-alive requests.
        read_buf: std.ArrayList(u8),
        /// True while reading is started on the stream (between uv_read_start and uv_read_stop).
        reading: bool,
        /// Length of the current request's head; valid while `request` is set.
        head_len: usize,
        /// Total length (head + body) of the request being processed.
        request_len: usize,
        request: ?*Request,
        /// Set by the worker thread in `process`, consumed in `afterProcess`.
        response: ?*Response,
        req: uv.uv_work_t,
        /// Serialized response. It must not be touched while `writing`; afterwards it is
        /// cleared, keeping its capacity for the next response on this connection.
        write_buf: std.ArrayList(u8),
        /// True while a write is in flight.
        writing: bool,
        keep_alive: bool,
        /// True while the request is queued on / running in the thread pool.
        processing: bool,
        closing: bool,
        /// The handler exceeded the timeout and a 408 was sent in its place.
        timed_out: bool,
        /// Number of libuv handles (stream + timer) that have not been closed yet.
        open_handles: u8,
    };

    // Only used from the loop thread.
    const StatePool = std.heap.MemoryPool(State);

    const CallbackFn = Callback(AppContext, RequestContext);

    const Action = GenericAction(AppContext, RequestContext);

    const MiddlewareFn = Middleware(AppContext, RequestContext);

    //Application-wide context
    const Context = struct {
        allocator: std.mem.Allocator,
        callback: CallbackFn,
        request_allocator: *RequestPool,
        response_allocator: *ResponsePool,
        client_allocator: *ClientPool,
        write_req_allocator: *WriteReqPool,
        arena_allocator: *ArenaPool,
        state_allocator: *StatePool,
        map_allocator: *StringMapPool,
        app_context: *AppContext,
        middleware_list: []const MiddlewareFn,
        timeout: u64,
        max_payload_size: u64,
        allowed_methods: []const []const u8,
    };

    return struct {
        allocator: mem.Allocator,
        config: Config = .{},
        callback: CallbackFn,
        app_context: if (AppContext == void) void else *AppContext,
        middleware_list: []const MiddlewareFn,

        // Shutdown signalling. `stop()` may be called from any thread, so it never touches the
        // loop directly: it wakes the loop thread through `stop_signal` (uv_async_send is the
        // only thread-safe libuv call). `mutex` guards both fields, so `stop()` can never send
        // on a handle that is closing or whose memory is gone.
        mutex: Mutex,
        stop_signal: ?*uv.uv_async_t = null,
        stop_requested: bool = false,
        /// The port actually bound while the server is listening (resolves `.port = 0` to the
        /// port the OS picked), 0 otherwise. Guarded by `mutex`; read it with `listeningPort()`.
        bound_port: u16 = 0,
        // Only accessed from the loop thread.
        listener: ?*uv.uv_tcp_t = null,

        const Self = @This();

        pub const StartError = error{
            LoopInitFailed,
            ServerInitFailed,
            InvalidListenAddress,
            BindFailed,
            ListenFailed,
            StopSignalInitFailed,
        };

        /// Call `deinit` once the server is no longer used (after `start()` has returned).
        pub fn init(allocator: mem.Allocator, comptime config: Config, callback: CallbackFn, app_context: if (AppContext == void) void else *AppContext) Mutex.InitError!Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .callback = callback,
                .app_context = app_context,
                .middleware_list = &.{},
                .mutex = try Mutex.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit(self.allocator);
            self.* = undefined;
        }

        /// Runs the server on the calling thread. Blocks until `stop()` is called (from any
        /// thread) and every open connection and in-flight request has been wound down.
        /// Returns an error if the loop cannot be set up or the address cannot be bound.
        pub fn start(self: *Self) !void {
            logger.info("Starting server", .{});

            const allocator = self.allocator;
            const config = self.config;
            const callback = self.callback;
            const app_context = if (AppContext == void) undefined else self.app_context;
            const middleware_list = self.middleware_list;

            const ctx: *Context = try allocator.create(Context);
            defer allocator.destroy(ctx);

            ctx.*.allocator = allocator;
            ctx.*.callback = callback;
            ctx.*.app_context = app_context;
            ctx.*.middleware_list = middleware_list;
            ctx.*.timeout = config.timeout;
            ctx.*.max_payload_size = config.max_payload_size;
            ctx.*.allowed_methods = config.allowed_methods;

            const cleanup = try initPools(allocator, ctx, config.pool_size);
            defer cleanup(allocator, ctx);
            logger.debug("Pools allocated", .{});

            var loop: uv.uv_loop_t = undefined;
            try uvCheck(uv.uv_loop_init(&loop), "initialize the event loop", error.LoopInitFailed);
            // Runs before the pools are cleaned up: closes whatever is still open (e.g. on a
            // bind error), lets every close callback and in-flight request finish, then
            // closes the loop.
            defer closeLoop(&loop);

            var server: uv.uv_tcp_t = undefined;
            try uvCheck(uv.uv_tcp_init(&loop, &server), "initialize the server handle", error.ServerInitFailed);
            server.data = @constCast(ctx);

            // libuv expects a null-terminated string; the configured address is a plain slice.
            const listen_address = try allocator.dupeSentinel(u8, config.listen_address, 0);
            defer allocator.free(listen_address);

            var addr: uv.struct_sockaddr_in = undefined;
            try uvCheck(uv.uv_ip4_addr(listen_address.ptr, @intCast(config.port), &addr), "parse the listen address", error.InvalidListenAddress);
            // Some platforms only report errors such as EADDRINUSE from uv_listen, so both are checked.
            try uvCheck(uv.uv_tcp_bind(&server, @ptrCast(&addr), 0), "bind the server", error.BindFailed);
            try uvCheck(uv.uv_listen(@ptrCast(&server), config.backlog_size, onConnection), "listen", error.ListenFailed);

            // With `.port = 0` the OS picks the port, so read back what was actually bound.
            var bound_port = config.port;
            {
                var bound_addr: uv.struct_sockaddr_in = undefined;
                var bound_len: c_int = @sizeOf(uv.struct_sockaddr_in);
                if (uv.uv_tcp_getsockname(&server, @ptrCast(&bound_addr), &bound_len) == 0) {
                    bound_port = mem.bigToNative(u16, bound_addr.sin_port);
                }
            }

            var stop_signal: uv.uv_async_t = undefined;
            try uvCheck(uv.uv_async_init(&loop, &stop_signal, onStopSignal), "initialize the stop signal", error.StopSignalInitFailed);
            stop_signal.data = self;
            self.listener = &server;

            // Publish the stop signal. If stop() was already called (before the signal existed),
            // send it now so the loop shuts down as soon as it starts running.
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.stop_signal = &stop_signal;
                self.bound_port = bound_port;
                if (self.stop_requested) {
                    _ = uv.uv_async_send(&stop_signal);
                }
            }
            defer {
                self.mutex.lock();
                self.stop_signal = null;
                self.bound_port = 0;
                self.stop_requested = false;
                self.mutex.unlock();
                self.listener = null;
            }

            logger.info("Server listening on {s}:{d}", .{ config.listen_address, bound_port });
            _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);
        }

        /// The port the server is listening on, or null if it is not (yet) listening. Safe to
        /// call from any thread.
        pub fn listeningPort(self: *Self) ?u16 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return if (self.stop_signal != null) self.bound_port else null;
        }

        /// Asks the server to shut down. Safe to call from any thread, and before or while
        /// `start()` is running. Returns immediately; `start()` returns once shutdown is complete.
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.stop_requested = true;
            if (self.stop_signal) |signal| {
                _ = uv.uv_async_send(signal);
            }
        }

        fn uvCheck(result: c_int, comptime action: []const u8, err: StartError) StartError!void {
            if (result < 0) {
                // Warning rather than error: the failure is returned to the caller of start(),
                // which decides how serious it is.
                logger.warn("Failed to " ++ action ++ ": {s}", .{uv.uv_strerror(result)});
                return err;
            }
        }

        // Runs on the loop thread when stop() is called. Stops accepting connections and closes
        // every open connection. uv_run then returns once all close callbacks have run and the
        // requests still in the thread pool have finished (afterProcess frees their state).
        fn onStopSignal(handle: [*c]uv.uv_async_t) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(handle.*.data));

            {
                self.mutex.lock();
                defer self.mutex.unlock();
                // From now on stop() won't touch the handle, so it can be closed.
                self.stop_signal = null;
            }
            uv.uv_close(@ptrCast(handle), null);

            if (self.listener) |listener| {
                uv.uv_close(@ptrCast(listener), null);
            }

            uv.uv_walk(handle.*.loop, closeConnectionHandle, null);
            logger.info("Server stopping", .{});
        }

        fn closeConnectionHandle(handle: [*c]uv.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
            if (uv.uv_is_closing(handle) != 0) return;

            // The listener and the stop signal are already closing, so every remaining TCP
            // handle is a client connection. Its timer is closed by closeConnection.
            if (uv.uv_handle_get_type(handle) == @as(uv.uv_handle_type, uv.UV_TCP)) {
                const state: *State = @ptrCast(@alignCast(handle.*.data));
                closeConnection(state);
            }
        }

        fn closeLoop(loop: *uv.uv_loop_t) void {
            // After a normal shutdown nothing is left open; after a startup error the listener
            // (and possibly the stop signal) still are.
            uv.uv_walk(loop, struct {
                fn cb(handle: [*c]uv.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
                    if (uv.uv_is_closing(handle) == 0) {
                        uv.uv_close(handle, null);
                    }
                }
            }.cb, null);
            _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);

            const status = uv.uv_loop_close(loop);
            if (status != 0) {
                logger.err("Failed to close the event loop: {s}", .{uv.uv_strerror(status)});
            } else {
                logger.info("Server stopped", .{});
            }
        }

        pub fn registerMiddlewares(self: *Self, middleware_list: []const MiddlewareFn) void {
            self.middleware_list = middleware_list;
        }

        // Connection lifecycle (all of this runs on the loop thread, except `process`):
        //
        //   reading ──(request complete)──> processing ──(afterProcess)──> writing ──(keep-alive)──> reading
        //
        // - While processing, reading and the inactivity timer are stopped, so the worker thread has
        //   exclusive access to the request and its buffer.
        // - The serialized response is in `state.write_buf`, which must not be touched while `state.writing`.
        // - A connection owns two libuv handles (the TCP stream and the timer). Both must be closed,
        //   and no work or write may be pending, before the state can be returned to the pool.
        fn onConnection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            const ctx: *Context = @ptrCast(@alignCast(server.*.data));
            const client_pool = ctx.client_allocator;
            const state_pool = ctx.state_allocator;

            if (status < 0) {
                return;
            }

            const client = client_pool.create(ctx.allocator) catch {
                logger.err("Failed to allocate client", .{});
                return;
            };

            const state = state_pool.create(ctx.allocator) catch {
                logger.err("Failed to allocate state", .{});
                client_pool.destroy(client);
                return;
            };

            const stream: [*c]uv.uv_stream_t = @ptrCast(client);

            state.* = .{
                .context = @ptrCast(@alignCast(ctx)),
                .timer = undefined,
                .stream = stream,
                .read_buf = .empty,
                .reading = false,
                .head_len = 0,
                .request_len = 0,
                .request = null,
                .response = null,
                .req = undefined,
                .write_buf = .empty,
                .writing = false,
                .keep_alive = false,
                .processing = false,
                .closing = false,
                .timed_out = false,
                .open_handles = 0,
            };

            if (uv.uv_tcp_init(server.*.loop, client) != 0) {
                logger.err("Failed to initialize client handle", .{});
                state_pool.destroy(state);
                client_pool.destroy(client);
                return;
            }
            client.*.data = state;
            state.open_handles += 1;

            _ = uv.uv_timer_init(server.*.loop, &state.timer);
            state.timer.data = state;
            state.open_handles += 1;

            if (uv.uv_accept(server, stream) == 0) {
                logger.debug("Connection accepted", .{});
                // Responses are written in one go, so there is nothing to gain from Nagle's algorithm.
                _ = uv.uv_tcp_nodelay(client, 1);
                _ = uv.uv_timer_start(&state.*.timer, onTimeout, ctx.*.timeout, 0);
                startReading(state);
            } else {
                logger.debug("Connection refused", .{});
                closeConnection(state);
            }
        }

        fn startReading(state: *State) void {
            if (uv.uv_read_start(state.*.stream, allocBuffer, onRead) == 0) {
                state.*.reading = true;
            }
        }

        fn stopReading(state: *State) void {
            _ = uv.uv_read_stop(state.*.stream);
            state.*.reading = false;
        }

        /// Serializes the response into the connection's write buffer and starts writing it.
        /// The response itself can be destroyed as soon as this returns.
        fn sendResponse(state: *State, response: *Response) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const allocator = ctx.*.allocator;
            const write_req_pool = ctx.*.write_req_allocator;

            std.debug.assert(!state.*.writing);

            response.*.serializeInto(allocator, &state.*.write_buf) catch |err| {
                // E.g. a handler set a header containing CR/LF. Send a plain 500 instead.
                logger.err("Failed to serialize response: {}", .{err});
                response.*.setResponseError(500);
                response.*.serializeInto(allocator, &state.*.write_buf) catch {
                    closeConnection(state);
                    return;
                };
            };

            const write_req = write_req_pool.create(allocator) catch {
                logger.err("Failed to allocate write_req", .{});
                closeConnection(state);
                return;
            };

            const data = state.*.write_buf.items;
            var buf_resp = uv.uv_buf_init(data.ptr, @intCast(data.len));
            const result = uv.uv_write(write_req, state.*.stream, &buf_resp, 1, onWriteComplete);
            if (result != 0) {
                logger.err("Write error: {s}", .{uv.uv_strerror(result)});
                write_req_pool.destroy(write_req);
                closeConnection(state);
                return;
            }
            state.*.writing = true;
        }

        /// Empties the write buffer once a write is done, keeping its capacity unless a large
        /// response made it grow.
        fn resetWriteBuf(state: *State) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            if (state.*.write_buf.capacity > max_retained_buffer_size) {
                state.*.write_buf.clearAndFree(ctx.*.allocator);
            } else {
                state.*.write_buf.clearRetainingCapacity();
            }
        }

        fn afterProcess(req: [*c]uv.uv_work_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            state.*.processing = false;
            const response = state.*.response;
            state.*.response = null;

            if (status < 0) {
                logger.debug("Operation cancelled", .{});
                closeConnection(state);
            } else if (!state.*.closing and !state.*.timed_out) {
                // No timeouts while the response is being written; onWriteComplete
                // restarts the timer for keep-alive connections.
                _ = uv.uv_timer_stop(&state.*.timer);
                if (response) |r| {
                    // A HEAD response carries the headers (including Content-Length) of the
                    // equivalent GET response, but never a body.
                    if (mem.eql(u8, state.*.request.?.method, "HEAD")) {
                        r.*.send_body = false;
                    }
                    sendResponse(state, r);
                } else {
                    setResponseAndSend(state, 500);
                }
            }

            // The response has been serialized into its own buffer, so the request,
            // the response and the response arena can all be released now.
            if (response) |r| destroyResponse(ctx, r);
            releaseRequest(state);
            consumeRequestBytes(state);

            if (state.*.closing) {
                tryFreeState(state);
            }
        }

        fn process(req: [*c]uv.uv_work_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            const request = state.*.request.?;

            const response = createResponse(ctx) catch |err| {
                logger.err("Error creating response: {}", .{err});
                return;
            };

            state.*.response = response;

            logger.debug("{s} {s}", .{ request.method, request.path });

            handleCallback(ctx, request, response);
        }

        fn handleCallback(ctx: *Context, request: *Request, response: *Response) void {
            const action: Action = .{
                .app_context = ctx.*.app_context,
                .index = 0,
                .middleware_list = ctx.*.middleware_list,
                .request = request,
                .response = response,
                .callback = ctx.*.callback,
            };
            action.next() catch |err| {
                const http_error = toHttpError(err, HttpError.InternalServerError);
                response.*.setResponseError(errorToStatusCode(http_error));
            };
        }

        fn transferBufferSlice(old_buffer: []u8, old_slice: []u8, new_buffer: []u8) []u8 {
            const old_buffer_pointer = @intFromPtr(old_buffer.ptr);
            const old_slice_pointer = @intFromPtr(old_slice.ptr);
            const offset = old_slice_pointer - old_buffer_pointer;
            return new_buffer[offset .. offset + old_slice.len];
        }

        // When the read buffer grows it may be moved to a new allocation. The request head may
        // already have been parsed by then (the body is still arriving), so its slices are
        // rebased onto the new buffer. Only the addresses of the old buffer are used; it is
        // never dereferenced (it has already been freed).
        fn transferBufferSlices(request: *Request, old_buffer: []u8, new_buffer: []u8) void {
            request.*.method = transferBufferSlice(old_buffer, @constCast(request.*.method), new_buffer);
            request.*.path = transferBufferSlice(old_buffer, @constCast(request.*.path), new_buffer);
            request.*.version = transferBufferSlice(old_buffer, @constCast(request.*.version), new_buffer);
            if (request.*.body) |body| {
                request.*.body = transferBufferSlice(old_buffer, @constCast(body), new_buffer);
            }

            transferMap(request.headers, old_buffer, new_buffer);
            transferMap(request.params, old_buffer, new_buffer);
        }

        fn transferMap(map: *std.StringHashMap([]const u8), old_buffer: []u8, new_buffer: []u8) void {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                const value = entry.value_ptr.*;
                entry.value_ptr.* = transferBufferSlice(old_buffer, @constCast(value), new_buffer);

                const key = entry.key_ptr.*;
                entry.key_ptr.* = transferBufferSlice(old_buffer, @constCast(key), new_buffer);
            }
        }

        fn onRead(stream: [*c]uv.uv_stream_t, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(stream.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            if (buf.*.base == null) {
                logger.debug("Closing connection", .{});
                closeConnection(state);
                return;
            }

            // nread == 0 is libuv's equivalent of EAGAIN: nothing was read, but the
            // connection is fine.
            if (nread == 0) {
                return;
            }

            // libuv (1.53, on Unix and Windows) calls allocBuffer and onRead back to back and
            // never reports a read after uv_read_stop. Should that ever change, bytes arriving
            // while the connection is not reading (e.g. a 408 is being sent) are dropped rather
            // than appended to a buffer that may have been cleared.
            if (nread > 0 and !state.*.reading) {
                return;
            }

            if (nread < 0) {
                switch (nread) {
                    // There is no more data to be read
                    uv.UV_EOF => {},
                    else => {
                        logger.err("Read error: {s}", .{uv.uv_strerror(@intCast(nread))});
                    },
                }
                closeConnection(state);
                return;
            }

            _ = uv.uv_timer_start(&state.*.timer, onTimeout, ctx.*.timeout, 0);

            // libuv read straight into read_buf's spare capacity (see allocBuffer).
            const new_read: usize = @intCast(nread);
            std.debug.assert(buf.*.base == state.*.read_buf.unusedCapacitySlice().ptr);
            std.debug.assert(new_read <= state.*.read_buf.unusedCapacitySlice().len);
            state.*.read_buf.items.len += new_read;

            _ = tryDispatch(state);
        }

        const DispatchResult = enum {
            /// A complete request was handed to the thread pool.
            dispatched,
            /// The buffered bytes don't hold a complete request yet.
            need_more,
            /// The request was rejected (an error response is being sent) or the connection closed.
            failed,
        };

        /// Looks at the buffered bytes and, once they hold a complete request, parses it and
        /// queues it on the thread pool. Bytes after the request (a pipelined request) stay in
        /// the buffer and are looked at once the response has been written.
        fn tryDispatch(state: *State) DispatchResult {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const data = state.*.read_buf.items;

            if (state.*.request == null) {
                const head_len = Request.headLength(data) orelse {
                    if (data.len > max_head_size) {
                        handleErrorAndStopReading(state, 431);
                        return .failed;
                    }
                    return .need_more;
                };
                if (head_len > max_head_size) {
                    handleErrorAndStopReading(state, 431);
                    return .failed;
                }

                const request = startRequest(ctx.*.allocator, ctx.*.map_allocator, ctx.*.request_allocator) catch |err| {
                    logger.err("There was an error initializing the request: {}", .{err});
                    closeConnection(state);
                    return .failed;
                };
                state.*.request = request;
                state.*.head_len = head_len;

                request.*.parseRequest(data[0..head_len], ctx.*.allowed_methods) catch |err| {
                    logger.debug("{}", .{err});
                    const http_error = toHttpError(err, HttpError.BadRequest);
                    handleErrorAndStopReading(state, errorToStatusCode(http_error));
                    return .failed;
                };

                state.*.keep_alive = request.isKeepAlive();

                // Reject an oversized body up front instead of buffering it first.
                if (request.getHeader("Content-Length")) |header| {
                    const content_length = std.fmt.parseInt(usize, header, 10) catch 0;
                    if (content_length > ctx.*.max_payload_size) {
                        handleErrorAndStopReading(state, 413);
                        return .failed;
                    }
                }
            }

            const request = state.*.request.?;
            const body_data = data[state.*.head_len..];

            const maybe_body_len = request.*.bodyLength(body_data) catch {
                handleErrorAndStopReading(state, 400);
                return .failed;
            };
            const body_len = maybe_body_len orelse {
                if (body_data.len > ctx.*.max_payload_size) {
                    handleErrorAndStopReading(state, 413);
                    return .failed;
                }
                return .need_more;
            };
            if (body_len > ctx.*.max_payload_size) {
                handleErrorAndStopReading(state, 413);
                return .failed;
            }

            state.*.request_len = state.*.head_len + body_len;
            request.*.body = if (body_len > 0) body_data[0..body_len] else null;

            if (request.*.getHeader("Transfer-Encoding") != null) {
                // bodyLength only accepts chunked. Decoding happens in place, within this
                // request's bytes, so any pipelined bytes after it are untouched.
                request.*.parseChunkedBody() catch {
                    handleErrorAndStopReading(state, 400);
                    return .failed;
                };
            }

            // The worker thread now owns the request: stop reading so no new data can touch it
            // (reading restarts once the response has been written, see onWriteComplete).
            // The timer is restarted to give the handler the full timeout: if it takes longer,
            // the client gets a 408 (see onTimeout).
            stopReading(state);
            _ = uv.uv_timer_start(&state.*.timer, onTimeout, ctx.*.timeout, 0);

            state.*.req.data = @ptrCast(state);
            state.*.processing = true;
            const res = uv.uv_queue_work(state.*.stream.*.loop, @ptrCast(@alignCast(&state.*.req)), process, afterProcess);
            if (res != 0) {
                state.*.processing = false;
                closeConnection(state);
                return .failed;
            }
            return .dispatched;
        }

        fn onWriteComplete(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            ctx.*.write_req_allocator.destroy(req);

            state.*.writing = false;
            resetWriteBuf(state);

            if (state.*.closing) {
                tryFreeState(state);
                return;
            }

            if (status < 0) {
                logger.err("Write error: {s}", .{uv.uv_strerror(status)});
                closeConnection(state);
                return;
            }

            if (!state.*.keep_alive) {
                closeConnection(state);
                return;
            }

            _ = uv.uv_timer_start(&state.*.timer, onTimeout, ctx.*.timeout, 0);

            // A pipelined request may already be fully buffered. No read event will
            // arrive for it, so handle it now.
            if (state.*.read_buf.items.len > 0) {
                switch (tryDispatch(state)) {
                    .dispatched, .failed => return,
                    .need_more => {},
                }
            }

            startReading(state);
        }

        fn startRequest(allocator: mem.Allocator, map_pool: *StringMapPool, request_pool: *RequestPool) !*Request {
            const request = try request_pool.create(allocator);
            errdefer request_pool.destroy(request);
            request.* = try Request.init(map_pool);
            return request;
        }

        fn startResponse(arena: *std.heap.ArenaAllocator, map_pool: *StringMapPool, response_pool: *ResponsePool) !*Response {
            const response = try response_pool.create();
            errdefer response_pool.destroy(response);
            response.* = try Response.init(arena, map_pool);
            return response;
        }

        fn createResponse(ctx: *Context) !*Response {
            const response_pool = ctx.*.response_allocator;
            const map_pool = ctx.*.map_allocator;
            const arena_pool = ctx.*.arena_allocator;
            const allocator = ctx.*.allocator;

            const arena = arena_pool.create() catch {
                logger.err("There was an error initializing the arena", .{});
                return error.ArenaInitFailed;
            };
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer {
                arena.deinit();
                arena_pool.destroy(arena);
            }

            return startResponse(arena, map_pool, response_pool) catch {
                logger.err("There was an error initializing the response", .{});
                return error.ResponseInitFailed;
            };
        }

        fn destroyResponse(ctx: *Context, response: *Response) void {
            const arena = response.*.arena;
            response.*.deinit(ctx.*.map_allocator);
            ctx.*.response_allocator.destroy(response);
            arena.deinit();
            ctx.*.arena_allocator.destroy(arena);
        }

        /// Releases the parsed request (if any). Its bytes stay in the read buffer.
        fn releaseRequest(state: *State) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            if (state.*.request) |request| {
                request.*.deinit(ctx.*.map_allocator);
                ctx.*.request_allocator.destroy(request);
                state.*.request = null;
            }
            state.*.head_len = 0;
        }

        /// Drops the bytes of the request that was just processed, keeping anything after it
        /// (the start of a pipelined request).
        fn consumeRequestBytes(state: *State) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const items = state.*.read_buf.items;

            const remaining = items.len - state.*.request_len;
            mem.copyForwards(u8, items[0..remaining], items[state.*.request_len..]);
            state.*.read_buf.shrinkRetainingCapacity(remaining);
            state.*.request_len = 0;

            // Don't let one large request pin its buffer for the rest of the connection.
            if (remaining == 0 and state.*.read_buf.capacity > max_retained_buffer_size) {
                state.*.read_buf.clearAndFree(ctx.*.allocator);
            }
        }

        /// Releases the request and every buffered byte, e.g. when the connection
        /// is about to be closed.
        fn discardRequest(state: *State) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            releaseRequest(state);
            state.*.read_buf.clearAndFree(ctx.*.allocator);
            state.*.request_len = 0;
        }

        /// Sends an error response and closes the connection once it has been written.
        fn setResponseAndSend(state: *State, code: u16) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            // No more timeouts: the connection is closed as soon as the write completes.
            _ = uv.uv_timer_stop(&state.*.timer);
            state.*.keep_alive = false;

            const response = createResponse(ctx) catch |err| {
                logger.err("Error creating response: {}", .{err});
                closeConnection(state);
                return;
            };
            defer destroyResponse(ctx, response);

            response.*.setResponseError(code);
            sendResponse(state, response);
        }

        fn handleErrorAndStopReading(state: *State, code: u16) void {
            stopReading(state);
            discardRequest(state);
            setResponseAndSend(state, code);
        }

        // The timer runs while the connection is reading and while a request is being processed.
        // It is stopped while a response is being written, so it never races with a pending write.
        fn onTimeout(timer: [*c]uv.uv_timer_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(timer.*.data));

            if (state.*.processing) {
                // The handler is taking too long. Answer 408 now and close the connection once
                // it is written. The worker still owns the request, so it is left alone:
                // afterProcess drops the handler's response and releases the request.
                logger.debug("Request handler exceeded the timeout", .{});
                state.*.timed_out = true;
                setResponseAndSend(state, 408);
                return;
            }

            logger.debug("Connection closing due to inactivity", .{});
            stopReading(state);
            discardRequest(state);
            setResponseAndSend(state, 408);
        }

        /// Starts closing both handles owned by the connection. The state is freed once
        /// both close callbacks have run and no work or write is pending.
        fn closeConnection(state: *State) void {
            if (state.*.closing) return;
            state.*.closing = true;

            _ = uv.uv_timer_stop(&state.*.timer);
            uv.uv_close(@ptrCast(@alignCast(state.*.stream)), onHandleClosed);
            uv.uv_close(@ptrCast(@alignCast(&state.*.timer)), onHandleClosed);
        }

        fn onHandleClosed(handle: [*c]uv.uv_handle_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            state.*.open_handles -= 1;
            tryFreeState(state);
        }

        fn tryFreeState(state: *State) void {
            if (state.*.open_handles != 0 or state.*.processing or state.*.writing) {
                return;
            }

            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const allocator = ctx.*.allocator;

            discardRequest(state);
            state.*.write_buf.deinit(allocator);

            logger.debug("Connection closed", .{});
            ctx.*.client_allocator.destroy(@ptrCast(@alignCast(state.*.stream)));
            ctx.*.state_allocator.destroy(state);
        }

        fn allocBuffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            // libuv reads straight into the spare capacity of the connection's read buffer,
            // so the bytes need no copy and the buffer is reused across keep-alive requests.
            const old_items = state.*.read_buf.items;
            state.*.read_buf.ensureUnusedCapacity(ctx.*.allocator, read_chunk_size) catch |err| {
                logger.err("Error growing the read buffer: {}", .{err});
                buf.* = uv.uv_buf_init(null, 0);
                return;
            };

            // Growing may have moved the buffer. If the request head was already parsed (its
            // body is still arriving), its slices point into the old buffer: rebase them.
            if (state.*.request) |request| {
                if (state.*.read_buf.items.ptr != old_items.ptr) {
                    transferBufferSlices(request, old_items, state.*.read_buf.items);
                }
            }

            const spare = state.*.read_buf.unusedCapacitySlice();
            const len: c_uint = @intCast(@min(spare.len, std.math.maxInt(c_uint)));
            buf.* = uv.uv_buf_init(spare.ptr, len);
        }

        fn initPools(allocator: mem.Allocator, ctx: *Context, pool_size: u16) !*const fn (allocator: mem.Allocator, ctx: *Context) void {
            ctx.*.request_allocator = try allocator.create(RequestPool);
            ctx.*.request_allocator.* = try RequestPool.initCapacity(allocator, pool_size);

            ctx.*.response_allocator = try allocator.create(ResponsePool);
            ctx.*.response_allocator.* = try ResponsePool.initPreheated(allocator, pool_size);

            ctx.*.client_allocator = try allocator.create(ClientPool);
            ctx.*.client_allocator.* = try ClientPool.initCapacity(allocator, pool_size);

            ctx.*.write_req_allocator = try allocator.create(WriteReqPool);
            ctx.*.write_req_allocator.* = try WriteReqPool.initCapacity(allocator, pool_size);

            ctx.*.arena_allocator = try allocator.create(ArenaPool);
            ctx.*.arena_allocator.* = try ArenaPool.initPreheated(allocator, pool_size);

            ctx.*.state_allocator = try allocator.create(StatePool);
            ctx.*.state_allocator.* = try StatePool.initCapacity(allocator, pool_size);

            //The poolsize is multiplied by three because it is used by the
            // request headers, the request params and the response headers
            ctx.*.map_allocator = try allocator.create(StringMapPool);
            ctx.*.map_allocator.* = try StringMapPool.initPreheated(allocator, pool_size * 3);

            return struct {
                fn clean(allocator_inner: mem.Allocator, ctx_inner: *Context) void {
                    ctx_inner.*.request_allocator.deinit(allocator_inner);
                    allocator_inner.destroy(ctx_inner.*.request_allocator);

                    ctx_inner.*.response_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.response_allocator);

                    ctx_inner.*.client_allocator.deinit(allocator_inner);
                    allocator_inner.destroy(ctx_inner.*.client_allocator);

                    ctx_inner.*.write_req_allocator.deinit(allocator_inner);
                    allocator_inner.destroy(ctx_inner.*.write_req_allocator);

                    ctx_inner.*.arena_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.arena_allocator);

                    ctx_inner.*.state_allocator.deinit(allocator_inner);
                    allocator_inner.destroy(ctx_inner.*.state_allocator);

                    ctx_inner.*.map_allocator.deinit();
                    allocator_inner.destroy(ctx_inner.*.map_allocator);
                }
            }.clean;
        }
    };
}

const testing = std.testing;

/// Waits until the server is accepting connections and returns the port it is listening on.
fn waitUntilListening(server: anytype) !u16 {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if (server.listeningPort()) |port| return port;
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, std.testing.io) catch {};
    }
    return error.ServerDidNotStart;
}

test "start returns an error when the port is already in use" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(_: *Request, _: *Response) !void {}
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var first = try TestServer.init(allocator, .{ .port = 0 }, onResponse, {});
    defer first.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&first});
    defer {
        first.stop();
        thread.join();
    }

    const port = try waitUntilListening(&first);

    var second = try TestServer.init(allocator, .{}, onResponse, {});
    defer second.deinit();
    second.config.port = port;
    if (second.start()) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.BindFailed or err == error.ListenFailed);
    }
}

test "stop called before start makes start return" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(_: *Request, _: *Response) !void {}
    }.onResponse;

    var server = try TestServer.init(allocator, .{ .port = 2602 }, onResponse, {});
    defer server.deinit();
    server.stop();
    // Would block forever if the early stop request were lost.
    try server.start();
}

test "testing server" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(request: *Request, response: *Response) !void {
            if (std.mem.eql(u8, request.path, "/")) {
                response.*.body = "Home Page";
                try response.*.addHeader("Content-Type", "text/plain");
            } else if (std.mem.eql(u8, request.path, "/error")) {
                return HttpError.InternalServerError;
            } else if (std.mem.eql(u8, request.path, "/bad-request")) {
                return HttpError.BadRequest;
            } else if (std.mem.eql(u8, request.path, "/timeout")) {
                response.*.setResponseError(408);
            } else if (std.mem.eql(u8, request.path, "/custom-status")) {
                response.*.status_code = 201;
                response.*.body = "Created";
            } else if (std.mem.eql(u8, request.path, "/chunked")) {
                response.*.body = request.body orelse "";
                try response.*.addHeader("Content-Type", "text/plain");
            } else {
                response.*.status_code = 404;
                response.*.body = "Not Found";
            }
        }
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, .{}, onResponse, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1000) }, std.testing.io) catch {};
        server.stop();
        thread.join();
    }

    _ = try waitUntilListening(&server);

    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    // Basic GET request to root path
    {
        var allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer allocating.deinit();
        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri }, .response_writer = &allocating.writer });

        try testing.expectEqual(std.http.Status.ok, req.status);
        try testing.expectEqualStrings("Home Page", allocating.written());
    }

    // GET request to error endpoint
    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500/error");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.internal_server_error, req.status);
    }

    // GET request to bad-request endpoint
    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500/bad-request");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.bad_request, req.status);
    }

    // GET request to timeout endpoint
    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500/timeout");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.request_timeout, req.status);
    }

    // GET request to custom status endpoint
    {
        var allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer allocating.deinit();

        const uri = try std.Uri.parse("http://127.0.0.1:2500/custom-status");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri }, .response_writer = &allocating.writer });

        try testing.expectEqual(std.http.Status.created, req.status);
        try testing.expectEqualStrings("Created", allocating.written());
    }

    // GET request to non-existent path
    {
        var allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer allocating.deinit();

        const uri = try std.Uri.parse("http://127.0.0.1:2500/not-found");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri }, .response_writer = &allocating.writer });

        try testing.expectEqual(std.http.Status.not_found, req.status);
        try testing.expectEqualStrings("Not Found", allocating.written());
    }

    // POST body bigger than buffer size
    {
        var buffer: [131072]u8 = undefined;
        for (0..buffer.len) |i| {
            buffer[i] = @intCast(i % 256);
        }

        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        const req = try client.fetch(.{ .method = .POST, .location = .{ .uri = uri }, .extra_headers = &.{.{ .name = "content_length", .value = "131072" }}, .payload = &buffer });

        try testing.expectEqual(std.http.Status.ok, req.status);
    }

    // Large body echoed back, then a small request on the same keep-alive connection.
    // The read buffer grows (and moves) while the body arrives, after the head was parsed,
    // so this checks that the request's slices are rebased; the large response then makes
    // the write buffer grow past the retained limit before it is reused for a small one.
    {
        const payload = try allocator.alloc(u8, 200_000);
        defer allocator.free(payload);
        for (payload, 0..) |*byte, i| byte.* = @intCast(i % 251);

        var allocating = try std.Io.Writer.Allocating.initCapacity(allocator, payload.len);
        defer allocating.deinit();

        const echo_uri = try std.Uri.parse("http://127.0.0.1:2500/chunked");
        const echo = try client.fetch(.{ .method = .POST, .location = .{ .uri = echo_uri }, .payload = payload, .response_writer = &allocating.writer });
        try testing.expectEqual(std.http.Status.ok, echo.status);
        try testing.expectEqualSlices(u8, payload, allocating.written());

        var small = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
        defer small.deinit();
        const root_uri = try std.Uri.parse("http://127.0.0.1:2500");
        const root = try client.fetch(.{ .method = .GET, .location = .{ .uri = root_uri }, .response_writer = &small.writer });
        try testing.expectEqual(std.http.Status.ok, root.status);
        try testing.expectEqualStrings("Home Page", small.written());
    }

    // POST explicit content-length = 0 and no body
    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        var req = try client.request(.POST, uri, .{});
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = 0 };

        var body = try req.sendBodyUnflushed(&.{});
        try body.end();
        try req.connection.?.flush();

        const redirect_buffer: []u8 = try allocator.alloc(u8, 8 * 1024);
        defer allocator.free(redirect_buffer);

        const response = try req.receiveHead(redirect_buffer);
        try testing.expectEqual(std.http.Status.ok, response.head.status);
    }

    // POST content-length > 0 and stop sending data mid_request
    // {
    //     const uri = try std.Uri.parse("http://127.0.0.1:2500");
    //     var req = try client.request(.POST, uri, .{});
    //     defer req.deinit();
    //
    //     req.transfer_encoding = .{ .content_length = -20 };
    //
    //     var body = try req.sendBodyUnflushed(&.{});
    //     try body.end();
    //     try req.connection.?.flush();
    //
    //     const redirect_buffer: []u8 = try allocator.alloc(u8, 8 * 1024);
    //     defer allocator.free(redirect_buffer);
    //
    //     var response = try req.receiveHead(redirect_buffer);
    //     try testing.expectEqual(std.http.Status.ok, response.head.status);
    // }

    // POST Transfer-Encoding: chunked
    {
        var allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
        defer allocating.deinit();

        const uri = try std.Uri.parse("http://127.0.0.1:2500/chunked");
        var req = try client.request(.POST, uri, .{});
        defer req.deinit();

        req.transfer_encoding = .chunked;
        var staging: [1024]u8 = undefined;
        var body = try req.sendBody(&staging);

        var writer = body.writer;
        _ = try writer.write("Hello");
        _ = try writer.write(" World");
        _ = try writer.write("!");

        try body.end();
        try req.connection.?.flush();

        const redirect_buffer: []u8 = try allocator.alloc(u8, 8 * 1024);
        defer allocator.free(redirect_buffer);

        const response = try req.receiveHead(redirect_buffer);

        try testing.expectEqual(std.http.Status.ok, response.head.status);
    }
}

test "should handle mid-request timeout gracefully" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(_: *Request, _: *Response) !void {
            try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(200) }, std.testing.io);
        }
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, Config{
        .timeout = 100,
    }, onResponse, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1000) }, std.testing.io) catch {};
        server.stop();
        thread.join();
    }

    _ = try waitUntilListening(&server);

    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.request_timeout, req.status);
    }
}

test "should handle mid-request timeout gracefully, where afterProcess is called BEFORE the on_close callback from the timeout" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(_: *Request, _: *Response) !void {
            // Slightly longer than the 100 ms timeout: the 408 is sent while the handler is still
            // running, and the handler finishes right around the time that write completes and
            // the connection is closed, so afterProcess can run before the close callbacks.
            try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(110) }, std.testing.io);
        }
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, Config{
        .timeout = 100,
    }, onResponse, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1000) }, std.testing.io) catch {};
        server.stop();
        thread.join();
    }

    _ = try waitUntilListening(&server);

    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.request_timeout, req.status);
    }
}

test "should enforce max_payload_size limit" {
    const TestServer = Server(void, void);
    const Request = GenericRequest(void);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(_: *Request, _: *Response) !void {}
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    const max_payload_size: u64 = comptime std.math.pow(u64, 2, 17);
    var server = try TestServer.init(allocator, Config{
        .max_payload_size = max_payload_size,
    }, onResponse, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(1000) }, std.testing.io) catch {};
        server.stop();
        thread.join();
    }

    _ = try waitUntilListening(&server);

    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    {
        var buffer: [std.math.pow(u64, 2, 18)]u8 = undefined;
        for (0..buffer.len) |i| {
            buffer[i] = @intCast(i % 256);
        }

        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        var buf: [20]u8 = undefined;
        const size = try std.fmt.bufPrint(&buf, "{d}", .{buffer.len});
        const req = try client.fetch(.{ .method = .POST, .location = .{ .uri = uri }, .extra_headers = &.{.{ .name = "content_length", .value = size }}, .payload = &buffer });

        try testing.expectEqual(std.http.Status.payload_too_large, req.status);
    }
}

test "should call middlewares in order" {
    const RequestContext = struct {
        counter: u8,
    };
    const TestServer = Server(void, RequestContext);
    const Request = GenericRequest(RequestContext);
    const Action = GenericAction(void, RequestContext);

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const onResponse = struct {
        fn onResponse(request: *Request, _: *Response) !void {
            try testing.expectEqual(request.context.counter, 3);
            request.context.counter = 4;
        }
    }.onResponse;

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
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, Config{}, onResponse, {});
    defer server.deinit();
    server.registerMiddlewares(&.{ mid1, mid2, mid3 });
    const thread = try std.Thread.spawn(.{}, run, .{&server});

    defer {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, std.testing.io) catch {};
        server.stop();
        thread.join();
    }

    _ = try waitUntilListening(&server);

    var client = std.http.Client{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    {
        const uri = try std.Uri.parse("http://127.0.0.1:2500");
        const req = try client.fetch(.{ .method = .GET, .location = .{ .uri = uri } });

        try testing.expectEqual(std.http.Status.ok, req.status);
    }
}

/// Test helpers that talk to the server over a raw socket, so tests control exactly which
/// bytes arrive in each read (pipelining, requests split mid-head, ...).
const raw_client = struct {
    const io = std.testing.io;

    fn connect(port: u16) !std.Io.net.Stream {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
        return address.connect(io, .{ .mode = .stream });
    }

    fn send(stream: std.Io.net.Stream, bytes: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    /// Reads until the server closes the connection.
    fn receiveAll(stream: std.Io.net.Stream, allocator: mem.Allocator) ![]u8 {
        var buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &buffer);
        return reader.interface.allocRemaining(allocator, .unlimited);
    }

    fn sleep(ms: i64) void {
        std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
    }

    /// The exact bytes the server sends for a 200 response with this body and no headers.
    fn okResponse(allocator: mem.Allocator, body: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    }
};

/// Answers every request with "<path>:<body>", so responses show which request they belong to.
fn echoPathAndBody(request: *GenericRequest(void), response: *Response) !void {
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "{s}:{s}", .{ request.path, request.body orelse "" });
}

fn runServer(server: *Server(void, void)) !void {
    try server.start();
}

test "pipelined requests sent in a single write are answered in order" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, echoPathAndBody, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);

    // Four requests, one write: no body, Content-Length body, chunked body, and a last one
    // that asks the server to close the connection once it has answered.
    try raw_client.send(stream, "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
        "POST /b HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" ++
        "POST /c HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n" ++
        "GET /d HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    const received = try raw_client.receiveAll(stream, allocator);
    defer allocator.free(received);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for ([_][]const u8{ "/a:", "/b:hello", "/c:abcde", "/d:" }) |body| {
        const response = try raw_client.okResponse(allocator, body);
        defer allocator.free(response);
        try expected.appendSlice(allocator, response);
    }
    try testing.expectEqualStrings(expected.items, received);
}

test "pipelined requests split across reads, including a large body, are answered in order" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, echoPathAndBody, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);

    // Several times read_chunk_size, so the read buffer has to grow (and may move) while
    // the body of an already parsed request is still arriving.
    const large_body = try allocator.alloc(u8, 5 * read_chunk_size + 123);
    defer allocator.free(large_body);
    for (large_body, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));

    const large_head = try std.fmt.allocPrint(allocator, "POST /large HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{large_body.len});
    defer allocator.free(large_head);

    // The first read holds a whole request plus half of the next one's head. The rest of
    // that head arrives later, followed by the large request's head and its body in parts.
    try raw_client.send(stream, "GET /first HTTP/1.1\r\nHost: localhost\r\n\r\nPOST /second HTTP/1.1\r\nHo");
    raw_client.sleep(50);
    try raw_client.send(stream, "st: localhost\r\nContent-Length: 3\r\n\r\nxyz");
    try raw_client.send(stream, large_head);
    try raw_client.send(stream, large_body[0..1000]);
    raw_client.sleep(50);
    try raw_client.send(stream, large_body[1000..]);

    const received = try raw_client.receiveAll(stream, allocator);
    defer allocator.free(received);

    const large_echo = try std.fmt.allocPrint(allocator, "/large:{s}", .{large_body});
    defer allocator.free(large_echo);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for ([_][]const u8{ "/first:", "/second:xyz", large_echo }) |body| {
        const response = try raw_client.okResponse(allocator, body);
        defer allocator.free(response);
        try expected.appendSlice(allocator, response);
    }
    try testing.expectEqualStrings(expected.items, received);
}

test "bytes sent after an inactivity timeout are ignored and the server keeps serving" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0, .timeout = 100 }, echoPathAndBody, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    {
        const stream = try raw_client.connect(port);
        defer stream.close(raw_client.io);

        // An incomplete head, then silence: the server times out and answers 408.
        try raw_client.send(stream, "GET /slow HTTP/1.1\r\nHost: loc");
        raw_client.sleep(150);
        // The rest of the request (and another one) arrives after the timeout. It must not
        // be parsed or answered. The server may already have closed the connection, in which
        // case the send fails; either way is fine.
        raw_client.send(stream, "alhost\r\n\r\nGET /late HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {};

        // Depending on timing the connection is closed cleanly or reset (the server closed
        // it with unread bytes); a reset may lose the 408 on the client side.
        const received = raw_client.receiveAll(stream, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(received);
        if (received.len > 0) {
            try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 408 "));
            try testing.expect(mem.indexOf(u8, received, "/late") == null);
            try testing.expect(mem.indexOf(u8, received, "200 OK") == null);
        }
    }

    // A new connection is served normally.
    {
        const stream = try raw_client.connect(port);
        defer stream.close(raw_client.io);
        try raw_client.send(stream, "GET /after HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        const received = try raw_client.receiveAll(stream, allocator);
        defer allocator.free(received);
        const expected = try raw_client.okResponse(allocator, "/after:");
        defer allocator.free(expected);
        try testing.expectEqualStrings(expected, received);
    }
}
