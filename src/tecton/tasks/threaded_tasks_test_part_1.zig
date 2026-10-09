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

        pub fn case_000() !void {
            try std.testing.expectEqual(@as(usize, 1), resolveWorkerCountForCpu(0, 2).resolved_count);
            try std.testing.expectEqual(@as(usize, 6), resolveWorkerCountForCpu(0, 8).resolved_count);
            try std.testing.expectEqual(@as(usize, 16), resolveWorkerCountForCpu(0, 32).resolved_count);
        }

        pub fn case_001() !void {
            try std.testing.expectEqual(@as(usize, 4), resolveWorkerCountForCpu(4, 8).resolved_count);
            try std.testing.expectEqual(@as(usize, 6), resolveWorkerCountForCpu(128, 8).resolved_count);
            try std.testing.expectEqual(@as(usize, 1), resolveWorkerCountForCpu(4, 2).resolved_count);
        }

        pub fn case_002() !void {
            try std.testing.expectEqual(@as(usize, 13), totalServerThreadCount(10));
            try std.testing.expectEqual(@as(usize, 4), totalServerThreadCount(1));
        }

        pub fn case_003() !void {
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

        pub fn case_004() !void {
            var ring = try scope.spsc_init(std.testing.allocator, 4);
            defer scope.spsc_deinit(&ring, std.testing.allocator);

            try std.testing.expectEqual(@as(usize, 4), ring.slots.len);
            for (0..4) |i| try std.testing.expect(scope.spsc_push(&ring, @intCast(i)));
            try std.testing.expect(!scope.spsc_push(&ring, 99));
            for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), scope.spsc_pop(&ring).?);
            try std.testing.expectEqual(@as(?u32, null), scope.spsc_pop(&ring));
            try std.testing.expect(scope.spsc_push(&ring, 42));
            try std.testing.expectEqual(@as(u32, 42), scope.spsc_pop(&ring).?);
        }

        pub fn case_005() !void {
            var ring = try scope.mpmc_init(std.testing.allocator, 256);
            defer scope.mpmc_deinit(&ring, std.testing.allocator);

            for (0..200) |i| try std.testing.expect(scope.mpmc_push(&ring, i));
            for (0..200) |i| try std.testing.expectEqual(@as(u64, i), scope.mpmc_pop(&ring).?);
            try std.testing.expectEqual(@as(?u64, null), scope.mpmc_pop(&ring));
        }

        pub fn case_006() !void {
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

            var queue = private_threadedtaskqueue_init(std.testing.io, allocator, 0);
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

        pub fn case_007() !void {
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

            var queue = private_threadedtaskqueue_init(std.testing.io, allocator, 0);
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

        pub fn case_008() !void {
            const allocator = std.testing.allocator;

            var queue = private_threadedtaskqueue_init(std.testing.io, allocator, 4);
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
    };
}
