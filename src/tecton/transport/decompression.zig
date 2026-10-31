pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const NetworkHandler = scope.NetworkHandler;
        const DecompressWork = scope.DecompressWork;
        const WorkerBuffers = scope.WorkerBuffers;
        const threaded_tasks = scope.threaded_tasks;
        const Compression = scope.Compression;

        pub fn workerBuffersForCurrentThread(self: *NetworkHandler) ?*WorkerBuffers {
            if (self.worker_buffers.len == 0) return null;
            const index = threaded_tasks.currentWorkerIndex() orelse return &self.worker_buffers[0];
            if (index >= self.worker_buffers.len) return &self.worker_buffers[index % self.worker_buffers.len];
            return &self.worker_buffers[index];
        }

        pub fn decompressTask(ctx: *anyopaque) void {
            const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
            const framing: scope.Framing = if (work.conn.isCompressionReady()) .negotiated else .initial;
            work.decompressed = Compression.decompress(work.raw, work.handler.options, framing, work.allocator) catch |err| {
                std.log.warn("decompress failed: {}", .{err});
                _ = work.handler.decompress_failures.fetchAdd(1, .monotonic);
                work.allocator.free(work.raw);
                work.raw = &.{};
                return;
            };
            work.allocator.free(work.raw);
            work.raw = &.{};
        }

        pub fn ringDecompressTask(ctx: *anyopaque) void {
            const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));

            var decoded = false;
            if (workerBuffersForCurrentThread(work.handler)) |buffers| {
                if (buffers.claim(&work.handler.tasks.stop_requested)) |index| {
                    const arena_allocator = buffers.arenas[index].allocator();
                    const framing: scope.Framing = if (work.conn.isCompressionReady()) .negotiated else .initial;
                    if (Compression.decompressInto(work.raw, work.handler.options, framing, arena_allocator)) |result| {
                        work.arena_result = result;
                        work.arena_outstanding = buffers.outstandingCounter(index);
                        _ = work.arena_outstanding.?.fetchAdd(1, .release);
                        decoded = true;
                    } else |err| {
                        std.log.warn("decompress failed: {}", .{err});
                    }
                }
            }

            if (!decoded) {
                const framing: scope.Framing = if (work.conn.isCompressionReady()) .negotiated else .initial;
                if (Compression.decompress(work.raw, work.handler.options, framing, work.allocator)) |result| {
                    work.decompressed = result;
                } else |err| {
                    std.log.warn("decompress failed: {}", .{err});
                    _ = work.handler.decompress_failures.fetchAdd(1, .monotonic);
                }
            }
        }

        pub fn decompressCallback(ctx: *anyopaque) void {
            const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
            const packets: ?[][]const u8 = if (work.arena_result) |result|
                result.packets
            else if (work.decompressed) |result|
                result.packets
            else
                null;

            if (packets) |entries| {
                if (work.conn.isOpen()) {
                    work.handler.host.dispatch(work.handler.host.ctx, work.conn, entries);
                }
            }
            releaseWork(work);
        }

        pub fn decompressCleanup(ctx: *anyopaque) void {
            const work = @as(*DecompressWork, @ptrCast(@alignCast(ctx)));
            releaseWork(work);
        }

        /// Frees everything the work item owns, including the connection reference the ring handed over.
        fn releaseWork(work: *DecompressWork) void {
            if (work.decompressed) |result| result.deinit();
            work.decompressed = null;

            if (work.raw_heap) |heap| {
                work.ring.?.ring.releaseOverflow(heap);
                work.raw_heap = null;
            }
            if (work.raw.len > 0 and work.raw_heap == null and work.ring == null) {
                work.allocator.free(work.raw);
                work.raw = &.{};
            }

            if (work.ring) |ring_slot| ring_slot.ring.release(ring_slot.slot);
            work.ring = null;
            if (work.arena_outstanding) |outstanding| {
                const previous = outstanding.fetchSub(1, .acq_rel);
                std.debug.assert(previous > 0);
            }
            work.arena_outstanding = null;

            const previous = work.handler.decompress_pending.fetchSub(1, .monotonic);
            std.debug.assert(previous > 0);
            work.conn.release();
            work.handler.decompress_pool.release(work);
        }
    };
}
