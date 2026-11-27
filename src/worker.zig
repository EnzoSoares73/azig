const std = @import("std");
const uv = @import("uv");
const sync = @import("pools/sync.zig");
const Libuv = @import("libuv_io.zig").Libuv;
const logger = std.log.scoped(.server);

/// One event loop with its own Io, pools and handles, on its own thread (the first
/// one in single and reuse_port modes runs on the thread that called `start()`).
pub fn Worker(comptime internals: anytype) type {
    const Server = internals.Server;
    return struct {
        const Self = @This();

        /// Where a worker gets its connections from.
        pub const Source = union(enum) {
            /// Its own listener on this port.
            listen: u16,
            /// The acceptor, over an IPC pipe with this name.
            channel: [:0]const u8,
        };

        server: *Server,
        index: usize,
        thread: ?std.Thread = null,
        /// Read only after the worker has finished.
        start_error: ?internals.Error = null,
        /// Guarded by `server.mutex`. Non-null while the worker runs.
        stop_signal: ?*uv.uv_async_t = null,
        listener: ?*uv.uv_tcp_t = null,
        channel: ?*uv.uv_pipe_t = null,
        interrupt_signal: ?*uv.uv_signal_t = null,

        const OnListening = *const fn (worker: *Self, bound_port: u16) void;

        pub fn run(worker: *Self, source: Source, on_listening: ?OnListening) internals.Error!void {
            const self = worker.server;
            const allocator = self.allocator;
            const config = self.config;
            const app_context = if (@TypeOf(self.app_context) == void) undefined else self.app_context;
            const routes = self.routes;

            const ctx: *internals.Context = try allocator.create(internals.Context);
            defer allocator.destroy(ctx);

            ctx.*.allocator = allocator;
            ctx.*.app_context = app_context;
            ctx.*.routes = routes;
            ctx.*.timeout = config.timeout;
            ctx.*.max_payload_size = config.max_payload_size;
            ctx.*.allowed_methods = config.allowed_methods;

            const cleanup = try internals.initPools(allocator, ctx, config.pool_size);
            defer cleanup(allocator, ctx);
            logger.debug("Pools allocated", .{});

            var loop: uv.uv_loop_t = undefined;
            try internals.uvCheck(uv.uv_loop_init(&loop), "initialize the event loop", error.LoopInitFailed);
            // Runs before the pools are cleaned up: closes whatever is still open (e.g. on a
            // bind error), lets every close callback and in-flight request finish, then
            // closes the loop.
            defer internals.closeLoop(&loop);

            // Closed by closeLoop like any other handle left open; it never keeps the loop
            // running by itself, since it is stopped whenever no connection has a deadline.
            try internals.uvCheck(uv.uv_timer_init(&loop, &ctx.*.deadline_timer), "initialize the deadline timer", error.LoopInitFailed);
            ctx.*.deadline_timer.data = ctx;
            ctx.*.deadline_timer_due = null;
            ctx.*.timeout_list = .{};
            ctx.*.linger_list = .{};

            // The Io the handlers run on. Its deinit runs before closeLoop (defers run in
            // reverse), once uv_run has returned, i.e. once every handler task has finished.
            var lio: Libuv = undefined;
            lio.init(allocator, &loop, .{ .stack_size = config.task_stack_size }) catch |err| {
                logger.warn("Failed to initialize the Io: {}", .{err});
                return error.IoInitFailed;
            };
            defer lio.deinit();
            ctx.*.lio = &lio;

            var server: uv.uv_tcp_t = undefined;
            var channel: uv.uv_pipe_t = undefined;
            var connect_req: uv.uv_connect_t = undefined;
            var bound_port: u16 = 0;
            switch (source) {
                .listen => |port| {
                    try internals.uvCheck(uv.uv_tcp_init(&loop, &server), "initialize the server handle", error.ServerInitFailed);
                    server.data = @constCast(ctx);
                    bound_port = try internals.bindAndListen(allocator, config, &server, port, internals.usesReusePort(config), internals.onConnection);
                    worker.listener = &server;
                },
                .channel => {
                    try internals.uvCheck(uv.uv_pipe_init(&loop, &channel, 1), "initialize the worker channel", error.WorkerChannelFailed);
                    channel.data = ctx;
                    worker.channel = &channel;
                },
            }

            var stop_signal: uv.uv_async_t = undefined;
            try internals.uvCheck(uv.uv_async_init(&loop, &stop_signal, onStopSignal), "initialize the stop signal", error.StopSignalInitFailed);
            stop_signal.data = worker;

            // One watcher is enough: stop() reaches every worker.
            const watches_interrupt = worker.index == 0 and source == .listen;
            var interrupt_signal: uv.uv_signal_t = undefined;
            if (watches_interrupt) {
                try internals.watchInterrupt(self, &loop, &interrupt_signal);
                worker.interrupt_signal = &interrupt_signal;
            }

            // Publish the stop signal. If stop() was already called (before the signal
            // existed), send it now so the loop shuts down as soon as it starts running.
            {
                self.mutex.lockUncancelable(sync.io());
                defer self.mutex.unlock(sync.io());
                worker.stop_signal = &stop_signal;
                if (watches_interrupt) self.bound_port = bound_port;
                if (self.stop_requested) {
                    _ = uv.uv_async_send(&stop_signal);
                }
            }
            defer {
                self.mutex.lockUncancelable(sync.io());
                worker.stop_signal = null;
                self.mutex.unlock(sync.io());
                worker.listener = null;
                worker.channel = null;
                worker.interrupt_signal = null;
            }

            switch (source) {
                .listen => if (watches_interrupt) {
                    logger.info("Server listening on {s}:{d}", .{ config.listen_address, bound_port });
                    internals.logRoutes(allocator, routes.list);
                },
                .channel => |name| {
                    connect_req.data = worker;
                    uv.uv_pipe_connect(&connect_req, &channel, name.ptr, onChannelConnected);
                },
            }
            if (on_listening) |callback| callback(worker, bound_port);
            _ = uv.uv_run(&loop, uv.UV_RUN_DEFAULT);
        }

        pub fn threadMain(worker: *Self, source: Source) void {
            worker.run(source, null) catch |err| worker.fail(err);
        }

        /// Takes the whole server down: it must not run short-handed.
        fn fail(worker: *Self, err: internals.Error) void {
            worker.start_error = err;
            worker.server.stop();
        }

        /// Starts the other reuse_port workers on the port the first one bound.
        pub fn spawnOthers(first: *Self, bound_port: u16) void {
            for (first.server.workers[1..]) |*worker| {
                worker.thread = std.Thread.spawn(.{}, threadMain, .{ worker, Source{ .listen = bound_port } }) catch |err| {
                    logger.warn("Failed to spawn a worker thread: {}", .{err});
                    return first.fail(error.WorkerSpawnFailed);
                };
            }
        }

        fn onChannelConnected(req: [*c]uv.uv_connect_t, status: c_int) callconv(.c) void {
            const worker: *Self = @ptrCast(@alignCast(req.*.data));
            if (status == uv.UV_ECANCELED or internals.isStopping(worker.server)) return;
            if (status < 0) {
                logger.warn("Failed to connect to the acceptor: {s}", .{uv.uv_strerror(status)});
                return worker.fail(error.WorkerChannelFailed);
            }
            _ = uv.uv_read_start(req.*.handle, allocChannelBuffer, onChannelRead);
        }

        /// The acceptor sends one byte with each connection handle.
        fn onChannelRead(stream: [*c]uv.uv_stream_t, nread: isize, _: [*c]const uv.uv_buf_t) callconv(.c) void {
            if (nread < 0) {
                _ = uv.uv_read_stop(stream);
                return;
            }
            const ctx: *internals.Context = @ptrCast(@alignCast(stream.*.data));
            const pipe: *uv.uv_pipe_t = @ptrCast(stream);
            while (uv.uv_pipe_pending_count(pipe) > 0) {
                if (!internals.acceptConnection(ctx, stream)) break;
            }
        }

        // Runs on a worker's loop thread when stop() is called. Stops accepting connections and
        // closes every open connection, which cancels the handlers still running. uv_run then
        // returns once all close callbacks have run and every handler task has finished
        // (afterProcess frees their state).
        fn onStopSignal(handle: [*c]uv.uv_async_t) callconv(.c) void {
            const worker: *Self = @ptrCast(@alignCast(handle.*.data));
            const self = worker.server;

            {
                self.mutex.lockUncancelable(sync.io());
                defer self.mutex.unlock(sync.io());
                // From now on stop() won't touch the handle, so it can be closed.
                worker.stop_signal = null;
            }
            uv.uv_close(@ptrCast(handle), null);

            if (worker.listener) |listener| uv.uv_close(@ptrCast(listener), null);
            if (worker.channel) |channel| {
                if (uv.uv_is_closing(@ptrCast(channel)) == 0) uv.uv_close(@ptrCast(channel), null);
            }
            // Closing it also restores the default SIGINT behaviour once no other server or
            // loop in the process watches it.
            if (worker.interrupt_signal) |interrupt_signal| {
                if (uv.uv_is_closing(@ptrCast(interrupt_signal)) == 0) uv.uv_close(@ptrCast(interrupt_signal), null);
            }

            uv.uv_walk(handle.*.loop, internals.closeConnectionHandle, null);
            if (worker.interrupt_signal != null) logger.info("Server stopping", .{});
        }

        fn allocChannelBuffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
            const ctx: *internals.Context = @ptrCast(@alignCast(handle.*.data));
            buf.* = uv.uv_buf_init(&ctx.channel_buffer, ctx.channel_buffer.len);
        }
    };
}
