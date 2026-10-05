const std = @import("std");

const NO_WORKER: usize = std.math.maxInt(usize);

threadlocal var current_worker_index: usize = NO_WORKER;

pub fn currentWorkerIndex() ?usize {
    const index = current_worker_index;
    return if (index == NO_WORKER) null else index;
}

pub const WorkFn = *const fn (ctx: *anyopaque) void;
pub const CallbackFn = *const fn (ctx: *anyopaque) void;
pub const CleanupFn = *const fn (ctx: *anyopaque) void;

pub const Kind = enum { input, world };

/// `split` dedicates `max(1, cpu/4)` workers to input so a chunk burst cannot delay input decompression.
pub const WorkerLayout = enum { shared, split };

pub const input_queue_capacity: usize = 128;
pub const world_queue_capacity: usize = 512;
pub const completed_queue_capacity: usize = 2048;

pub const ThreadedTask = struct {
    work: WorkFn,
    callback: ?CallbackFn = null,
    cleanup: ?CleanupFn = null,
    ctx: *anyopaque,
    shard_key: u64 = 0,
    kind: Kind = .world,
};

/// Blocking parallel-for: the tick publishes one trampoline per worker and waits for all of them.
pub const ParallelJob = struct {
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    item_count: usize = 0,
    /// Workers remaining; each trampoline drops it before returning so the waiter cannot deadlock behind a worker parked in `pushCompleted`.
    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    body: *const fn (index: usize, ctx: *anyopaque) void = undefined,
    ctx: *anyopaque = undefined,
    /// The waiter parks here instead of spinning, so a parallel phase costs worker time, not a busy core on the tick thread.
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    fn trampoline(raw: *anyopaque) void {
        const self: *ParallelJob = @ptrCast(@alignCast(raw));
        while (true) {
            const index = self.next_index.fetchAdd(1, .monotonic);
            if (index >= self.item_count) break;
            self.body(index, self.ctx);
        }
        if (self.remaining.fetchSub(1, .release) == 1) {
            self.mutex.lock(self.io) catch return;
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};

pub const WorkerCountResolution = struct {
    cpu_count: usize,
    recommended_max: usize,
    requested_count: usize,
    resolved_count: usize,
    auto_selected: bool,
};

pub const WorkerLayoutResolution = struct {
    layout: WorkerLayout,
    cpu_count: usize,
    worker_count: usize,
    input_worker_count: usize,
    world_worker_count: usize,
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

/// A single worker cannot be split, so the pool falls back to `shared`.
pub fn resolveWorkerLayout(requested: WorkerLayout, worker_count: usize, cpu_count: usize) WorkerLayoutResolution {
    if (requested == .split and worker_count >= 2) {
        const requested_input = @max(@as(usize, 1), cpu_count / 4);
        const input_count = @min(requested_input, worker_count - 1);
        return .{
            .layout = .split,
            .cpu_count = cpu_count,
            .worker_count = worker_count,
            .input_worker_count = input_count,
            .world_worker_count = worker_count - input_count,
        };
    }
    return .{
        .layout = .shared,
        .cpu_count = cpu_count,
        .worker_count = worker_count,
        .input_worker_count = 0,
        .world_worker_count = worker_count,
    };
}

/// Single producer (the tick) and single consumer (the shard's own worker); a full ring reports it instead of growing.
fn SpscRing(comptime T: type) type {
    return struct {
        const Self = @This();

        slots: []T = &.{},
        mask: usize = 0,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const size = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(T, size);
            return .{ .slots = slots, .mask = size - 1 };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.slots.len > 0) allocator.free(self.slots);
            self.slots = &.{};
        }

        fn empty(self: *const Self) bool {
            return self.tail.load(.acquire) == self.head.load(.acquire);
        }

        fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head -% tail >= self.slots.len) return false;
            self.slots[head & self.mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail == head) return null;
            const item = self.slots[tail & self.mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }
    };
}

/// Vyukov bounded MPMC ring for completions (every worker pushes, the tick pops); the per-slot sequence replaces a shared mutex + ArrayList.
fn MpmcRing(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T = undefined,
        };

        slots: []Slot = &.{},
        mask: usize = 0,
        enqueue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const size = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(Slot, size);
            for (slots, 0..) |*slot, i| slot.* = .{ .sequence = std.atomic.Value(usize).init(i) };
            return .{ .slots = slots, .mask = size - 1 };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.slots.len > 0) allocator.free(self.slots);
            self.slots = &.{};
        }

        /// Producer side; safe from any worker thread.
        fn push(self: *Self, value: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const sequence = slot.sequence.load(.acquire);
                const diff = sequence -% pos;
                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    slot.value = value;
                    slot.sequence.store(pos +% 1, .release);
                    return true;
                }
                if (@as(isize, @bitCast(diff)) < 0) return false;
                pos = self.enqueue_pos.load(.monotonic);
            }
        }

        fn pop(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const sequence = slot.sequence.load(.acquire);
                const diff = sequence -% (pos +% 1);
                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    break;
                }
                if (@as(isize, @bitCast(diff)) < 0) return null;
                pos = self.dequeue_pos.load(.monotonic);
            }
            const value = self.slots[pos & self.mask].value;
            self.slots[pos & self.mask].sequence.store(pos +% self.slots.len, .release);
            return value;
        }
    };
}

/// The mutex synchronizes task publication with the worker's sleep handshake.
const TaskShard = struct {
    queue: SpscRing(ThreadedTask),
    kind: Kind,
    idle: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    fn init(allocator: std.mem.Allocator, kind: Kind, capacity: usize) !TaskShard {
        return .{
            .queue = try SpscRing(ThreadedTask).init(allocator, capacity),
            .kind = kind,
        };
    }
};

pub const ThreadedTaskQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Requested by config; resolved to a concrete split in `start`.
    requested_layout: WorkerLayout = .split,
    layout_resolution: WorkerLayoutResolution = .{
        .layout = .shared,
        .cpu_count = 0,
        .worker_count = 0,
        .input_worker_count = 0,
        .world_worker_count = 0,
    },
    shards: []TaskShard = &.{},
    input_shard_count: usize = 0,
    world_shard_count: usize = 0,
    completed_input: MpmcRing(ThreadedTask) = .{},
    completed_world: MpmcRing(ThreadedTask) = .{},
    workers: []?std.Thread,
    running: bool,
    configured_worker_count: usize,
    detected_cpu_count: usize,
    active_worker_count: usize,
    next_shard: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Set by `stop` before joining, so long-lived work functions can give up instead of waiting on a tick that will not run again.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, configured_worker_count: usize) ThreadedTaskQueue {
        return .{
            .io = io,
            .allocator = allocator,
            .workers = &.{},
            .running = false,
            .configured_worker_count = configured_worker_count,
            .detected_cpu_count = 0,
            .active_worker_count = 0,
        };
    }

    pub fn setLayout(self: *ThreadedTaskQueue, layout: WorkerLayout) void {
        self.requested_layout = layout;
    }

    pub fn start(self: *ThreadedTaskQueue) !void {
        self.running = true;
        self.stop_requested.store(false, .release);
        const resolution = resolveWorkerCount(self.configured_worker_count);
        self.detected_cpu_count = resolution.cpu_count;
        self.active_worker_count = resolution.resolved_count;
        const worker_count = resolution.resolved_count;

        self.layout_resolution = resolveWorkerLayout(self.requested_layout, worker_count, resolution.cpu_count);
        self.input_shard_count = self.layout_resolution.input_worker_count;
        self.world_shard_count = self.layout_resolution.world_worker_count;

        self.shards = try self.allocator.alloc(TaskShard, worker_count);
        for (self.shards, 0..) |*shard, i| {
            const kind: Kind = if (i < self.input_shard_count) .input else .world;
            const capacity = if (kind == .input) input_queue_capacity else world_queue_capacity;
            shard.* = try TaskShard.init(self.allocator, kind, capacity);
        }

        self.completed_input = try MpmcRing(ThreadedTask).init(self.allocator, completed_queue_capacity);
        errdefer self.completed_input.deinit(self.allocator);
        self.completed_world = try MpmcRing(ThreadedTask).init(self.allocator, completed_queue_capacity);
        errdefer self.completed_world.deinit(self.allocator);

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

    pub fn layoutResolution(self: *const ThreadedTaskQueue) WorkerLayoutResolution {
        return self.layout_resolution;
    }

    pub fn worldWorkerCount(self: *const ThreadedTaskQueue) usize {
        return self.world_shard_count;
    }

    /// Blocks until every item is done; the caller must tolerate an inline run when the pool is down or has one world worker.
    pub fn runParallel(self: *ThreadedTaskQueue, job: *ParallelJob, shards: usize) void {
        if (job.item_count == 0) return;
        job.io = self.io;
        if (shards <= 1 or self.world_shard_count == 0 or !self.running) {
            var index: usize = 0;
            while (index < job.item_count) : (index += 1) job.body(index, job.ctx);
            return;
        }

        const workers = @min(shards, @min(job.item_count, self.world_shard_count));
        job.next_index.store(0, .monotonic);
        job.remaining.store(workers, .release);

        var published: usize = 0;
        while (published < workers) {
            self.enqueue(.{
                .work = ParallelJob.trampoline,
                .ctx = @ptrCast(job),
                .kind = .world,
                .shard_key = published + 1,
            }) catch {
                // Let the workers drain a momentarily full shard and retry rather than fall back to a serial run.
                std.Thread.yield() catch {};
                continue;
            };
            published += 1;
        }

        job.mutex.lock(job.io) catch return;
        while (job.remaining.load(.acquire) != 0) {
            job.cond.wait(job.io, &job.mutex) catch {
                job.mutex.unlock(job.io);
                return;
            };
        }
        job.mutex.unlock(job.io);
    }

    fn shardIndexFor(self: *ThreadedTaskQueue, task: ThreadedTask) usize {
        const base: usize = if (self.layout_resolution.layout == .split and task.kind == .world)
            self.input_shard_count
        else
            0;
        const count: usize = if (self.layout_resolution.layout == .split)
            (if (task.kind == .input) self.input_shard_count else self.world_shard_count)
        else
            self.shards.len;
        if (task.shard_key != 0) return base + @as(usize, @intCast(task.shard_key % count));
        const n = self.next_shard.fetchAdd(1, .monotonic);
        return base + @as(usize, @intCast(n % count));
    }

    /// Producer side (the tick thread); a full shard returns `error.QueueFull` instead of growing.
    pub fn enqueue(self: *ThreadedTaskQueue, task: ThreadedTask) !void {
        if (self.shards.len == 0 or !self.running) return error.QueueNotStarted;
        const shard = &self.shards[self.shardIndexFor(task)];
        if (!shard.queue.push(task)) return error.QueueFull;

        shard.mutex.lockUncancelable(self.io);
        if (shard.idle.load(.acquire)) shard.cond.signal(self.io);
        shard.mutex.unlock(self.io);
    }

    /// Input completions drain before world ones: their handlers mutate player state.
    pub fn drainCompleted(self: *ThreadedTaskQueue, budget_ns: u64) void {
        self.drainCompletedInput(budget_ns);
        self.drainCompletedWorld(budget_ns);
    }

    pub fn drainCompletedInput(self: *ThreadedTaskQueue, budget_ns: u64) void {
        self.drainCompletedRing(&self.completed_input, budget_ns);
    }

    pub fn drainCompletedWorld(self: *ThreadedTaskQueue, budget_ns: u64) void {
        self.drainCompletedRing(&self.completed_world, budget_ns);
    }

    fn drainCompletedRing(self: *ThreadedTaskQueue, ring: *MpmcRing(ThreadedTask), budget_ns: u64) void {
        const drain_start = std.Io.Timestamp.now(self.io, .awake);
        while (ring.pop()) |task| {
            if (task.callback) |cb| cb(task.ctx);
            const elapsed: u64 = @intCast(@max(0, drain_start.durationTo(.now(self.io, .awake)).nanoseconds));
            if (elapsed >= budget_ns) return;
        }
    }

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
        self.stop();
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

    /// On shutdown a finished task gives up on a full completion ring and cleans itself instead of hanging the join.
    fn pushCompleted(self: *ThreadedTaskQueue, task: ThreadedTask) void {
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

    fn workerLoop(self: *ThreadedTaskQueue, shard_idx: usize) void {
        current_worker_index = shard_idx;
        defer current_worker_index = NO_WORKER;

        const shard = &self.shards[shard_idx];
        while (true) {
            if (shard.queue.pop()) |task| {
                task.work(task.ctx);
                self.pushCompleted(task);
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

test "worker layout splits a quarter of the CPUs to input and keeps one world worker" {
    const eight = resolveWorkerLayout(.split, 6, 8);
    try std.testing.expectEqual(WorkerLayout.split, eight.layout);
    try std.testing.expectEqual(@as(usize, 2), eight.input_worker_count);
    try std.testing.expectEqual(@as(usize, 4), eight.world_worker_count);

    const four = resolveWorkerLayout(.split, 4, 4);
    try std.testing.expectEqual(@as(usize, 1), four.input_worker_count);
    try std.testing.expectEqual(@as(usize, 3), four.world_worker_count);

    const many = resolveWorkerLayout(.split, 2, 32);
    try std.testing.expectEqual(@as(usize, 1), many.input_worker_count);
    try std.testing.expectEqual(@as(usize, 1), many.world_worker_count);

    const single = resolveWorkerLayout(.split, 1, 8);
    try std.testing.expectEqual(WorkerLayout.shared, single.layout);

    const shared = resolveWorkerLayout(.shared, 6, 8);
    try std.testing.expectEqual(WorkerLayout.shared, shared.layout);
    try std.testing.expectEqual(@as(usize, 0), shared.input_worker_count);
    try std.testing.expectEqual(@as(usize, 6), shared.world_worker_count);
}

test "spsc ring is bounded, FIFO and wraps" {
    var ring = try SpscRing(u32).init(std.testing.allocator, 4);
    defer ring.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), ring.slots.len);
    for (0..4) |i| try std.testing.expect(ring.push(@intCast(i)));
    try std.testing.expect(!ring.push(99));
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), ring.pop().?);
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
    try std.testing.expect(ring.push(42));
    try std.testing.expectEqual(@as(u32, 42), ring.pop().?);
}

test "mpmc completion ring keeps FIFO order across many pushes" {
    var ring = try MpmcRing(u64).init(std.testing.allocator, 256);
    defer ring.deinit(std.testing.allocator);

    for (0..200) |i| try std.testing.expect(ring.push(i));
    for (0..200) |i| try std.testing.expectEqual(@as(u64, i), ring.pop().?);
    try std.testing.expectEqual(@as(?u64, null), ring.pop());
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

test "split layout keeps input and world tasks on their own workers" {
    const allocator = std.testing.allocator;

    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 4);
    defer queue.deinit();
    try queue.start();

    const resolution = queue.layoutResolution();
    if (resolution.layout != .split) {
        return;
    }

    const Context = struct {
        mask: *std.atomic.Value(u64),
        done: *std.atomic.Value(usize),
    };

    const work_fn = struct {
        fn f(ctx: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(ctx));
            const index: u6 = @intCast(currentWorkerIndex() orelse 63);
            _ = c.mask.fetchOr(@as(u64, 1) << index, .seq_cst);
            _ = c.done.fetchAdd(1, .seq_cst);
        }
    }.f;

    var input_mask = std.atomic.Value(u64).init(0);
    var world_mask = std.atomic.Value(u64).init(0);
    var done = std.atomic.Value(usize).init(0);

    const Total: usize = 32;
    var input_ctx = Context{ .mask = &input_mask, .done = &done };
    var world_ctx = Context{ .mask = &world_mask, .done = &done };

    for (0..Total) |i| {
        try queue.enqueue(.{
            .work = work_fn,
            .ctx = @ptrCast(&input_ctx),
            .kind = .input,
            .shard_key = i + 1,
        });
        try queue.enqueue(.{
            .work = work_fn,
            .ctx = @ptrCast(&world_ctx),
            .kind = .world,
        });
    }

    var attempts: usize = 0;
    while (attempts < 2000) : (attempts += 1) {
        queue.drainCompleted(std.math.maxInt(u64));
        if (done.load(.seq_cst) == Total * 2) break;
        std.testing.io.sleep(.fromNanoseconds(1_000_000), .awake) catch {};
    }
    try std.testing.expectEqual(Total * 2, done.load(.seq_cst));

    var bit: usize = 0;
    while (bit < 64) : (bit += 1) {
        const set = (input_mask.load(.seq_cst) >> @as(u6, @intCast(bit))) & 1 == 1;
        if (set) try std.testing.expect(bit < resolution.input_worker_count);
    }
    bit = 0;
    while (bit < 64) : (bit += 1) {
        const set = (world_mask.load(.seq_cst) >> @as(u6, @intCast(bit))) & 1 == 1;
        if (set) try std.testing.expect(bit >= resolution.input_worker_count);
        if (set) try std.testing.expect(bit < resolution.worker_count);
    }
}

test "enqueue reports QueueFull instead of growing without bound" {
    const allocator = std.testing.allocator;

    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 2);
    queue.setLayout(.shared);
    try queue.start();

    const release = try allocator.create(std.atomic.Value(bool));
    release.* = std.atomic.Value(bool).init(false);
    const started = try allocator.create(std.atomic.Value(usize));
    started.* = std.atomic.Value(usize).init(0);
    defer allocator.destroy(release);
    defer allocator.destroy(started);
    defer queue.deinit();

    const Context = struct {
        release: *std.atomic.Value(bool),
        started: *std.atomic.Value(usize),
    };

    const work_fn = struct {
        fn f(ctx: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(ctx));
            _ = c.started.fetchAdd(1, .seq_cst);
            while (!c.release.load(.seq_cst)) std.Thread.yield() catch {};
        }
    }.f;

    var context = Context{ .release = release, .started = started };
    const task = ThreadedTask{
        .work = work_fn,
        .ctx = @ptrCast(&context),
        .kind = .world,
    };

    const attempts = world_queue_capacity * 2 + 256;
    var full_hits: usize = 0;
    var accepted: usize = 0;
    for (0..attempts) |_| {
        queue.enqueue(task) catch |err| {
            if (err == error.QueueFull) {
                full_hits += 1;
                continue;
            }
            return err;
        };
        accepted += 1;
    }
    try std.testing.expect(full_hits > 0);
    try std.testing.expect(accepted <= world_queue_capacity * 2 + 2);

    release.store(true, .seq_cst);
    var attempts_drain: usize = 0;
    while (attempts_drain < 4000 and started.load(.seq_cst) < accepted) : (attempts_drain += 1) {
        queue.drainCompleted(std.math.maxInt(u64));
        std.testing.io.sleep(.fromNanoseconds(200_000), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, accepted), started.load(.seq_cst));
}

test "bursts of completions drain without losing work" {
    const allocator = std.testing.allocator;

    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 2);
    defer queue.deinit();
    try queue.start();

    const Context = struct {
        done: *std.atomic.Value(usize),
    };

    const work_fn = struct {
        fn f(ctx: *anyopaque) void {
            const c: *Context = @ptrCast(@alignCast(ctx));
            _ = c.done.fetchAdd(1, .seq_cst);
        }
    }.f;

    var done = std.atomic.Value(usize).init(0);
    var context = Context{ .done = &done };

    const rounds: usize = 200;
    const per_round: usize = 32;
    var accepted: usize = 0;
    for (0..rounds) |_| {
        for (0..per_round) |_| {
            queue.enqueue(.{
                .work = work_fn,
                .ctx = @ptrCast(&context),
                .kind = .world,
            }) catch continue;
            accepted += 1;
        }
        queue.drainCompleted(std.math.maxInt(u64));
    }

    var attempts: usize = 0;
    while (attempts < 40_000) : (attempts += 1) {
        queue.drainCompleted(std.math.maxInt(u64));
        if (done.load(.seq_cst) == accepted) break;
        std.testing.io.sleep(.fromNanoseconds(50_000), .awake) catch {};
    }
    try std.testing.expect(accepted > 0);
    try std.testing.expectEqual(accepted, done.load(.seq_cst));
}
