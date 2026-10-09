pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ThreadedTaskQueue = scope.ThreadedTaskQueue;
        const ThreadedTask = scope.ThreadedTask;
        const MpmcRing = scope.MpmcRing;
        const NO_WORKER = scope.NO_WORKER;

        pub fn stop(self: *ThreadedTaskQueue) void {
            self.stop_requested.store(true, .release);
            self.running = false;
            for (self.shards) |*shard| {
                shard.mutex.lock(self.io) catch |err| {
                    std.log.err("failed to acquire lock: {}", .{err});
                    continue;
                };
                shard.idle.store(false, .release);
                shard.cond.broadcast(self.io);
                shard.mutex.unlock(self.io);
            }

            for (self.workers) |*w| {
                if (w.*) |t| {
                    t.join();
                    w.* = null;
                }
            }
        }

        pub fn deinit(self: *ThreadedTaskQueue) void {
            stop(self);
            for (self.shards) |*shard| {
                while (shard.queue.pop()) |task| {
                    if (task.cleanup) |c_fn| c_fn(task.ctx);
                }
                shard.queue.deinit(self.allocator);
            }
            if (self.shards.len > 0) self.allocator.free(self.shards);
            self.shards = &.{};

            while (self.completed_input.pop()) |task| {
                if (task.cleanup) |c_fn| c_fn(task.ctx);
            }
            while (self.completed_world.pop()) |task| {
                if (task.cleanup) |c_fn| c_fn(task.ctx);
            }
            self.completed_input.deinit(self.allocator);
            self.completed_world.deinit(self.allocator);
            if (self.workers.len > 0) self.allocator.free(self.workers);
            self.workers = &.{};
        }

        pub fn pushCompleted(self: *ThreadedTaskQueue, task: ThreadedTask) void {
            const ring = switch (task.kind) {
                .input => &self.completed_input,
                .world => &self.completed_world,
            };
            var yields: usize = 0;
            while (!ring.push(task)) {
                if (self.stop_requested.load(.acquire) and yields >= 1000) {
                    if (task.cleanup) |c_fn| c_fn(task.ctx);
                    return;
                }
                std.Thread.yield() catch {};
                yields += 1;
            }
        }

        pub fn workerLoop(self: *ThreadedTaskQueue, shard_idx: usize) void {
            scope.workerIndex().* = shard_idx;
            defer scope.workerIndex().* = NO_WORKER;

            const shard = &self.shards[shard_idx];
            while (true) {
                if (shard.queue.pop()) |task| {
                    task.work(task.ctx);
                    pushCompleted(self, task);
                    continue;
                }

                if (!self.running) return;

                shard.mutex.lock(self.io) catch |err| {
                    std.log.err("failed to acquire lock: {}", .{err});
                    std.Thread.yield() catch {};
                    continue;
                };
                shard.idle.store(true, .release);
                while (self.running and shard.queue.empty()) {
                    shard.cond.wait(self.io, &shard.mutex) catch |err| {
                        std.log.err("worker condition wait failed: {}", .{err});
                        shard.mutex.unlock(self.io);
                        return;
                    };
                }
                shard.idle.store(false, .release);
                shard.mutex.unlock(self.io);
            }
        }

        pub fn drainCompletedRing(self: *ThreadedTaskQueue, ring: *MpmcRing(ThreadedTask), budget_ns: u64) void {
            const drain_start = std.Io.Timestamp.now(self.io, .awake);
            while (ring.pop()) |task| {
                if (task.callback) |cb| cb(task.ctx);
                const elapsed: u64 = @intCast(@max(0, drain_start.durationTo(.now(self.io, .awake)).nanoseconds));
                if (elapsed >= budget_ns) return;
            }
        }
    };
}
