pub fn Suite(comptime scope: type) type {
    return struct {
        const Part0 = @import("threaded_tasks_test_part_1.zig").Suite(scope);
        pub const case_000 = Part0.case_000;
        pub const case_001 = Part0.case_001;
        pub const case_002 = Part0.case_002;
        pub const case_003 = Part0.case_003;
        pub const case_004 = Part0.case_004;
        pub const case_005 = Part0.case_005;
        pub const case_006 = Part0.case_006;
        pub const case_007 = Part0.case_007;
        pub const case_008 = Part0.case_008;
        const Part1 = @import("threaded_tasks_test_part_2.zig").Suite(scope);
        pub const case_009 = Part1.case_009;
        pub const case_010 = Part1.case_010;

        pub fn case_011() !void {
            var queue = scope.ThreadedTaskQueue.init(scope.std.testing.io, scope.std.testing.allocator, 1);
            try scope.std.testing.expectEqual(@as(usize, 0), queue.workerCount());
            try scope.std.testing.expect(!queue.running);
            queue.drainCompleted(scope.std.math.maxInt(u64));
            queue.deinit();
        }

        pub fn case_012() !void {
            const Context = struct {
                worked: bool = false,
                cleaned: usize = 0,

                fn work(raw: *anyopaque) void {
                    const ctx: *@This() = @ptrCast(@alignCast(raw));
                    ctx.worked = true;
                }

                fn cleanup(raw: *anyopaque) void {
                    const ctx: *@This() = @ptrCast(@alignCast(raw));
                    ctx.cleaned += 1;
                }
            };
            var context: Context = .{};
            var queue = scope.ThreadedTaskQueue.init(scope.std.testing.io, scope.std.testing.allocator, 1);
            try queue.start();
            try queue.enqueue(.{ .work = Context.work, .cleanup = Context.cleanup, .ctx = &context, .kind = .world });
            queue.stop();
            try scope.std.testing.expect(context.worked);
            try scope.std.testing.expect(!queue.running);
            queue.deinit();
            try scope.std.testing.expectEqual(@as(usize, 1), context.cleaned);
        }
    };
}
