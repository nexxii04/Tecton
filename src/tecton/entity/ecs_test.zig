const std = @import("std");

pub fn Suite(comptime EcsWorld: type) type {
    return struct {
        pub fn case_000() !void {
            var ecs = try EcsWorld.init(std.testing.allocator, 2);
            defer ecs.deinit();
            const first = try ecs.create(1);
            try std.testing.expect(ecs.isAlive(first));
            try std.testing.expect(ecs.destroy(first));
            const second = try ecs.create(1);
            try std.testing.expect(first.index == second.index);
            try std.testing.expect(first.generation != second.generation);
            try std.testing.expect(!ecs.isAlive(first));
            try std.testing.expect(ecs.isAlive(second));
        }

        pub fn case_001() !void {
            var ecs = try EcsWorld.init(std.testing.allocator, 4);
            defer ecs.deinit();
            const first = try ecs.create(1);
            const second = try ecs.create(1);
            try ecs.transforms.add(first, .{ .position = .zero(), .rotation = .zero(), .velocity = .zero() });
            try ecs.transforms.add(second, .{ .position = .{ .x = 2, .y = 0, .z = 0 }, .rotation = .zero(), .velocity = .zero() });
            ecs.transforms.remove(first);
            try std.testing.expect(ecs.transforms.get(second) != null);
            try std.testing.expectEqual(@as(f32, 2), ecs.transforms.get(second).?.position.x);
        }

        pub fn case_002() !void {
            var ecs = try EcsWorld.init(std.testing.allocator, 1000);
            defer ecs.deinit();
            for (0..1000) |index| {
                const id = try ecs.create(1);
                try ecs.transforms.add(id, .{ .position = .{ .x = @floatFromInt(index), .y = 64, .z = 0 }, .rotation = .zero(), .velocity = .{ .x = 0.1, .y = 0, .z = 0 } });
                try ecs.physics.add(id, .{ .enabled = index < 250 });
                try ecs.metadata.add(id, .{});
            }
            const transform_capacity = ecs.transforms.dense_ids.len;
            ecs.tick();
            try std.testing.expectEqual(transform_capacity, ecs.transforms.dense_ids.len);
            try std.testing.expect(ecs.transforms.dense_values[0].position.x > 0);
        }
    };
}
