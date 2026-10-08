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

pub const ParallelJob = struct {
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    item_count: usize = 0,

    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    body: *const fn (index: usize, ctx: *anyopaque) void = undefined,
    ctx: *anyopaque = undefined,

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

    pub fn enqueue(self: *ThreadedTaskQueue, task: ThreadedTask) !void {
        if (self.shards.len == 0 or !self.running) return error.QueueNotStarted;
        const shard = &self.shards[self.shardIndexFor(task)];
        if (!shard.queue.push(task)) return error.QueueFull;

        shard.mutex.lockUncancelable(self.io);
        if (shard.idle.load(.acquire)) shard.cond.signal(self.io);
        shard.mutex.unlock(self.io);
    }

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

const test_owner = @This();
const test_scope = struct {
    pub const spsc_init = test_owner.SpscRing(u32).init;
    pub const spsc_deinit = test_owner.SpscRing(u32).deinit;
    pub const spsc_push = test_owner.SpscRing(u32).push;
    pub const spsc_pop = test_owner.SpscRing(u32).pop;
    pub const mpmc_init = test_owner.MpmcRing(u64).init;
    pub const mpmc_deinit = test_owner.MpmcRing(u64).deinit;
    pub const mpmc_push = test_owner.MpmcRing(u64).push;
    pub const mpmc_pop = test_owner.MpmcRing(u64).pop;
    pub const std = test_owner.std;
    pub const currentWorkerIndex = test_owner.currentWorkerIndex;
    pub const WorkerLayout = test_owner.WorkerLayout;
    pub const world_queue_capacity = test_owner.world_queue_capacity;
    pub const ThreadedTask = test_owner.ThreadedTask;
    pub const totalServerThreadCount = test_owner.totalServerThreadCount;
    pub const resolveWorkerCountForCpu = test_owner.resolveWorkerCountForCpu;
    pub const resolveWorkerLayout = test_owner.resolveWorkerLayout;
    pub const SpscRing = test_owner.SpscRing;
    pub const MpmcRing = test_owner.MpmcRing;
    pub const ThreadedTaskQueue = test_owner.ThreadedTaskQueue;
    pub const private_threadedtaskqueue_init = test_owner.ThreadedTaskQueue.init;
};

test "dynamic worker count bounds" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_000();
}

test "configured worker count is respected" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_001();
}

test "server thread count includes main raknet and workers" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_002();
}

test "worker layout splits a quarter of the CPUs to input and keeps one world worker" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_003();
}

test "spsc ring is bounded, FIFO and wraps" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_004();
}

test "mpmc completion ring keeps FIFO order across many pushes" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_005();
}

test "task queue completeness across shards" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_006();
}

test "tasks with the same shard key complete in submission order" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_007();
}

test "split layout keeps input and world tasks on their own workers" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_008();
}

test "enqueue reports QueueFull instead of growing without bound" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_009();
}

test "bursts of completions drain without losing work" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_010();
}
