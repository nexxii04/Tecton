pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const releaseCachedPackets = scope.releaseCachedPackets;

        pub fn case_000() !void {
            var rng = std.Random.DefaultPrng.init(0xabcd1234);
            const random = rng.random();

            for (0..100) |_| {
                const cx = random.intRangeAtMost(i32, -1000, 1000);
                const cz = random.intRangeAtMost(i32, -1000, 1000);
                const px = random.intRangeAtMost(i32, -1000, 1000);
                const pz = random.intRangeAtMost(i32, -1000, 1000);
                const sim_dist = random.intRangeAtMost(i32, 1, 16);

                const dx = cx - px;
                const dz = cz - pz;
                const in_simulation = dx * dx + dz * dz <= sim_dist * sim_dist;

                const dx_f: f64 = @floatFromInt(dx);
                const dz_f: f64 = @floatFromInt(dz);
                const sd_f: f64 = @floatFromInt(sim_dist);
                const expected = (dx_f * dx_f + dz_f * dz_f) <= (sd_f * sd_f);

                try std.testing.expectEqual(expected, in_simulation);
            }
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;

            var cached = [_][]const u8{ &.{}, &.{}, &.{} };
            cached[0] = try allocator.dupe(u8, "cached-0");
            cached[2] = try allocator.dupe(u8, "cached-2");

            releaseCachedPackets(allocator, &cached);
        }
    };
}
