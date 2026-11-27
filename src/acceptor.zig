const std = @import("std");
const builtin = @import("builtin");
const uv = @import("uv");
const sync = @import("pools/sync.zig");
const logger = std.log.scoped(.server);

/// The cross-platform fallback: accepts every connection on the thread that called
/// `start()` and hands it to the workers in turn over IPC pipes.
pub fn Acceptor(comptime internals: anytype, comptime Worker: type) type {
    const Server = internals.Server;
    return struct {
        const Self = @This();

        server: *Server,
        workers: []Worker,
        loop: uv.uv_loop_t = undefined,
        listener: uv.uv_tcp_t = undefined,
        pipe_server: uv.uv_pipe_t = undefined,
        channels: []uv.uv_pipe_t = &.{},
        connected: usize = 0,
        next: usize = 0,
        /// Connections reported before any worker was connected.
        waiting: usize = 0,
        transfers: TransferPool = .empty,
        interrupt_signal: uv.uv_signal_t = undefined,
        discard_buffer: [16]u8 = undefined,
        start_error: ?internals.Error = null,
        /// Guarded by `server.mutex`.
        stop_signal: ?*uv.uv_async_t = null,
        /// Guarded by `server.mutex`. Set once every worker is connected.
        ready: bool = false,

        const Transfer = struct { tcp: uv.uv_tcp_t, req: uv.uv_write_t };
        const TransferPool = std.heap.MemoryPool(Transfer);

        pub fn run(acceptor: *Self) internals.Error!void {
            const self = acceptor.server;
            const allocator = self.allocator;
            const config = self.config;

            acceptor.channels = try allocator.alloc(uv.uv_pipe_t, acceptor.workers.len);
            defer allocator.free(acceptor.channels);
            defer acceptor.transfers.deinit(allocator);

            const loop = &acceptor.loop;
            try internals.uvCheck(uv.uv_loop_init(loop), "initialize the event loop", error.LoopInitFailed);
            defer internals.closeLoop(loop);

            try internals.uvCheck(uv.uv_tcp_init(loop, &acceptor.listener), "initialize the server handle", error.ServerInitFailed);
            acceptor.listener.data = acceptor;
            const bound_port = try internals.bindAndListen(allocator, config, &acceptor.listener, config.port, false, onClientConnection);

            var name_buffer: [256]u8 = undefined;
            const name = try pipeName(&name_buffer);
            try internals.uvCheck(uv.uv_pipe_init(loop, &acceptor.pipe_server, 0), "initialize the worker channel", error.WorkerChannelFailed);
            acceptor.pipe_server.data = acceptor;
            uv.uv_pipe_pending_instances(&acceptor.pipe_server, @intCast(acceptor.workers.len));
            try internals.uvCheck(uv.uv_pipe_bind2(&acceptor.pipe_server, name.ptr, name.len, uv.UV_PIPE_NO_TRUNCATE), "bind the worker channel", error.WorkerChannelFailed);
            try internals.uvCheck(uv.uv_listen(@ptrCast(&acceptor.pipe_server), @intCast(acceptor.workers.len), onWorkerConnected), "listen for workers", error.WorkerChannelFailed);

            var stop_signal: uv.uv_async_t = undefined;
            try internals.uvCheck(uv.uv_async_init(loop, &stop_signal, onStopSignal), "initialize the stop signal", error.StopSignalInitFailed);
            stop_signal.data = acceptor;
            try internals.watchInterrupt(self, loop, &acceptor.interrupt_signal);

            {
                self.mutex.lockUncancelable(sync.io());
                defer self.mutex.unlock(sync.io());
                self.acceptor = acceptor;
                acceptor.stop_signal = &stop_signal;
                self.bound_port = bound_port;
                if (self.stop_requested) _ = uv.uv_async_send(&stop_signal);
            }
            defer {
                self.mutex.lockUncancelable(sync.io());
                self.acceptor = null;
                acceptor.stop_signal = null;
                acceptor.ready = false;
                self.mutex.unlock(sync.io());
            }

            for (acceptor.workers) |*worker| {
                worker.thread = std.Thread.spawn(.{}, Worker.threadMain, .{ worker, Worker.Source{ .channel = name } }) catch |err| {
                    logger.warn("Failed to spawn a worker thread: {}", .{err});
                    acceptor.start_error = error.WorkerSpawnFailed;
                    self.stop();
                    break;
                };
            }
            _ = uv.uv_run(loop, uv.UV_RUN_DEFAULT);
        }

        fn onWorkerConnected(pipe_server: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            const acceptor: *Self = @ptrCast(@alignCast(pipe_server.*.data));
            const self = acceptor.server;
            if (status < 0 or acceptor.connected == acceptor.channels.len) return;

            const channel = &acceptor.channels[acceptor.connected];
            if (uv.uv_pipe_init(&acceptor.loop, channel, 1) != 0) return acceptor.fail();
            channel.data = acceptor;
            if (uv.uv_accept(pipe_server, @ptrCast(channel)) != 0) {
                uv.uv_close(@ptrCast(channel), null);
                return acceptor.fail();
            }
            acceptor.connected += 1;
            _ = uv.uv_read_start(@ptrCast(channel), allocDiscardBuffer, onWorkerChannelRead);

            while (acceptor.waiting > 0) : (acceptor.waiting -= 1) acceptor.dispatch();

            if (acceptor.connected == acceptor.channels.len) {
                // Also removes the pipe's file on Unix.
                uv.uv_close(@ptrCast(pipe_server), null);
                self.mutex.lockUncancelable(sync.io());
                acceptor.ready = true;
                self.mutex.unlock(sync.io());
                logger.info("Server listening on {s}:{d} with {d} workers", .{ self.config.listen_address, self.bound_port, acceptor.channels.len });
                internals.logRoutes(self.allocator, self.routes.list);
            }
        }

        fn fail(acceptor: *Self) void {
            logger.warn("Failed to connect a worker", .{});
            acceptor.start_error = error.WorkerChannelFailed;
            acceptor.server.stop();
        }

        fn onClientConnection(listener: [*c]uv.uv_stream_t, status: c_int) callconv(.c) void {
            if (status < 0) return;
            const acceptor: *Self = @ptrCast(@alignCast(listener.*.data));
            if (acceptor.connected == 0) {
                acceptor.waiting += 1;
                return;
            }
            acceptor.dispatch();
        }

        fn dispatch(acceptor: *Self) void {
            const transfer = acceptor.transfers.create(acceptor.server.allocator) catch {
                logger.err("Failed to allocate a connection transfer", .{});
                return;
            };
            if (uv.uv_tcp_init(&acceptor.loop, &transfer.tcp) != 0) {
                acceptor.transfers.destroy(transfer);
                return;
            }
            transfer.tcp.data = acceptor;
            if (uv.uv_accept(@ptrCast(&acceptor.listener), @ptrCast(&transfer.tcp)) != 0) {
                uv.uv_close(@ptrCast(&transfer.tcp), onTransferClosed);
                return;
            }

            const channel = &acceptor.channels[acceptor.next % acceptor.connected];
            acceptor.next +%= 1;
            const buf = uv.uv_buf_init(@constCast("."), 1);
            transfer.req.data = transfer;
            if (uv.uv_write2(&transfer.req, @ptrCast(channel), &buf, 1, @ptrCast(&transfer.tcp), onTransferWritten) != 0) {
                uv.uv_close(@ptrCast(&transfer.tcp), onTransferClosed);
            }
        }

        fn onTransferWritten(req: [*c]uv.uv_write_t, status: c_int) callconv(.c) void {
            const transfer: *Transfer = @ptrCast(@alignCast(req.*.data));
            if (status < 0 and status != uv.UV_ECANCELED) {
                logger.debug("Failed to hand a connection to a worker: {s}", .{uv.uv_strerror(status)});
            }
            uv.uv_close(@ptrCast(&transfer.tcp), onTransferClosed);
        }

        fn onTransferClosed(handle: [*c]uv.uv_handle_t) callconv(.c) void {
            const acceptor: *Self = @ptrCast(@alignCast(handle.*.data));
            const transfer: *Transfer = @fieldParentPtr("tcp", @as(*uv.uv_tcp_t, @ptrCast(handle)));
            acceptor.transfers.destroy(transfer);
        }

        fn allocDiscardBuffer(handle: [*c]uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
            const acceptor: *Self = @ptrCast(@alignCast(handle.*.data));
            buf.* = uv.uv_buf_init(&acceptor.discard_buffer, acceptor.discard_buffer.len);
        }

        fn onWorkerChannelRead(stream: [*c]uv.uv_stream_t, nread: isize, _: [*c]const uv.uv_buf_t) callconv(.c) void {
            if (nread < 0) _ = uv.uv_read_stop(stream);
        }

        fn onStopSignal(handle: [*c]uv.uv_async_t) callconv(.c) void {
            const acceptor: *Self = @ptrCast(@alignCast(handle.*.data));
            const self = acceptor.server;
            {
                self.mutex.lockUncancelable(sync.io());
                defer self.mutex.unlock(sync.io());
                acceptor.stop_signal = null;
                acceptor.ready = false;
            }
            uv.uv_close(@ptrCast(handle), null);
            uv.uv_close(@ptrCast(&acceptor.listener), null);
            closeIfOpen(@ptrCast(&acceptor.pipe_server));
            closeIfOpen(@ptrCast(&acceptor.interrupt_signal));
            // Cancels their pending transfers, whose callbacks then close them.
            for (acceptor.channels[0..acceptor.connected]) |*channel| closeIfOpen(@ptrCast(channel));
            logger.info("Server stopping", .{});
        }

        fn pipeName(buffer: []u8) internals.Error![:0]const u8 {
            const pid = uv.uv_os_getpid();
            const stamp = uv.uv_hrtime();
            if (builtin.os.tag == .windows) {
                return std.fmt.bufPrintSentinel(buffer, "\\\\.\\pipe\\azig-{d}-{x}", .{ pid, stamp }, 0) catch error.WorkerChannelFailed;
            }
            var dir_buffer: [128]u8 = undefined;
            var dir_len: usize = dir_buffer.len;
            const dir: []const u8 = if (uv.uv_os_tmpdir(&dir_buffer, &dir_len) == 0 and dir_len < 64) dir_buffer[0..dir_len] else "/tmp";
            return std.fmt.bufPrintSentinel(buffer, "{s}/azig-{d}-{x}.sock", .{ dir, pid, stamp }, 0) catch error.WorkerChannelFailed;
        }

        fn closeIfOpen(handle: [*c]uv.uv_handle_t) void {
            if (uv.uv_is_closing(handle) == 0) uv.uv_close(handle, null);
        }
    };
}
