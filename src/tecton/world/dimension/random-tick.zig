const std = @import("std");

const Protocol = @import("protocol");

const BlockPermutation = @import("../block/block-permutation.zig").BlockPermutation;
const BlockState = @import("../block/block-permutation.zig").BlockState;

pub const RandomTickEligibility = struct {
    eligible: []bool,
    allocator: std.mem.Allocator,
    max_id: usize,

    pub fn init(allocator: std.mem.Allocator, eligible_identifiers: []const []const u8) !RandomTickEligibility {
        var max_id: usize = 0;
        var iter = BlockPermutation.valueIterator();
        while (iter.next()) |perm| {
            const nid: usize = @intCast(@as(u32, @bitCast(perm.*.network_id)));
            if (nid > max_id) max_id = nid;
        }

        const table = try allocator.alloc(bool, max_id + 1);
        @memset(table, false);

        iter = BlockPermutation.valueIterator();
        while (iter.next()) |perm| {
            const nid: usize = @intCast(@as(u32, @bitCast(perm.*.network_id)));
            for (eligible_identifiers) |eid| {
                if (std.mem.eql(u8, perm.*.identifier, eid)) {
                    table[nid] = true;
                    break;
                }
            }
        }

        return .{ .eligible = table, .allocator = allocator, .max_id = max_id };
    }

    pub fn deinit(self: *RandomTickEligibility) void {
        self.allocator.free(self.eligible);
    }

    pub fn isEligible(self: *const RandomTickEligibility, network_id: i32) bool {
        const idx: usize = @intCast(@as(u32, @bitCast(network_id)));
        if (idx > self.max_id) return false;
        return self.eligible[idx];
    }
};

pub fn isChunkInSimRange(cx: i32, cz: i32, px: i32, pz: i32, sim_dist: i32) bool {
    const dx = cx - px;
    const dz = cz - pz;
    return dx * dx + dz * dz <= sim_dist * sim_dist;
}

test "random tick spatial filtering" {
    var rng = std.Random.DefaultPrng.init(0xdead5678);
    const random = rng.random();

    for (0..100) |_| {
        const px = random.intRangeAtMost(i32, -100, 100);
        const pz = random.intRangeAtMost(i32, -100, 100);
        const sim_dist = random.intRangeAtMost(i32, 1, 8);

        const in_cx = px + random.intRangeAtMost(i32, 0, sim_dist);
        const in_cz = pz;
        const out_cx = px + sim_dist + random.intRangeAtMost(i32, 1, 10);
        const out_cz = pz + sim_dist + random.intRangeAtMost(i32, 1, 10);

        const in_dx = in_cx - px;
        const in_dz = in_cz - pz;
        if (in_dx * in_dx + in_dz * in_dz <= sim_dist * sim_dist) {
            try std.testing.expect(isChunkInSimRange(in_cx, in_cz, px, pz, sim_dist));
        }

        try std.testing.expect(!isChunkInSimRange(out_cx, out_cz, px, pz, sim_dist));
    }
}

test "random tick eligibility lookup" {
    const allocator = std.testing.allocator;
    try BlockPermutation.initRegistry(allocator);
    defer BlockPermutation.deinitRegistry();

    const state1 = BlockState.init(allocator);
    const perm1 = try BlockPermutation.init(allocator, 1, "minecraft:grass_block", state1);
    try perm1.register();

    const state2 = BlockState.init(allocator);
    const perm2 = try BlockPermutation.init(allocator, 2, "minecraft:stone", state2);
    try perm2.register();

    const state3 = BlockState.init(allocator);
    const perm3 = try BlockPermutation.init(allocator, 3, "minecraft:wheat", state3);
    try perm3.register();

    const eligible_ids = [_][]const u8{ "minecraft:grass_block", "minecraft:wheat" };
    var rte = try RandomTickEligibility.init(allocator, &eligible_ids);
    defer rte.deinit();

    try std.testing.expect(rte.isEligible(1));
    try std.testing.expect(!rte.isEligible(2));
    try std.testing.expect(rte.isEligible(3));
    try std.testing.expect(!rte.isEligible(999));
}
