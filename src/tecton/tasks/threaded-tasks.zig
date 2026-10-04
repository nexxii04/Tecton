const std = @import("std");

pub const WorkFn = *const fn (ctx: *anyopaque) void;
pub const CallbackFn = *const fn (ctx: *anyopaque) void;
pub const CleanupFn = *const fn (ctx: *anyopaque) void;

pub const ThreadedTask = struct {
    work: WorkFn,
    callback: ?CallbackFn = null,
    cleanup: ?CleanupFn = null,
    ctx: *anyopaque,
    // Tasks sharing a shard_key run on one worker in submission order; 0 means round-robin.
    shard_key: u64 = 0,
};

pub const WorkerCountResolution = struct {
    cpu_count: usize,
    recommended_max: usize,
    requested_count: usize,
    resolved_count: usize,
    auto_selected: bool,
};

pub fn computeWorkerCount(configured_count: usize) usize {
    return resolveWorkerCount(configured_count).resolved_count;
}

pub fn totalServerThreadCount(worker_count: usize) usize {
    return 1 + 2 + worker_count;
}

pub fn resolveWorkerCount(configured_count: usize) WorkerCountResolution {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    return resolveWorkerCountForCpu(configured_count, cpu_count);
}

fn resolveWorkerCountForCpu(configured_count: usize, cpu_count: usize) WorkerCountResolution {
    const recommended_max = recommendedWorkerCountForCpu(cpu_count);
    if (configured_count > 0) {
        return .{
            .cpu_count = cpu_count,
            .recommended_max = recommended_max,
            .requested_count = configured_count,
            .resolved_count = @min(configured_count, recommended_max),
            .auto_selected = false,
        };
    }

    return .{
        .cpu_count = cpu_count,
        .recommended_max = recommended_max,
        .requested_count = 0,
        .resolved_count = recommended_max,
        .auto_selected = true,
    };
}

fn recommendedWorkerCountForCpu(cpu_count: usize) usize {
    if (cpu_count <= 2) return 1;
    const count = cpu_count - 2;
    return @max(@as(usize, 1), @min(count, 16));
}

/// One worker per shard; tasks in a shard run FIFO, keyless tasks round-robin across shards.
const TaskShard = struct {
    pending: std.ArrayList(ThreadedTask) = .empty,
    head: usize = 0,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    fn count(self: *const TaskShard) usize {
        return self.pending.items.len - self.head;
    }
};

pub const ThreadedTaskQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    shards: []TaskShard = &.{},
    completed: std.ArrayList(ThreadedTask),
    completed_head: usize = 0,
    completed_mutex: std.Io.Mutex,
    workers: []?std.Thread,
    running: bool,
    configured_worker_count: usize,
    detected_cpu_count: usize,
    active_worker_count: usize,
    next_shard: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, configured_worker_count: usize) ThreadedTaskQueue {
        return .{
            .io = io,
            .allocator = allocator,
            .completed = std.ArrayList(ThreadedTask).empty,
            .completed_mutex = .init,
            .workers = &.{},
            .running = false,
            .configured_worker_count = configured_worker_count,
            .detected_cpu_count = 0,
            .active_worker_count = 0,
        };
    }

    pub fn start(self: *ThreadedTaskQueue) !void {
        self.running = true;
        const resolution = resolveWorkerCount(self.configured_worker_count);
        self.detected_cpu_count = resolution.cpu_count;
        self.active_worker_count = resolution.resolved_count;
        const worker_count = resolution.resolved_count;
        self.shards = try self.allocator.alloc(TaskShard, worker_count);
        for (self.shards) |*shard| {
            shard.* = .{};
        }
        self.workers = try self.allocator.alloc(?std.Thread, worker_count);
        for (self.workers, 0..) |*w, i| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{ self, i });
        }
    }

    pub fn workerCount(self: *const ThreadedTaskQueue) usize {
        return self.active_worker_count;
    }

    pub fn detectedCpuCount(self: *const ThreadedTaskQueue) usize {
        return self.detected_cpu_count;
    }

    fn shardIndexFor(self: *ThreadedTaskQueue, task: ThreadedTask) usize {
        if (task.shard_key != 0) return @intCast(task.shard_key % self.shards.len);
        const n = self.next_shard.fetchAdd(1, .monotonic);
        return @intCast(n % self.shards.len);
    }

    pub fn enqueue(self: *ThreadedTaskQueue, task: ThreadedTask) !void {
        if (self.shards.len == 0) return error.QueueNotStarted;
        const shard = &self.shards[self.shardIndexFor(task)];
        try shard.mutex.lock(self.io);
        defer shard.mutex.unlock(self.io);
        try shard.pending.append(self.allocator, task);
        shard.cond.signal(self.io);
    }

    pub fn drainCompleted(self: *ThreadedTaskQueue, budget_ns: u64) void {
        const drain_start = std.Io.Timestamp.now(self.io, .awake);
        while (true) {
            self.completed_mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                return;
            };
            if (self.completed_head == self.completed.items.len) {
                self.completed_mutex.unlock(self.io);
                return;
            }
            const task = self.completed.items[self.completed_head];
            self.completed_head += 1;
            if (self.completed_head == self.completed.items.len) {
                self.completed.clearRetainingCapacity();
                self.completed_head = 0;
            }
            self.completed_mutex.unlock(self.io);

            if (task.callback) |cb| cb(task.ctx);

            const elapsed: u64 = @intCast(@max(0, drain_start.durationTo(.now(self.io, .awake)).nanoseconds));
            if (elapsed >= budget_ns) return;
        }
    }

    pub fn clearPending(self: *ThreadedTaskQueue) void {
        for (self.shards) |*shard| {
            shard.mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                continue;
            };
            for (shard.pending.items[shard.head..]) |task| {
                if (task.cleanup) |c_fn| c_fn(task.ctx);
            }
            shard.pending.clearRetainingCapacity();
            shard.head = 0;
            shard.mutex.unlock(self.io);
        }
    }

    pub fn stop(self: *ThreadedTaskQueue) void {
        self.running = false;
        for (self.shards) |*shard| {
            shard.mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                continue;
            };
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
        self.stop();
        for (self.shards) |*shard| {
            for (shard.pending.items[shard.head..]) |task| {
                if (task.cleanup) |c_fn| c_fn(task.ctx);
            }
            if (shard.pending.capacity > 0) shard.pending.deinit(self.allocator);
        }
        if (self.shards.len > 0) self.allocator.free(self.shards);
        self.shards = &.{};

        for (self.completed.items[self.completed_head..]) |task| {
            if (task.cleanup) |c_fn| c_fn(task.ctx);
        }
        if (self.completed.capacity > 0) self.completed.deinit(self.allocator);
        self.completed = .empty;
        self.completed_head = 0;
        if (self.workers.len > 0) self.allocator.free(self.workers);
    }

    fn workerLoop(self: *ThreadedTaskQueue, shard_idx: usize) void {
        const shard = &self.shards[shard_idx];
        while (true) {
            shard.mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                std.Thread.yield() catch {};
                continue;
            };
            while (shard.count() == 0 and self.running) {
                shard.cond.wait(self.io, &shard.mutex) catch |err| {
                    std.log.err("worker condition wait failed: {}", .{err});
                    return;
                };
            }
            if (!self.running and shard.count() == 0) {
                shard.mutex.unlock(self.io);
                return;
            }
            const task = shard.pending.items[shard.head];
            shard.head += 1;
            if (shard.head == shard.pending.items.len) {
                shard.pending.clearRetainingCapacity();
                shard.head = 0;
            }
            shard.mutex.unlock(self.io);

            task.work(task.ctx);

            self.completed_mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                if (task.cleanup) |c_fn| c_fn(task.ctx);
                std.Thread.yield() catch {};
                continue;
            };

            self.completed.append(self.allocator, task) catch {
                if (task.cleanup) |c_fn| c_fn(task.ctx);
            };
            self.completed_mutex.unlock(self.io);
        }
    }
};

test "dynamic worker count bounds" {
    try std.testing.expectEqual(@as(usize, 1), resolveWorkerCountForCpu(0, 2).resolved_count);
    try std.testing.expectEqual(@as(usize, 6), resolveWorkerCountForCpu(0, 8).resolved_count);
    try std.testing.expectEqual(@as(usize, 16), resolveWorkerCountForCpu(0, 32).resolved_count);
}

test "configured worker count is respected" {
    try std.testing.expectEqual(@as(usize, 4), resolveWorkerCountForCpu(4, 8).resolved_count);
    try std.testing.expectEqual(@as(usize, 6), resolveWorkerCountForCpu(128, 8).resolved_count);
    try std.testing.expectEqual(@as(usize, 1), resolveWorkerCountForCpu(4, 2).resolved_count);
}

test "server thread count includes main raknet and workers" {
    try std.testing.expectEqual(@as(usize, 13), totalServerThreadCount(10));
    try std.testing.expectEqual(@as(usize, 4), totalServerThreadCount(1));
}

test "task queue completeness across shards" {
    const allocator = std.testing.allocator;
    var completed_count: usize = 0;

    const Context = struct {
        counter: *usize,
    };

    const work_fn = struct {
        fn f(ctx: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(ctx));
            _ = @atomicRmw(usize, c.counter, .Add, 1, .seq_cst);
        }
    }.f;

    const N: usize = 100;
    var contexts: [N]Context = undefined;
    for (&contexts) |*ctx| {
        ctx.* = .{ .counter = &completed_count };
    }

    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 0);
    defer queue.deinit();
    try queue.start();

    for (&contexts) |*ctx| {
        try queue.enqueue(.{
            .work = work_fn,
            .ctx = @ptrCast(ctx),
        });
    }

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        queue.drainCompleted(std.math.maxInt(u64));
        if (@atomicLoad(usize, &completed_count, .seq_cst) == N) break;
        std.testing.io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
    }

    try std.testing.expectEqual(N, @atomicLoad(usize, &completed_count, .seq_cst));
}

test "tasks with the same shard key complete in submission order" {
    const allocator = std.testing.allocator;

    const Context = struct {
        index: usize,
        seq: *std.atomic.Value(usize),
        recorded: []usize,
    };

    const work_fn = struct {
        fn f(ctx: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(ctx));
            const pos = c.seq.fetchAdd(1, .seq_cst);
            c.recorded[pos] = c.index;
        }
    }.f;

    const N: usize = 64;
    const recorded = try allocator.alloc(usize, N);
    defer allocator.free(recorded);
    var seq = std.atomic.Value(usize).init(0);

    var contexts: [N]Context = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{ .index = i, .seq = &seq, .recorded = recorded };
    }

    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 0);
    defer queue.deinit();
    try queue.start();

    for (&contexts) |*ctx| {
        try queue.enqueue(.{
            .work = work_fn,
            .ctx = @ptrCast(ctx),
            .shard_key = 0x1234,
        });
    }

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        queue.drainCompleted(std.math.maxInt(u64));
        if (seq.load(.seq_cst) == N) break;
        std.testing.io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
    }

    try std.testing.expectEqual(N, seq.load(.seq_cst));
    for (recorded, 0..) |index, position| {
        try std.testing.expectEqual(position, index);
    }
}
