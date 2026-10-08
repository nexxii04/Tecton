pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const sweepUnseenPlayers = scope.sweepUnseenPlayers;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            var rng = std.Random.DefaultPrng.init(0x5eed1234);
            const random = rng.random();

            var map = std.AutoHashMap(i64, u32).init(allocator);
            defer map.deinit();
            var linear = std.AutoHashMap(i64, void).init(allocator);
            defer linear.deinit();
            var scratch = std.ArrayList(i64).empty;
            defer scratch.deinit(allocator);
            var live = std.ArrayList(i64).empty;
            defer live.deinit(allocator);
            var stale = std.ArrayList(i64).empty;
            defer stale.deinit(allocator);

            const bernoulli = struct {
                fn f(r: std.Random) bool {
                    return r.uintLessThan(u64, 2) == 1;
                }
            }.f;

            for (0..1000) |_| {
                map.clearRetainingCapacity();
                linear.clearRetainingCapacity();
                live.clearRetainingCapacity();

                const universe: i64 = random.intRangeAtMost(i64, 0, 40);
                const epoch: u32 = random.intRangeAtMost(u32, 1, 1000);

                var id: i64 = 0;
                while (id < universe) : (id += 1) {
                    if (bernoulli(random)) {
                        try map.put(id, epoch -% 1);
                        try linear.put(id, {});
                    }
                    if (bernoulli(random)) try live.append(allocator, id);
                }

                for (live.items) |l| {
                    if (map.getPtr(l)) |p| p.* = epoch;
                }
                _ = try sweepUnseenPlayers(&map, epoch, &scratch, allocator);

                stale.clearRetainingCapacity();
                var it = linear.keyIterator();
                while (it.next()) |rid| {
                    var found = false;
                    for (live.items) |l| {
                        if (l == rid.*) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try stale.append(allocator, rid.*);
                }
                for (stale.items) |rid| _ = linear.remove(rid);

                try std.testing.expectEqual(linear.count(), map.count());
                var check = map.keyIterator();
                while (check.next()) |rid| {
                    try std.testing.expect(linear.contains(rid.*));
                }
            }
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            var map = std.AutoHashMap(i64, u32).init(allocator);
            defer map.deinit();
            var scratch = std.ArrayList(i64).empty;
            defer scratch.deinit(allocator);

            try map.put(1, std.math.maxInt(u32));
            try map.put(2, std.math.maxInt(u32));
            try map.put(3, 7);

            const previous: u32 = std.math.maxInt(u32);
            const epoch = previous +% 1;
            try std.testing.expectEqual(@as(u32, 0), epoch);

            inline for (.{ 1, 2 }) |l| {
                map.getPtr(l).?.* = epoch;
            }

            const removed = try sweepUnseenPlayers(&map, epoch, &scratch, allocator);
            try std.testing.expectEqual(@as(usize, 1), removed);
            try std.testing.expectEqual(@as(usize, 2), map.count());
            try std.testing.expect(map.contains(1));
            try std.testing.expect(map.contains(2));
            try std.testing.expect(!map.contains(3));
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var map = std.AutoHashMap(i64, u32).init(allocator);
            defer map.deinit();
            var scratch = std.ArrayList(i64).empty;
            defer scratch.deinit(allocator);

            try map.put(1, 0);
            try map.put(2, 0);
            try map.put(3, 0);

            try std.testing.expectEqual(@as(usize, 3), try sweepUnseenPlayers(&map, 1, &scratch, allocator));
            try std.testing.expectEqual(@as(usize, 0), map.count());
            const capacity_after_first = scratch.capacity;
            try std.testing.expect(capacity_after_first >= 3);

            try map.put(9, 0);
            try map.put(10, 0);
            try std.testing.expectEqual(@as(usize, 2), try sweepUnseenPlayers(&map, 1, &scratch, allocator));
            try std.testing.expectEqual(capacity_after_first, scratch.capacity);
            try std.testing.expectEqual(@as(usize, 0), map.count());
        }
    };
}
