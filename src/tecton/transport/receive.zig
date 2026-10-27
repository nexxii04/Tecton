const log = @import("../core/log.zig");
pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Connection = scope.Connection;
        const NetworkHandler = scope.NetworkHandler;
        const InboundRing = scope.InboundRing;
        const PacketDrainResult = scope.PacketDrainResult;
        const queue = scope.queue;
        const INPUT_DECOMPRESS_CAP = scope.INPUT_DECOMPRESS_CAP;

        pub fn drainRing(self: *NetworkHandler, ring: *InboundRing, budget_ns: u64, max_packets: usize) PacketDrainResult {
            const io = self.io;
            const started = std.Io.Timestamp.now(io, .awake);
            const cap = queue.drainCap(max_packets);

            var scanned: usize = 0;
            var enqueued: usize = 0;
            while (scanned < cap) {
                const elapsed: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).nanoseconds));
                if (enqueued > 0 and elapsed >= budget_ns) break;
                if (self.decompress_pending.load(.monotonic) >= INPUT_DECOMPRESS_CAP) {
                    if (elapsed >= budget_ns) break;
                    std.Thread.yield() catch {};
                    continue;
                }

                const popped = ring.pop() orelse break;
                scanned += 1;

                if (!popped.entry.conn.isOpen()) {
                    dropPopped(ring, popped);
                    continue;
                }

                const work = self.decompress_pool.acquire() orelse {
                    _ = self.dropped_packets.fetchAdd(1, .monotonic);
                    dropPopped(ring, popped);
                    continue;
                };
                const raw: []const u8 = if (popped.heap) |heap|
                    heap
                else
                    ring.slab[popped.slot * ring.slot_size ..][0..popped.entry.len];
                work.* = .{
                    .conn = popped.entry.conn,
                    .raw = raw,
                    .raw_heap = popped.heap,
                    .ring = .{ .ring = ring, .slot = popped.slot },
                    .allocator = self.allocator,
                    .handler = self,
                };

                _ = self.decompress_pending.fetchAdd(1, .monotonic);
                self.tasks.enqueue(.{
                    .work = scope.ringDecompressTask,
                    .callback = scope.decompressCallback,
                    .cleanup = scope.decompressCleanup,
                    .ctx = @ptrCast(work),

                    .shard_key = popped.entry.conn.id,
                    .kind = .input,
                }) catch {
                    _ = self.decompress_pending.fetchSub(1, .monotonic);
                    dropPopped(ring, popped);
                    self.decompress_pool.release(work);
                    continue;
                };

                enqueued += 1;
            }

            return .{ .processed = enqueued, .remaining = ring.depth() };
        }

        /// The ring slot owns one connection reference; dropping the slot has to drop it too.
        fn dropPopped(ring: *InboundRing, popped: InboundRing.Popped) void {
            popped.entry.conn.release();
            ring.discard(popped);
        }

        pub fn drainLegacy(self: *NetworkHandler, budget_ns: u64, max_packets: usize) PacketDrainResult {
            const io = self.io;
            const started = std.Io.Timestamp.now(io, .awake);
            const cap = queue.drainCap(max_packets);

            self.packet_queue_mutex.lock(io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                return .{ .processed = 0, .remaining = 0 };
            };

            var batch = self.packet_queue;
            self.packet_queue = .empty;
            self.packet_queue_mutex.unlock(io);

            const scan_limit = @min(batch.items.len, cap);

            var consumed: usize = 0;
            var enqueued: usize = 0;
            while (consumed < scan_limit) : (consumed += 1) {
                const entry = &batch.items[consumed];
                if (!entry.conn.isOpen()) {
                    entry.conn.release();
                    self.allocator.free(entry.payload);
                    entry.payload = &.{};
                    continue;
                }

                if (enqueued > 0) {
                    const elapsed: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).nanoseconds));
                    if (elapsed >= budget_ns) break;
                }

                if (self.decompress_pending.load(.monotonic) >= INPUT_DECOMPRESS_CAP) break;

                const work = self.decompress_pool.acquire() orelse {
                    _ = self.dropped_packets.fetchAdd(1, .monotonic);
                    entry.conn.release();
                    self.allocator.free(entry.payload);
                    entry.payload = &.{};
                    continue;
                };
                work.* = .{
                    .conn = entry.conn,
                    .raw = entry.payload,
                    .allocator = self.allocator,
                    .handler = self,
                    .decompressed = null,
                };
                _ = self.decompress_pending.fetchAdd(1, .monotonic);
                self.tasks.enqueue(.{
                    .work = scope.decompressTask,
                    .callback = scope.decompressCallback,
                    .cleanup = scope.decompressCleanup,
                    .ctx = @ptrCast(work),
                    .shard_key = entry.conn.id,
                    .kind = .input,
                }) catch {
                    log.err("threaded_tasks enqueue FAILED", .{});
                    _ = self.decompress_pending.fetchSub(1, .monotonic);
                    entry.conn.release();
                    self.allocator.free(entry.payload);
                    entry.payload = &.{};
                    self.decompress_pool.release(work);
                    continue;
                };

                enqueued += 1;
                entry.payload = &.{};
            }

            self.packet_queue_mutex.lock(io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                for (batch.items[consumed..]) |entry| {
                    entry.conn.release();
                    self.allocator.free(entry.payload);
                }
                batch.deinit(self.allocator);
                return .{ .processed = enqueued, .remaining = 0 };
            };
            var arrivals = self.packet_queue;
            queue.requeueLeftover(&batch, &arrivals, self.allocator, consumed);
            self.packet_queue = batch;
            const remaining = self.packet_queue.items.len;
            self.packet_queue_mutex.unlock(io);

            return .{ .processed = enqueued, .remaining = remaining };
        }

        pub fn publishToRing(self: *NetworkHandler, ring: *InboundRing, conn: *Connection, payload: []const u8) void {
            if (!conn.isOpen()) return;
            conn.retain();
            _ = ring.publish(conn, payload) orelse {
                _ = self.dropped_packets.fetchAdd(1, .monotonic);
                conn.release();
            };
        }

        pub fn enqueueLegacy(self: *NetworkHandler, conn: *Connection, payload: []const u8) void {
            if (!conn.isOpen()) return;
            conn.retain();
            const copy = self.allocator.dupe(u8, payload) catch {
                conn.release();
                return;
            };

            self.packet_queue_mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                conn.release();
                self.allocator.free(copy);
                return;
            };
            defer self.packet_queue_mutex.unlock(self.io);

            if (self.packet_queue.items.len >= queue.MAX_PACKET_QUEUE) {
                _ = self.dropped_packets.fetchAdd(1, .monotonic);
                conn.release();
                self.allocator.free(copy);
                return;
            }

            self.packet_queue.append(self.allocator, .{
                .conn = conn,
                .payload = copy,
            }) catch {
                conn.release();
                self.allocator.free(copy);
            };
        }
    };
}
