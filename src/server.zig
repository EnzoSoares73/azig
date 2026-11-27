/// Represents a HTTP server implementation using libuv
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const uv = @import("uv");
const Config = @import("config.zig").Config;
const GenericRequest = @import("http/request.zig").GenericRequest;
const Response = @import("http/response.zig").Response;
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
const errorToStatusCode = @import("http/http_error.zig").errorToStatusCode;
const HttpError = @import("http/http_error.zig").HttpError;
const toHttpError = @import("http/http_error.zig").toHttpError;
const GenericRouter = @import("router.zig").GenericRouter;

const sync = @import("pools/sync.zig");
const Libuv = @import("libuv_io.zig").Libuv;
const Task = @import("libuv_io.zig").Task;
const GenericWorker = @import("worker.zig").Worker;
const GenericAcceptor = @import("acceptor.zig").Acceptor;
const logger = std.log.scoped(.server);

/// Largest accepted request head (request line + headers). Larger heads get a 431.
const max_head_size: usize = suggested_buffer_size;
/// Read and write buffers whose capacity grew past this (a large request or response) are
/// freed once they are empty, so one big message does not pin memory for the whole connection.
const max_retained_buffer_size: usize = suggested_buffer_size;
/// How long a connection rejected mid-request keeps draining the client's input after the
/// error response was sent (see lingeringClose).
const linger_timeout_ms: u64 = 2000;

pub fn Server(comptime AppContext: type, comptime RequestContext: type) type {
    const Request = GenericRequest(RequestContext);

    // Requests are created and released on the loop's own context only (the handler task uses
    // a request, but never creates or destroys one).
    const RequestPool = std.heap.MemoryPool(Request);

    const Phase = enum {
        reading,
        processing,
        writing,
        draining,
        closing,
    };

    const AfterWrite = enum {
        /// Keep-alive
        read_next,
        close,
        linger,
    };

    // Which deadline a connection is waiting on (see armDeadline).
    const DeadlineKind = enum {
        none,
        // `Context.timeout`: inactivity while reading, or a handler taking too long.
        timeout,
        // `linger_timeout_ms`: how long a lingering close keeps draining input.
        linger,
    };

    const State = struct {
        context: *anyopaque,
        stream: [*c]uv.uv_stream_t,
        /// Bytes read from the connection that have not been consumed yet: the request being
        /// read or processed, possibly followed by the start of the next (pipelined) request.
        /// The parsed request points into this buffer. libuv reads straight into its spare
        /// capacity (see allocBuffer), and it is kept across keep-alive requests.
        read_buf: std.ArrayList(u8),
        phase: Phase,
        after_write: AfterWrite,
        /// Length of the current request's head; valid while `request` is set.
        head_len: usize,
        /// Total length (head + body) of the request being processed.
        request_len: usize,
        request: ?*Request,
        /// Set by the handler task in `process`, consumed in `afterProcess`.
        response: ?*Response,
        /// The handler task; non-null from dispatch until afterProcess, whatever the phase
        /// (a timed-out task keeps running until its next cancelation point).
        task: ?Task,
        /// Serialized response. It must not be touched while `write_in_flight`; afterwards it
        /// is cleared, keeping its capacity for the next response on this connection.
        write_buf: std.ArrayList(u8),
        /// True from uv_write until onWriteComplete. Not implied by the phase: a write can
        /// still be in flight once the connection is `.closing`.
        write_in_flight: bool,
        shutdown_req: uv.uv_shutdown_t,
        /// False once the stream's close callback has run.
        stream_open: bool,
        /// The deadline list the connection is in, if any (see armDeadline).
        deadline_kind: DeadlineKind,
        /// Loop time (uv_now) at which the deadline expires; valid unless `deadline_kind` is `.none`.
        deadline: u64,
        deadline_node: std.DoublyLinkedList.Node,
    };

    const StatePool = std.heap.MemoryPool(State);

    const Action = GenericAction(AppContext, RequestContext);

    const Router = GenericRouter(AppContext, RequestContext);

    //Application-wide context
    const Context = struct {
        allocator: mem.Allocator,
        request_allocator: *RequestPool,
        response_allocator: *ResponsePool,
        client_allocator: *ClientPool,
        write_req_allocator: *WriteReqPool,
        arena_allocator: *ArenaPool,
        state_allocator: *StatePool,
        map_allocator: *StringMapPool,
        app_context: *AppContext,
        routes: Router.Table,
        lio: *Libuv,
        timeout: u64,
        /// One timer drives every connection's deadline. Connections are kept in one list per
        /// duration: a connection is (re)armed by moving it to the end of its list, so each list
        /// stays sorted by deadline, re-arming is O(1) and never touches libuv, and the timer
        /// only needs to fire for the earliest head. See armDeadline and onDeadlineTimer.
        deadline_timer: uv.uv_timer_t,
        /// When `deadline_timer` is due (loop time), null if it is not running. It may be due
        /// before any deadline (the connection it was set for was disarmed): it then just
        /// reschedules itself.
        deadline_timer_due: ?u64,
        timeout_list: std.DoublyLinkedList,
        linger_list: std.DoublyLinkedList,
        max_payload_size: u64,
        allowed_methods: []const []const u8,
        /// Receives the byte sent with each connection over the worker's IPC channel.
        channel_buffer: [16]u8,
    };

    return struct {
        allocator: mem.Allocator,
        config: Config = .{},
        app_context: if (AppContext == void) void else *AppContext,
        routes: Router.Table,

        // Shutdown signalling. `stop()` may be called from any thread, so it never touches a
        // loop directly: it wakes each worker's loop thread through the worker's `stop_signal`
        // (uv_async_send is the only thread-safe libuv call). `mutex` guards the fields below and
        // every worker's `stop_signal`, so `stop()` can never send on a handle that is closing or
        // whose memory is gone.
        mutex: std.Io.Mutex = .init,
        stop_requested: bool = false,
        workers: []Worker = &.{},
        /// Only in acceptor mode, while it runs.
        acceptor: ?*Acceptor = null,
        /// The port actually bound while the server is listening
        bound_port: u16 = 0,

        const Self = @This();

        pub const StartError = error{
            LoopInitFailed,
            ServerInitFailed,
            InvalidListenAddress,
            BindFailed,
            ListenFailed,
            StopSignalInitFailed,
            InterruptSignalInitFailed,
            IoInitFailed,
            WorkerSpawnFailed,
            WorkerChannelFailed,
        };

        const WorkerError = StartError || mem.Allocator.Error;

        const internals = .{
            .Server = Self,
            .Context = Context,
            .Error = WorkerError,
            .initPools = initPools,
            .closeLoop = closeLoop,
            .uvCheck = uvCheck,
            .bindAndListen = bindAndListen,
            .usesReusePort = usesReusePort,
            .watchInterrupt = watchInterrupt,
            .logRoutes = logRoutes,
            .closeConnectionHandle = closeConnectionHandle,
            .acceptConnection = acceptConnection,
            .onConnection = onConnection,
            .isStopping = isStopping,
        };
        const Worker = GenericWorker(internals);
        const Acceptor = GenericAcceptor(internals, Worker);
        const Source = Worker.Source;

        const Mode = enum { single, reuse_port, acceptor };
        const Plan = struct { mode: Mode, workers: usize };

        /// Call `deinit` once the server is no longer used (after `start()` has returned).
        /// `router` is compiled into a lookup tree at comptime; invalid route trees fail to compile.
        pub fn init(allocator: mem.Allocator, comptime config: Config, comptime router: Router, app_context: if (AppContext == void) void else *AppContext) mem.Allocator.Error!Self {
            return Self{
                .allocator = allocator,
                .config = config,
                .app_context = app_context,
                .routes = Router.Compiled(router).table,
            };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        /// Runs the server (see `Config.num_workers`). Blocks until `stop()` is called (from any
        /// thread) and every open connection and in-flight request has been wound down.
        /// Returns an error if a loop cannot be set up or the address cannot be bound.
        pub fn start(self: *Self) WorkerError!void {
            const plan = planFor(self.config);
            if (plan.mode == .single) {
                logger.info("Starting server", .{});
            } else {
                logger.info("Starting server with {d} workers ({s})", .{ plan.workers, @tagName(plan.mode) });
            }

            const workers = try self.allocator.alloc(Worker, plan.workers);
            defer self.allocator.free(workers);
            for (workers, 0..) |*worker, index| worker.* = .{ .server = self, .index = index };

            {
                self.mutex.lockUncancelable(sync.io());
                defer self.mutex.unlock(sync.io());
                self.workers = workers;
            }
            defer {
                self.mutex.lockUncancelable(sync.io());
                self.workers = &.{};
                self.bound_port = 0;
                self.stop_requested = false;
                self.mutex.unlock(sync.io());
            }

            var acceptor: Acceptor = .{ .server = self, .workers = workers };
            const result = switch (plan.mode) {
                .single, .reuse_port => workers[0].run(.{ .listen = self.config.port }, if (plan.workers > 1) Worker.spawnOthers else null),
                .acceptor => acceptor.run(),
            };
            for (workers) |*worker| {
                if (worker.thread) |thread| thread.join();
            }
            try result;
            if (acceptor.start_error) |err| return err;
            for (workers) |*worker| {
                if (worker.start_error) |err| return err;
            }
            logger.info("Server stopped", .{});
        }

        fn isStopping(self: *Self) bool {
            self.mutex.lockUncancelable(sync.io());
            defer self.mutex.unlock(sync.io());
            return self.stop_requested;
        }

        fn usesReusePort(config: Config) bool {
            return config.reuse_port and builtin.os.tag == .linux;
        }

        // How the server will work based on config
        fn planFor(config: Config) Plan {
            const count: usize = config.num_workers orelse std.Thread.getCpuCount() catch |err| blk: {
                logger.warn("Failed to get the CPU count, running a single worker: {}", .{err});
                break :blk 1;
            };
            if (count == 0) return .{ .mode = .single, .workers = 1 };
            if (usesReusePort(config)) return .{ .mode = .reuse_port, .workers = count };
            if (count == 1) return .{ .mode = .single, .workers = 1 };
            return .{ .mode = .acceptor, .workers = count };
        }

        /// Binds `server` and starts listening; returns the bound port (resolves port 0).
        fn bindAndListen(allocator: mem.Allocator, config: Config, server: *uv.uv_tcp_t, port: u16, reuse_port: bool, on_connection: uv.uv_connection_cb) WorkerError!u16 {
            // libuv expects a null-terminated string; the configured address is a plain slice.
            const listen_address = try allocator.dupeSentinel(u8, config.listen_address, 0);
            defer allocator.free(listen_address);

            var addr: uv.struct_sockaddr_in = undefined;
            try uvCheck(uv.uv_ip4_addr(listen_address.ptr, @intCast(port), &addr), "parse the listen address", error.InvalidListenAddress);
            // Some platforms only report errors such as EADDRINUSE from uv_listen, so both are checked.
            const flags: c_uint = if (reuse_port) uv.UV_TCP_REUSEPORT else 0;
            try uvCheck(uv.uv_tcp_bind(server, @ptrCast(&addr), flags), "bind the server", error.BindFailed);
            try uvCheck(uv.uv_listen(@ptrCast(server), config.backlog_size, on_connection), "listen", error.ListenFailed);

            var bound_addr: uv.struct_sockaddr_in = undefined;
            var bound_len: c_int = @sizeOf(uv.struct_sockaddr_in);
            if (uv.uv_tcp_getsockname(server, @ptrCast(&bound_addr), &bound_len) == 0) {
                return mem.bigToNative(u16, bound_addr.sin_port);
            }
            return port;
        }

        /// libuv turns SIGINT (a console Ctrl+C event on Windows) into a regular callback on the
        /// loop. One-shot: a second Ctrl+C gets the default behaviour and terminates the process.
        fn watchInterrupt(self: *Self, loop: *uv.uv_loop_t, signal: *uv.uv_signal_t) StartError!void {
            try uvCheck(uv.uv_signal_init(loop, signal), "initialize the interrupt signal", error.InterruptSignalInitFailed);
            signal.data = self;
            try uvCheck(uv.uv_signal_start_oneshot(signal, onInterrupt, uv.SIGINT), "watch for interrupts", error.InterruptSignalInitFailed);
        }

        /// The port the server is listening on, or null if it is not (yet) ready to serve.
        /// Safe to call from any thread.
        pub fn listeningPort(self: *Self) ?u16 {
            self.mutex.lockUncancelable(sync.io());
            defer self.mutex.unlock(sync.io());
            if (self.workers.len == 0) return null;
            for (self.workers) |*worker| {
                if (worker.stop_signal == null) return null;
            }
            if (self.acceptor) |acceptor| {
                if (!acceptor.ready) return null;
            }
            return self.bound_port;
        }

        /// Asks the server to shut down. Safe to call from any thread, and before or while
        /// `start()` is running. Returns immediately; `start()` returns once shutdown is complete.
        pub fn stop(self: *Self) void {
            self.mutex.lockUncancelable(sync.io());
            defer self.mutex.unlock(sync.io());

            self.stop_requested = true;
            if (self.acceptor) |acceptor| {
                if (acceptor.stop_signal) |signal| _ = uv.uv_async_send(signal);
            }
            for (self.workers) |*worker| {
                if (worker.stop_signal) |signal| _ = uv.uv_async_send(signal);
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

        // Runs when the process receives SIGINT (Ctrl+C).
        fn onInterrupt(handle: [*c]uv.uv_signal_t, _: c_int) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(handle.*.data));
            logger.info("Interrupt received", .{});
            self.stop();
        }

        fn closeConnectionHandle(handle: [*c]uv.uv_handle_t, _: ?*anyopaque) callconv(.c) void {
            if (uv.uv_is_closing(handle) != 0) return;

            // The listener and the stop signal are already closing, so every remaining TCP
            // handle is a client connection.
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
            }
        }

        // - Reading is started only in `.reading` and `.draining`. While processing it is stopped,
        //   so the handler task has exclusive access to the request and its buffer.
        // - `state.after_write` decides where `.writing` goes; it is set when the request is parsed
        //   (keep-alive or not) or when an error response is sent.
        // - The serialized response is in `state.write_buf`, which must not be touched while
        //   `state.write_in_flight`.
        // - A connection owns one libuv handle, the TCP stream. It must be closed, and no work or
        //   write may be pending, before the state can be returned to the pool. Its timeouts are
        //   entries in the server's deadline lists (see armDeadline), not handles of their own.
        fn onConnection(server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            if (status < 0) return;
            _ = acceptConnection(@ptrCast(@alignCast(server.*.data)), server);
        }

        /// Accepts a connection from `source`: a listener, or a worker's channel with a pending
        /// handle. Returns false if nothing could be accepted.
        fn acceptConnection(ctx: *Context, source: [*c]uv.uv_stream_t) bool {
            const client_pool = ctx.client_allocator;
            const state_pool = ctx.state_allocator;

            const client = client_pool.create(ctx.allocator) catch {
                logger.err("Failed to allocate client", .{});
                return false;
            };

            const state = state_pool.create(ctx.allocator) catch {
                logger.err("Failed to allocate state", .{});
                client_pool.destroy(client);
                return false;
            };

            const stream: [*c]uv.uv_stream_t = @ptrCast(client);

            state.* = .{
                .context = @ptrCast(@alignCast(ctx)),
                .stream = stream,
                .read_buf = .empty,
                .phase = .reading,
                .after_write = .close,
                .head_len = 0,
                .request_len = 0,
                .request = null,
                .response = null,
                .task = null,
                .write_buf = .empty,
                .write_in_flight = false,
                .shutdown_req = undefined,
                .stream_open = false,
                .deadline_kind = .none,
                .deadline = 0,
                .deadline_node = .{},
            };

            if (uv.uv_tcp_init(source.*.loop, client) != 0) {
                logger.err("Failed to initialize client handle", .{});
                state_pool.destroy(state);
                client_pool.destroy(client);
                return false;
            }
            client.*.data = state;
            state.stream_open = true;

            if (uv.uv_accept(source, stream) == 0) {
                logger.debug("Connection accepted", .{});
                // Responses are written in one go, so there is nothing to gain from Nagle's algorithm.
                _ = uv.uv_tcp_nodelay(client, 1);
                armDeadline(state, .timeout);
                startReading(state);
            } else {
                logger.debug("Connection refused", .{});
                closeConnection(state);
            }
            return true;
        }

        /// Only called in `.reading` and `.draining`.
        fn startReading(state: *State) void {
            std.debug.assert(state.*.phase == .reading or state.*.phase == .draining);
            _ = uv.uv_read_start(state.*.stream, allocBuffer, onRead);
        }

        fn stopReading(state: *State) void {
            _ = uv.uv_read_stop(state.*.stream);
        }

        /// Serializes the response into the connection's write buffer and starts writing it.
        /// The response itself can be destroyed as soon as this returns.
        fn sendResponse(state: *State, response: *Response) void {
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));
            const allocator = ctx.*.allocator;
            const write_req_pool = ctx.*.write_req_allocator;

            std.debug.assert(!state.*.write_in_flight);

            response.*.serializeInto(allocator, &state.*.write_buf) catch |err| {
                // E.g. a handler set a header containing CR/LF. Send a plain 500 instead, without
                // the headers: the invalid one would make serialization fail again.
                logger.err("Failed to serialize response: {}", .{err});
                response.*.headers.clearRetainingCapacity();
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
            state.*.write_in_flight = true;
            state.*.phase = .writing;
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

        /// Runs on the loop's own context once the handler task has finished.
        fn afterProcess(arg: *anyopaque) void {
            const state: *State = @ptrCast(@alignCast(arg));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            state.*.task = null;
            const response = state.*.response;
            state.*.response = null;

            // Any other phase means the response slot is no longer ours: the handler timed out
            // and a 408 was sent instead (`.writing`), or the connection is `.closing`.
            if (state.*.phase == .processing) {
                // No timeouts while the response is being written; onWriteComplete
                // re-arms the deadline for keep-alive connections.
                disarmDeadline(state);
                if (response) |r| {
                    // A HEAD response carries the headers (including Content-Length) of the
                    // equivalent GET response, but never a body.
                    if (mem.eql(u8, state.*.request.?.method, "HEAD")) {
                        r.*.send_body = false;
                    }
                    sendResponse(state, r);
                } else {
                    setResponseAndSend(state, 500, .close);
                }
            }

            // The response has been serialized into its own buffer, so the request,
            // the response and the response arena can all be released now.
            if (response) |r| destroyResponse(ctx, r);
            releaseRequest(state);
            consumeRequestBytes(state);

            if (state.*.phase == .closing) {
                tryFreeState(state);
            }
        }

        /// The handler task. Runs as a fiber on the loop thread, so it can wait (through the Io
        /// it passes to the handler) without blocking the loop.
        fn process(arg: *anyopaque) void {
            const state: *State = @ptrCast(@alignCast(arg));
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

        fn logRoutes(allocator: mem.Allocator, list: []const Router.RouteInfo) void {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            formatRoutes(allocator, &buf, list) catch {
                logger.warn("Could not list the routes: out of memory", .{});
                return;
            };
            logger.info("{s}", .{buf.items});
        }

        fn formatRoutes(allocator: mem.Allocator, buf: *std.ArrayList(u8), list: []const Router.RouteInfo) !void {
            try buf.appendSlice(allocator, "\n\tRoutes:");
            for (list) |route| {
                const method = if (route.method) |m| @tagName(m) else "ANY";
                try buf.print(allocator, "\n\t\t{s: <7} {s}", .{ method, route.path });
            }
        }

        fn handleCallback(ctx: *Context, request: *Request, response: *Response) void {
            const routes = ctx.*.routes;
            const method = std.meta.stringToEnum(std.http.Method, request.*.method);
            var action: Action = .{
                .io = ctx.*.lio.io(),
                .app_context = ctx.*.app_context,
                .index = 0,
                .middleware_list = undefined,
                .request = request,
                .response = response,
                .callback = undefined,
            };
            var allow: []const u8 = "";

            if (routes.match(method, request.*.path, &request.*.path_params)) |entry| {
                action.middleware_list = entry.middlewares;
                action.callback = entry.handler.callback;
                action.allow = entry.allow;
            } else |err| {
                // The middlewares still run
                const miss = routes.miss(request.*.path);
                action.middleware_list = miss.middlewares;
                action.allow = miss.allow;
                action.callback = Router.failWith(err);
                if (err == error.MethodNotAllowed) allow = miss.allow;
            }

            action.next() catch |err| {
                const http_error = toHttpError(err, HttpError.InternalServerError);
                const code = errorToStatusCode(http_error);
                response.*.setResponseError(code);
                if (code == 405 and allow.len > 0) {
                    response.*.addHeader("Allow", allow) catch response.*.setResponseError(500);
                }
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

            // Only `.reading` keeps the bytes. During a lingering close (`.draining`) they are
            // dropped: they were read into the spare capacity, which is simply reused, and the
            // linger deadline is left alone. In every other phase reading is stopped, and libuv
            // (1.53, on Unix and Windows) calls allocBuffer and onRead back to back and never
            // reports a read after uv_read_stop. Should that ever change, such bytes are dropped
            // too rather than appended to a buffer that may have been cleared.
            if (nread > 0 and state.*.phase != .reading) {
                return;
            }

            if (nread < 0) {
                switch (nread) {
                    // There is no more data to be read
                    uv.UV_EOF => {},
                    else => {
                        // A client that gives up on a rejected request may reset the connection.
                        if (state.*.phase == .draining) {
                            logger.debug("Read error while draining: {s}", .{uv.uv_strerror(@intCast(nread))});
                        } else {
                            logger.err("Read error: {s}", .{uv.uv_strerror(@intCast(nread))});
                        }
                    },
                }
                closeConnection(state);
                return;
            }

            armDeadline(state, .timeout);

            // libuv read straight into read_buf's spare capacity (see allocBuffer).
            const new_read: usize = @intCast(nread);
            std.debug.assert(buf.*.base == state.*.read_buf.unusedCapacitySlice().ptr);
            std.debug.assert(new_read <= state.*.read_buf.unusedCapacitySlice().len);
            state.*.read_buf.items.len += new_read;

            _ = tryDispatch(state);
        }

        const DispatchResult = enum {
            /// A complete request was handed to a handler task.
            dispatched,
            /// The buffered bytes don't hold a complete request yet.
            need_more,
            /// The request was rejected (an error response is being sent) or the connection closed.
            failed,
        };

        /// Looks at the buffered bytes and, once they hold a complete request, parses it and
        /// starts a handler task for it. Bytes after the request (a pipelined request) stay in
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

                state.*.after_write = if (request.isKeepAlive()) .read_next else .close;

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

            // The handler task now owns the request: stop reading so no new data can touch it
            // (reading restarts once the response has been written, see onWriteComplete).
            // The deadline is re-armed to give the handler the full timeout: if it takes longer,
            // the client gets a 408 and the task is canceled (see onTimeout).
            stopReading(state);

            state.*.task = ctx.*.lio.spawnDetached(process, afterProcess, state) catch {
                logger.err("Failed to start a handler task", .{});
                discardRequest(state);
                setResponseAndSend(state, 503, .close);
                return .failed;
            };
            state.*.phase = .processing;
            armDeadline(state, .timeout);

            // Run the handler now rather than in the loop's next idle phase: deferring it costs a
            // whole loop iteration per request, which under load cut throughput by about 25%.
            // The handler may finish here, and afterProcess may free `state` (if the connection is
            // closing), so `state` must not be touched after this; callers return right away.
            ctx.*.lio.drain();
            return .dispatched;
        }

        fn onWriteComplete(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(req.*.handle.*.data));
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            ctx.*.write_req_allocator.destroy(req);

            state.*.write_in_flight = false;
            resetWriteBuf(state);

            if (state.*.phase == .closing) {
                tryFreeState(state);
                return;
            }

            if (status < 0) {
                logger.err("Write error: {s}", .{uv.uv_strerror(status)});
                closeConnection(state);
                return;
            }

            switch (state.*.after_write) {
                .close => {
                    closeConnection(state);
                    return;
                },
                .linger => {
                    lingeringClose(state);
                    return;
                },
                .read_next => {},
            }

            // A keep-alive response is only sent after the handler finished.
            std.debug.assert(state.*.task == null);
            state.*.phase = .reading;
            armDeadline(state, .timeout);

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

        /// Sends an error response; once it has been written, the connection is closed the way
        /// `after_write` says (`.close` or `.linger`).
        fn setResponseAndSend(state: *State, code: u16, after_write: AfterWrite) void {
            std.debug.assert(after_write != .read_next);
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            // No more timeouts: the connection is closed as soon as the write completes.
            disarmDeadline(state);
            state.*.after_write = after_write;

            const response = createResponse(ctx) catch |err| {
                logger.err("Error creating response: {}", .{err});
                closeConnection(state);
                return;
            };
            defer destroyResponse(ctx, response);

            response.*.setResponseError(code);
            sendResponse(state, response);
        }

        /// Rejects the request being read. The client may still be sending it (e.g. the body
        /// of a 413), so the connection is closed with lingeringClose once the response is out.
        fn handleErrorAndStopReading(state: *State, code: u16) void {
            stopReading(state);
            discardRequest(state);
            setResponseAndSend(state, code, .linger);
        }

        /// Closing a socket that still has unread input makes the OS send a RST, which can
        /// destroy the error response before the client reads it. Instead (RFC 9112 §9.6),
        /// half-close the connection, which sends a FIN once the response is out, and keep
        /// reading and discarding input until the client closes its side or linger_timeout_ms
        /// passes.
        fn lingeringClose(state: *State) void {
            state.*.phase = .draining;
            if (uv.uv_shutdown(&state.*.shutdown_req, state.*.stream, onShutdown) != 0) {
                closeConnection(state);
                return;
            }
            armDeadline(state, .linger);
            startReading(state);
        }

        fn onShutdown(_: [*c]uv.uv_shutdown_t, _: c_int) callconv(.c) void {
            // Nothing to do: the connection is closed on EOF, a read error or the linger deadline.
            // shutdown_req lives in State, which is freed only after the stream's close callback,
            // and libuv completes (or cancels) the shutdown before that.
        }

        fn listFor(ctx: *Context, kind: DeadlineKind) *std.DoublyLinkedList {
            return switch (kind) {
                .timeout => &ctx.*.timeout_list,
                .linger => &ctx.*.linger_list,
                .none => unreachable,
            };
        }

        /// Sets the connection's deadline to now + the kind's duration, replacing any
        /// previous one. Hot path (every read): two list operations, plus a libuv call only
        /// when the shared timer is idle or due later than this deadline.
        fn armDeadline(state: *State, kind: DeadlineKind) void {
            std.debug.assert(kind != .none);
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            disarmDeadline(state);

            const now = uv.uv_now(ctx.*.deadline_timer.loop);
            const duration = switch (kind) {
                .timeout => ctx.*.timeout,
                .linger => linger_timeout_ms,
                .none => unreachable,
            };
            state.*.deadline = now + duration;
            state.*.deadline_kind = kind;
            // Every entry of a list has the same duration and uv_now never goes back, so
            // appending keeps the list sorted by deadline.
            listFor(ctx, kind).append(&state.*.deadline_node);

            if (ctx.*.deadline_timer_due == null or state.*.deadline < ctx.*.deadline_timer_due.?) {
                scheduleDeadlineTimer(ctx, now, state.*.deadline);
            }
        }

        fn disarmDeadline(state: *State) void {
            if (state.*.deadline_kind == .none) return;
            const ctx: *Context = @ptrCast(@alignCast(state.*.context));

            listFor(ctx, state.*.deadline_kind).remove(&state.*.deadline_node);
            state.*.deadline_kind = .none;
            state.*.deadline_node = .{};

            // Don't let a timer with nothing to do keep the loop alive (e.g. during shutdown).
            if (ctx.*.timeout_list.first == null and ctx.*.linger_list.first == null and ctx.*.deadline_timer_due != null) {
                _ = uv.uv_timer_stop(&ctx.*.deadline_timer);
                ctx.*.deadline_timer_due = null;
            }
        }

        fn scheduleDeadlineTimer(ctx: *Context, now: u64, due: u64) void {
            ctx.*.deadline_timer_due = due;
            _ = uv.uv_timer_start(&ctx.*.deadline_timer, onDeadlineTimer, due -| now, 0);
        }

        fn onDeadlineTimer(timer: [*c]uv.uv_timer_t) callconv(.c) void {
            const ctx: *Context = @ptrCast(@alignCast(timer.*.data));
            ctx.*.deadline_timer_due = null;
            const now = uv.uv_now(timer.*.loop);

            expireDeadlines(ctx, .timeout, now);
            expireDeadlines(ctx, .linger, now);

            // The handlers above may have armed new deadlines (and scheduled the timer), but
            // never one earlier than the remaining heads.
            var next: ?u64 = null;
            for ([_]DeadlineKind{ .timeout, .linger }) |kind| {
                if (listFor(ctx, kind).first) |node| {
                    const state: *State = @fieldParentPtr("deadline_node", node);
                    if (next == null or state.*.deadline < next.?) next = state.*.deadline;
                }
            }
            if (next) |due| {
                if (ctx.*.deadline_timer_due != due) scheduleDeadlineTimer(ctx, now, due);
            } else if (ctx.*.deadline_timer_due != null) {
                _ = uv.uv_timer_stop(&ctx.*.deadline_timer);
                ctx.*.deadline_timer_due = null;
            }
        }

        fn expireDeadlines(ctx: *Context, kind: DeadlineKind, now: u64) void {
            const list = listFor(ctx, kind);
            while (list.first) |node| {
                const state: *State = @fieldParentPtr("deadline_node", node);
                if (state.*.deadline > now) break;
                // Removed before the handler runs: it may close the connection.
                disarmDeadline(state);
                switch (kind) {
                    .timeout => onTimeout(state),
                    .linger => closeConnection(state),
                    .none => unreachable,
                }
            }
        }

        // The timeout deadline is armed while the connection is reading and while a request is
        // being processed. It is disarmed while a response is being written, so it never races
        // with a pending write.
        fn onTimeout(state: *State) void {
            if (state.*.phase == .processing) {
                // The handler is taking too long. Answer 408 now, close the connection once it
                // is written, and cancel the handler: its next cancelation point (or the one it
                // is waiting in) returns error.Canceled. The task still owns the request, so it
                // is left alone: sending moves the phase to `.writing`, so afterProcess drops
                // the handler's response and only releases the request.
                logger.debug("Request handler exceeded the timeout", .{});
                const ctx: *Context = @ptrCast(@alignCast(state.*.context));
                ctx.*.lio.cancelTask(state.*.task.?);
                setResponseAndSend(state, 408, .close);
                return;
            }

            std.debug.assert(state.*.phase == .reading);
            logger.debug("Connection closing due to inactivity", .{});
            stopReading(state);
            discardRequest(state);
            setResponseAndSend(state, 408, .close);
        }

        /// Starts closing the connection's stream. The state is freed once its close callback
        /// has run and no handler task or write is pending.
        fn closeConnection(state: *State) void {
            if (state.*.phase == .closing) return;
            state.*.phase = .closing;

            // Nobody is left to receive the response: cancel the handler, if one is running.
            if (state.*.task) |task| {
                const ctx: *Context = @ptrCast(@alignCast(state.*.context));
                ctx.*.lio.cancelTask(task);
            }

            disarmDeadline(state);
            uv.uv_close(@ptrCast(@alignCast(state.*.stream)), onHandleClosed);
        }

        fn onHandleClosed(handle: [*c]uv.uv_handle_t) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(handle.*.data));
            state.*.stream_open = false;
            tryFreeState(state);
        }

        fn tryFreeState(state: *State) void {
            if (state.*.stream_open or state.*.task != null or state.*.write_in_flight) {
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
        fn onResponse(_: std.Io, _: *Request, _: *Response) !void {}
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var first = try TestServer.init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", onResponse)} }, {});
    defer first.deinit();
    const thread = try std.Thread.spawn(.{}, run, .{&first});
    defer {
        first.stop();
        thread.join();
    }

    const port = try waitUntilListening(&first);

    var second = try TestServer.init(allocator, .{}, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(_: std.Io, _: *Request, _: *Response) !void {}
    }.onResponse;

    var server = try TestServer.init(allocator, .{ .port = 2602 }, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(_: std.Io, request: *Request, response: *Response) !void {
            if (mem.eql(u8, request.path, "/")) {
                response.*.body = "Home Page";
                try response.*.addHeader("Content-Type", "text/plain");
            } else if (mem.eql(u8, request.path, "/error")) {
                return HttpError.InternalServerError;
            } else if (mem.eql(u8, request.path, "/bad-request")) {
                return HttpError.BadRequest;
            } else if (mem.eql(u8, request.path, "/timeout")) {
                response.*.setResponseError(408);
            } else if (mem.eql(u8, request.path, "/custom-status")) {
                response.*.status_code = 201;
                response.*.body = "Created";
            } else if (mem.eql(u8, request.path, "/chunked")) {
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

    var server = try TestServer.init(allocator, .{}, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(io: std.Io, _: *Request, _: *Response) !void {
            try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(200) }, io);
        }
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, Config{
        .timeout = 100,
    }, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(io: std.Io, _: *Request, _: *Response) !void {
            // Slightly longer than the 100 ms timeout: the 408 is sent while the handler is still
            // running, and the handler finishes right around the time that write completes and
            // the connection is closed, so afterProcess can run before the close callbacks.
            // The timeout cancels the handler, so the sleep is protected from cancelation to
            // keep it running until then.
            const old = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old);
            std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(110) }, io) catch unreachable;
        }
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    var server = try TestServer.init(allocator, Config{
        .timeout = 100,
    }, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(_: std.Io, _: *Request, _: *Response) !void {}
    }.onResponse;

    const run = struct {
        fn run(server_ptr: *TestServer) !void {
            try server_ptr.start();
        }
    }.run;

    const max_payload_size: u64 = comptime std.math.pow(u64, 2, 17);
    var server = try TestServer.init(allocator, Config{
        .max_payload_size = max_payload_size,
    }, .{ .handlers = &.{.any("", onResponse)} }, {});
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
        fn onResponse(_: std.Io, request: *Request, _: *Response) !void {
            try testing.expectEqual(request.context.counter, 3);
            request.context.counter = 4;
        }
    }.onResponse;

    const mid1 = struct {
        fn mid(_: std.Io, request: *Request, _: *Response, action: Action) !void {
            request.context.counter = 1;
            try action.next();
            try testing.expectEqual(request.context.counter, 6);
            request.context.counter = 7;
        }
    }.mid;

    const mid2 = struct {
        fn mid(_: std.Io, request: *Request, _: *Response, action: Action) !void {
            try testing.expectEqual(request.context.counter, 1);
            request.context.counter = 2;
            try action.next();
            try testing.expectEqual(request.context.counter, 5);
            request.context.counter = 6;
        }
    }.mid;

    const mid3 = struct {
        fn mid(_: std.Io, request: *Request, _: *Response, action: Action) !void {
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

    var server = try TestServer.init(allocator, Config{}, .{
        .middlewares = &.{ mid1, mid2, mid3 },
        .handlers = &.{.any("", onResponse)},
    }, {});
    defer server.deinit();
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
fn echoPathAndBody(_: std.Io, request: *GenericRequest(void), response: *Response) !void {
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "{s}:{s}", .{ request.path, request.body orelse "" });
}

fn runServer(server: *Server(void, void)) !void {
    try server.start();
}

test "pipelined requests sent in a single write are answered in order" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", echoPathAndBody)} }, {});
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

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", echoPathAndBody)} }, {});
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

    var server = try Server(void, void).init(allocator, .{ .port = 0, .timeout = 100 }, .{ .handlers = &.{.any("", echoPathAndBody)} }, {});
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

fn sleepMs(io: std.Io, ms: i64) std.Io.Cancelable!void {
    return std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io);
}

fn msSince(start: std.Io.Clock.Timestamp) i64 {
    return start.untilNow(raw_client.io).raw.toMilliseconds();
}

test "slow handlers do not stall the server" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const handler = struct {
        fn handler(io: std.Io, request: *GenericRequest(void), response: *Response) !void {
            // Stands in for a slow database query.
            if (mem.eql(u8, request.path, "/slow")) try sleepMs(io, 600);
            response.body = request.path;
        }
    }.handler;

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", handler)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    // Far more slow requests than libuv's thread pool (4 threads) used to handle at once.
    var slow_streams: [16]std.Io.net.Stream = undefined;
    for (&slow_streams) |*stream| {
        stream.* = try raw_client.connect(port);
        try raw_client.send(stream.*, "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    }
    defer for (slow_streams) |stream| stream.close(raw_client.io);
    raw_client.sleep(50);

    // A fast request is answered while every slow one is still waiting.
    {
        const start = std.Io.Clock.Timestamp.now(raw_client.io, .awake);
        const stream = try raw_client.connect(port);
        defer stream.close(raw_client.io);
        try raw_client.send(stream, "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        const received = try raw_client.receiveAll(stream, allocator);
        defer allocator.free(received);
        const expected = try raw_client.okResponse(allocator, "/fast");
        defer allocator.free(expected);
        try testing.expectEqualStrings(expected, received);
        try testing.expect(msSince(start) < 400);
    }

    // And the slow ones all complete, about together.
    const expected = try raw_client.okResponse(allocator, "/slow");
    defer allocator.free(expected);
    for (slow_streams) |stream| {
        const received = try raw_client.receiveAll(stream, allocator);
        defer allocator.free(received);
        try testing.expectEqualStrings(expected, received);
    }
}

test "handlers can run io.async tasks concurrently" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const handler = struct {
        fn slowValue(io: std.Io, value: u32) std.Io.Cancelable!u32 {
            try sleepMs(io, 200);
            return value;
        }

        fn handler(io: std.Io, _: *GenericRequest(void), response: *Response) !void {
            var a = io.async(slowValue, .{ io, 1 });
            defer _ = a.cancel(io) catch {};
            var b = io.async(slowValue, .{ io, 2 });
            defer _ = b.cancel(io) catch {};
            const sum = try a.await(io) + try b.await(io);
            response.body = try std.fmt.allocPrint(response.arena.allocator(), "{d}", .{sum});
        }
    }.handler;

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", handler)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const start = std.Io.Clock.Timestamp.now(raw_client.io, .awake);
    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);
    try raw_client.send(stream, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const received = try raw_client.receiveAll(stream, allocator);
    defer allocator.free(received);
    const expected = try raw_client.okResponse(allocator, "3");
    defer allocator.free(expected);
    try testing.expectEqualStrings(expected, received);
    // The two 200 ms waits overlap.
    try testing.expect(msSince(start) < 380);
}

var timed_out_handler_canceled = std.atomic.Value(bool).init(false);

test "a handler that exceeds the timeout is canceled" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const handler = struct {
        fn handler(io: std.Io, _: *GenericRequest(void), _: *Response) !void {
            sleepMs(io, 60_000) catch |err| {
                timed_out_handler_canceled.store(true, .release);
                return err;
            };
        }
    }.handler;

    var server = try Server(void, void).init(allocator, .{ .port = 0, .timeout = 100 }, .{ .handlers = &.{.any("", handler)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);
    try raw_client.send(stream, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const received = try raw_client.receiveAll(stream, allocator);
    defer allocator.free(received);
    try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 408 "));

    var attempts: usize = 0;
    while (!timed_out_handler_canceled.load(.acquire) and attempts < 100) : (attempts += 1) raw_client.sleep(10);
    try testing.expect(timed_out_handler_canceled.load(.acquire));
}

test "stop cancels the handlers still running" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const handler = struct {
        fn handler(io: std.Io, _: *GenericRequest(void), _: *Response) !void {
            try sleepMs(io, 60_000);
        }
    }.handler;

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", handler)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    const port = try waitUntilListening(&server);

    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);
    try raw_client.send(stream, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    raw_client.sleep(100);

    // Without cancelation, start() would only return once the 60 s handler had finished.
    const start = std.Io.Clock.Timestamp.now(raw_client.io, .awake);
    server.stop();
    thread.join();
    try testing.expect(msSince(start) < 2000);
}

/// A slow backend (think database) the handlers below query over TCP. It runs on its own
/// threads, outside the server.
const slow_backend = struct {
    var address: std.Io.net.IpAddress = undefined;

    fn run(server: *std.Io.net.Server, connections: usize) void {
        var threads: [16]?std.Thread = @splat(null);
        for (threads[0..connections]) |*thread| {
            const stream = server.accept(raw_client.io) catch break;
            thread.* = std.Thread.spawn(.{}, serve, .{stream}) catch {
                stream.close(raw_client.io);
                break;
            };
        }
        for (threads) |thread| if (thread) |t| t.join();
    }

    fn serve(stream: std.Io.net.Stream) void {
        defer stream.close(raw_client.io);
        var read_buffer: [64]u8 = undefined;
        var reader = stream.reader(raw_client.io, &read_buffer);
        const query = reader.interface.takeDelimiterExclusive('\n') catch return;
        raw_client.sleep(300);
        var write_buffer: [64]u8 = undefined;
        var writer = stream.writer(raw_client.io, &write_buffer);
        writer.interface.print("rows for {s}\n", .{query}) catch return;
        writer.interface.flush() catch return;
    }
};

test "handlers query a TCP backend concurrently through io" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const request_count = 8;
    var backend = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(raw_client.io, .{});
    defer backend.deinit(raw_client.io);
    slow_backend.address = backend.socket.address;
    const backend_thread = try std.Thread.spawn(.{}, slow_backend.run, .{ &backend, request_count });
    defer backend_thread.join();

    const handler = struct {
        fn handler(io: std.Io, request: *GenericRequest(void), response: *Response) !void {
            const stream = try slow_backend.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);
            var write_buffer: [64]u8 = undefined;
            var writer = stream.writer(io, &write_buffer);
            try writer.interface.print("{s}\n", .{request.path});
            try writer.interface.flush();
            var read_buffer: [64]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            const rows = try reader.interface.takeDelimiterExclusive('\n');
            response.body = try response.arena.allocator().dupe(u8, rows);
        }
    }.handler;

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, .{ .handlers = &.{.any("", handler)} }, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const start = std.Io.Clock.Timestamp.now(raw_client.io, .awake);
    var streams: [request_count]std.Io.net.Stream = undefined;
    for (&streams, 0..) |*stream, i| {
        stream.* = try raw_client.connect(port);
        var request_buffer: [128]u8 = undefined;
        try raw_client.send(stream.*, try std.fmt.bufPrint(&request_buffer, "GET /{d} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{i}));
    }
    defer for (streams) |stream| stream.close(raw_client.io);

    for (streams, 0..) |stream, i| {
        const received = try raw_client.receiveAll(stream, allocator);
        defer allocator.free(received);
        var body_buffer: [32]u8 = undefined;
        const expected = try raw_client.okResponse(allocator, try std.fmt.bufPrint(&body_buffer, "rows for /{d}", .{i}));
        defer allocator.free(expected);
        try testing.expectEqualStrings(expected, received);
    }
    // The eight 300 ms queries overlap.
    try testing.expect(msSince(start) < 1500);
}

fn routedUsers(_: std.Io, _: *GenericRequest(void), response: *Response) !void {
    response.body = "list";
}

fn routedCreate(_: std.Io, _: *GenericRequest(void), response: *Response) !void {
    response.status_code = 201;
    response.body = "created";
}

fn routedUser(_: std.Io, request: *GenericRequest(void), response: *Response) !void {
    response.body = try std.fmt.allocPrint(response.arena.allocator(), "user {s}", .{request.path_params.get("id").?});
}

const routed_router: GenericRouter(void, void) = .{ .handlers = &.{
    .get("/users", routedUsers),
    .post("/users", routedCreate),
    .get("/users/:id", routedUser),
} };

/// Sends one request on its own connection and returns everything the server answered.
fn routedRequest(allocator: mem.Allocator, port: u16, comptime request_line: []const u8) ![]u8 {
    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);
    try raw_client.send(stream, request_line ++ " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    return raw_client.receiveAll(stream, allocator);
}

test "routes are chosen by path and method" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0 }, routed_router, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    {
        const received = try routedRequest(allocator, port, "GET /users");
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(mem.endsWith(u8, received, "\r\n\r\nlist"));
    }
    {
        const received = try routedRequest(allocator, port, "POST /users");
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 201 Created\r\n"));
        try testing.expect(mem.endsWith(u8, received, "\r\n\r\ncreated"));
    }
    {
        const received = try routedRequest(allocator, port, "GET /users/42");
        defer allocator.free(received);
        try testing.expect(mem.endsWith(u8, received, "\r\n\r\nuser 42"));
    }
    {
        // HEAD is answered by the GET handler, without the body.
        const received = try routedRequest(allocator, port, "HEAD /users");
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 200 OK\r\n"));
        try testing.expect(mem.indexOf(u8, received, "Content-Length: 4\r\n") != null);
        try testing.expect(mem.endsWith(u8, received, "\r\n\r\n"));
    }
    {
        const received = try routedRequest(allocator, port, "DELETE /users");
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 405 Method Not Allowed\r\n"));
        try testing.expect(mem.indexOf(u8, received, "Allow: GET, HEAD, POST\r\n") != null);
    }
    {
        const received = try routedRequest(allocator, port, "GET /nope");
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 404 Not Found\r\n"));
    }
}

var guarded_requests = std.atomic.Value(u32).init(0);

fn countRequests(_: std.Io, _: *GenericRequest(void), response: *Response, action: GenericAction(void, void)) !void {
    _ = guarded_requests.fetchAdd(1, .monotonic);
    try response.addHeader("X-Seen", "1");
    try action.next();
}

fn requireUser(_: std.Io, request: *GenericRequest(void), _: *Response, action: GenericAction(void, void)) !void {
    if (request.getHeader("X-User") == null) return error.Unauthorized;
    try action.next();
}

const guarded_router: GenericRouter(void, void) = .{
    .middlewares = &.{countRequests},
    .routes = &.{.{
        .path = "/api",
        .middlewares = &.{requireUser},
        .handlers = &.{.get("/users", routedUsers)},
    }},
};

fn guardedRequest(allocator: mem.Allocator, port: u16, comptime request_line: []const u8, comptime headers: []const u8) ![]u8 {
    const stream = try raw_client.connect(port);
    defer stream.close(raw_client.io);
    try raw_client.send(stream, request_line ++ " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 0\r\n" ++ headers ++ "\r\n");
    return raw_client.receiveAll(stream, allocator);
}

test "404 and 405 run the middlewares of the routers the path is under" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    guarded_requests.store(0, .monotonic);
    var server = try Server(void, void).init(allocator, .{ .port = 0 }, guarded_router, {});
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.stop();
        thread.join();
    }
    const port = try waitUntilListening(&server);

    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // Outside "/api": only the root middleware runs.
        .{ "GET /nope", "", "HTTP/1.1 404 Not Found\r\n" },
        // Under "/api", its middleware rejects the request before the 404 / 405 is revealed.
        .{ "GET /api/nope", "", "HTTP/1.1 401 Unauthorized\r\n" },
        .{ "DELETE /api/users", "", "HTTP/1.1 401 Unauthorized\r\n" },
        .{ "GET /api/nope", "X-User: ana\r\n", "HTTP/1.1 404 Not Found\r\n" },
        .{ "DELETE /api/users", "X-User: ana\r\n", "HTTP/1.1 405 Method Not Allowed\r\n" },
        .{ "GET /api/users", "X-User: ana\r\n", "HTTP/1.1 200 OK\r\n" },
    };
    inline for (cases) |case| {
        const received = try guardedRequest(allocator, port, case[0], case[1]);
        defer allocator.free(received);
        testing.expect(mem.startsWith(u8, received, case[2])) catch |err| {
            std.debug.print("{s} ({s}) got:\n{s}\n", .{ case[0], case[1], received });
            return err;
        };
        // Headers set by middlewares survive error responses.
        try testing.expect(mem.indexOf(u8, received, "X-Seen: 1\r\n") != null);
        // Only the 405 the router produced carries Allow.
        const has_allow = mem.indexOf(u8, received, "Allow: GET, HEAD\r\n") != null;
        try testing.expectEqual(mem.startsWith(u8, case[2], "HTTP/1.1 405"), has_allow);
    }
    try testing.expectEqual(@as(u32, cases.len), guarded_requests.load(.monotonic));
}

test "routes are formatted as one message, without a trailing newline" {
    const Router = GenericRouter(void, void);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try Server(void, void).formatRoutes(testing.allocator, &buf, Router.Compiled(routed_router).list ++ &[_]Router.RouteInfo{
        .{ .method = null, .path = "/any" },
    });
    try testing.expectEqualStrings(
        "\n\tRoutes:\n\t\tGET     /users\n\t\tPOST    /users\n\t\tGET     /users/:id\n\t\tANY     /any",
        buf.items,
    );
}

/// App context shared by every worker: records which threads ran a handler.
const WorkerTestApp = struct {
    mutex: std.Io.Mutex = .init,
    thread_ids: [16]std.Thread.Id = undefined,
    thread_count: usize = 0,
    requests: std.atomic.Value(usize) = .init(0),

    fn handle(app: *WorkerTestApp, _: std.Io, _: *GenericRequest(void), _: *Response) !void {
        _ = app.requests.fetchAdd(1, .monotonic);
        const id = std.Thread.getCurrentId();
        // Handlers of different workers contend here, so the lock must block the thread (see
        // `Config.num_workers`), not the task.
        app.mutex.lockUncancelable(sync.io());
        defer app.mutex.unlock(sync.io());
        for (app.thread_ids[0..app.thread_count]) |known| {
            if (known == id) return;
        }
        if (app.thread_count < app.thread_ids.len) {
            app.thread_ids[app.thread_count] = id;
            app.thread_count += 1;
        }
    }

    fn runServer(server: *Server(WorkerTestApp, void)) !void {
        try server.start();
    }
};

test "reuse_port mode spreads connections across workers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The kernel picks a listener by hashing each connection: 64 all landing on one of 4
    // workers is vanishingly unlikely.
    try expectSpreadAcrossWorkers(.{ .port = 0, .reuse_port = true, .num_workers = 4 });
}

test "stop called before start makes start return with several workers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0, .reuse_port = true, .num_workers = 3 }, .{ .handlers = &.{.any("", echoPathAndBody)} }, {});
    defer server.deinit();
    server.stop();
    // Would block forever if any worker missed the early stop request.
    try server.start();
}

test "num_workers and reuse_port select the mode" {
    const TestServer = Server(void, void);
    const Plan = TestServer.Plan;
    try testing.expectEqual(Plan{ .mode = .single, .workers = 1 }, TestServer.planFor(.{ .num_workers = 0 }));
    try testing.expectEqual(Plan{ .mode = .single, .workers = 1 }, TestServer.planFor(.{ .num_workers = 1 }));
    try testing.expectEqual(Plan{ .mode = .acceptor, .workers = 8 }, TestServer.planFor(.{ .num_workers = 8 }));
    try testing.expectEqual(Plan{ .mode = .single, .workers = 1 }, TestServer.planFor(.{ .reuse_port = true, .num_workers = 0 }));
    const cpus = try std.Thread.getCpuCount();
    if (builtin.os.tag == .linux) {
        try testing.expectEqual(Plan{ .mode = .reuse_port, .workers = 8 }, TestServer.planFor(.{ .reuse_port = true, .num_workers = 8 }));
        try testing.expectEqual(cpus, TestServer.planFor(.{ .reuse_port = true }).workers);
    } else {
        try testing.expectEqual(Plan{ .mode = .acceptor, .workers = 8 }, TestServer.planFor(.{ .reuse_port = true, .num_workers = 8 }));
    }
}

fn expectSpreadAcrossWorkers(comptime config: Config) !void {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app: WorkerTestApp = .{};
    const TestServer = Server(WorkerTestApp, void);
    var server = try TestServer.init(allocator, config, .{ .handlers = &.{.any("", WorkerTestApp.handle)} }, &app);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, WorkerTestApp.runServer, .{&server});
    var stopped = false;
    defer if (!stopped) {
        server.stop();
        thread.join();
    };
    const port = try waitUntilListening(&server);

    const connection_count = 64;
    for (0..connection_count) |_| {
        const stream = try raw_client.connect(port);
        defer stream.close(raw_client.io);
        try raw_client.send(stream, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        const received = try raw_client.receiveAll(stream, allocator);
        defer allocator.free(received);
        try testing.expect(mem.startsWith(u8, received, "HTTP/1.1 200 OK"));
    }

    try testing.expectEqual(@as(usize, connection_count), app.requests.load(.monotonic));
    try testing.expect(app.thread_count >= 2);

    server.stop();
    thread.join();
    stopped = true;
    try testing.expectEqual(@as(?u16, null), server.listeningPort());
}

test "acceptor mode hands connections to every worker" {
    try expectSpreadAcrossWorkers(.{ .port = 0, .num_workers = 4 });
}

test "stop called before start makes start return in acceptor mode" {
    var gpa = std.heap.DebugAllocator(.{ .thread_safe = true }).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try Server(void, void).init(allocator, .{ .port = 0, .num_workers = 3 }, .{ .handlers = &.{.any("", echoPathAndBody)} }, {});
    defer server.deinit();
    server.stop();
    try server.start();
}
