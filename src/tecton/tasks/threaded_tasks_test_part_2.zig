pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const currentWorkerIndex = scope.currentWorkerIndex;
        const WorkerLayout = scope.WorkerLayout;
        const world_queue_capacity = scope.world_queue_capacity;
        const ThreadedTask = scope.ThreadedTask;
        const totalServerThreadCount = scope.totalServerThreadCount;
        const resolveWorkerCountForCpu = scope.resolveWorkerCountForCpu;
        const resolveWorkerLayout = scope.resolveWorkerLayout;
        const SpscRing = scope.SpscRing;
        const MpmcRing = scope.MpmcRing;
        const ThreadedTaskQueue = scope.ThreadedTaskQueue;
        const private_threadedtaskqueue_init = scope.private_threadedtaskqueue_init;

        pub fn case_009() !void {
            const allocator = std.testing.allocator;

            var queue = private_threadedtaskqueue_init(std.testing.io, allocator, 2);
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

        pub fn case_010() !void {
            const allocator = std.testing.allocator;

            var queue = private_threadedtaskqueue_init(std.testing.io, allocator, 2);
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
    };
}
