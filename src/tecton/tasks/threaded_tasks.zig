const std = @import("std");

const NO_WORKER: usize = std.math.maxInt(usize);

threadlocal var current_worker_index: usize = NO_WORKER;

pub fn currentWorkerIndex() ?usize {
    const index = current_worker_index;
    return if (index == NO_WORKER) null else index;
}

pub const WorkFn = @import("task.zig").WorkFn;
pub const CallbackFn = @import("task.zig").CallbackFn;
pub const CleanupFn = @import("task.zig").CleanupFn;
pub const Kind = @import("task.zig").Kind;
pub const ThreadedTask = @import("task.zig").ThreadedTask;
pub const ParallelJob = @import("task.zig").ParallelJob;
pub const input_queue_capacity = @import("task.zig").input_queue_capacity;
pub const world_queue_capacity = @import("task.zig").world_queue_capacity;
pub const completed_queue_capacity = @import("task.zig").completed_queue_capacity;

pub const WorkerLayout = @import("worker_layout.zig").WorkerLayout;
pub const WorkerCountResolution = @import("worker_layout.zig").WorkerCountResolution;
pub const WorkerLayoutResolution = @import("worker_layout.zig").WorkerLayoutResolution;
pub const computeWorkerCount = @import("worker_layout.zig").computeWorkerCount;
pub const totalServerThreadCount = @import("worker_layout.zig").totalServerThreadCount;
pub const resolveWorkerCount = @import("worker_layout.zig").resolveWorkerCount;
pub const resolveWorkerCountForCpu = @import("worker_layout.zig").resolveWorkerCountForCpu;
pub const resolveWorkerLayout = @import("worker_layout.zig").resolveWorkerLayout;

const SpscRing = @import("rings.zig").SpscRing;
const MpmcRing = @import("rings.zig").MpmcRing;

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
        if (self.running) return;
        if (self.shards.len != 0) return error.QueueAlreadyStarted;
        errdefer self.deinit();
        self.running = true;
        self.stop_requested.store(false, .release);
        const resolution = resolveWorkerCount(self.configured_worker_count);
        self.detected_cpu_count = resolution.cpu_count;
        self.active_worker_count = resolution.resolved_count;
        const worker_count = resolution.resolved_count;

        self.layout_resolution = resolveWorkerLayout(self.requested_layout, worker_count, resolution.cpu_count);
        self.input_shard_count = self.layout_resolution.input_worker_count;
        self.world_shard_count = self.layout_resolution.world_worker_count;

        const shards = try self.allocator.alloc(TaskShard, worker_count);
        var initialized: usize = 0;
        for (shards, 0..) |*shard, i| {
            const kind: Kind = if (i < self.input_shard_count) .input else .world;
            const capacity = if (kind == .input) input_queue_capacity else world_queue_capacity;
            shard.* = TaskShard.init(self.allocator, kind, capacity) catch |err| {
                for (shards[0..initialized]) |*ready| ready.queue.deinit(self.allocator);
                self.allocator.free(shards);
                return err;
            };
            initialized += 1;
        }
        self.shards = shards;

        self.completed_input = try MpmcRing(ThreadedTask).init(self.allocator, completed_queue_capacity);
        self.completed_world = try MpmcRing(ThreadedTask).init(self.allocator, completed_queue_capacity);

        self.workers = try self.allocator.alloc(?std.Thread, worker_count);
        @memset(self.workers, null);
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

    const drainCompletedRing = @import("worker.zig").Methods(helper_scope).drainCompletedRing;

    pub const stop = @import("worker.zig").Methods(helper_scope).stop;

    pub const deinit = @import("worker.zig").Methods(helper_scope).deinit;

    const pushCompleted = @import("worker.zig").Methods(helper_scope).pushCompleted;

    const workerLoop = @import("worker.zig").Methods(helper_scope).workerLoop;
};

fn exerciseQueueStart(allocator: std.mem.Allocator) !void {
    var queue = ThreadedTaskQueue.init(std.testing.io, allocator, 1);
    defer queue.deinit();
    try queue.start();
}

test "worker startup unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseQueueStart, .{});
}

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

test "server thread count includes the game clock, the transport ticker and workers" {
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

test "task queue deinit without start does not access uninitialized rings" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_011();
}

test "task queue deinit after stop preserves completed task cleanup" {
    try @import("threaded_tasks_test.zig").Suite(test_scope).case_012();
}

const helper_owner = @This();
const helper_scope = struct {
    pub const std = helper_owner.std;
    pub const ThreadedTaskQueue = helper_owner.ThreadedTaskQueue;
    pub const ThreadedTask = helper_owner.ThreadedTask;
    pub const MpmcRing = helper_owner.MpmcRing;
    pub const NO_WORKER = helper_owner.NO_WORKER;
    pub fn workerIndex() *usize {
        return &current_worker_index;
    }
};
