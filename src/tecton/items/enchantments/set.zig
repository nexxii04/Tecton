const std = @import("std");
const storage = @import("storage.zig");
const enchantment = @import("enchantment.zig");

pub const WIDTH: u16 = enchantment.MAX_ENCHANTMENT_ID + 1;
const WORDS: usize = (WIDTH + 63) / 64;

pub const EnchantmentSet = struct {
    words: [WORDS]u64 = @splat(0),

    pub const empty: EnchantmentSet = .{};

    pub fn fromIds(ids: []const u16) EnchantmentSet {
        var set: EnchantmentSet = .{};
        for (ids) |id| set.add(id);
        return set;
    }

    pub fn add(self: *EnchantmentSet, id: u16) void {
        if (id >= WIDTH) return;
        const word = id / 64;
        const bit: u6 = @intCast(id % 64);
        self.words[word] |= @as(u64, 1) << bit;
    }

    pub fn remove(self: *EnchantmentSet, id: u16) void {
        if (id >= WIDTH) return;
        const word = id / 64;
        const bit: u6 = @intCast(id % 64);
        self.words[word] &= ~(@as(u64, 1) << bit);
    }

    pub fn contains(self: *const EnchantmentSet, id: u16) bool {
        if (id >= WIDTH) return false;
        const word = id / 64;
        const bit: u6 = @intCast(id % 64);
        return (self.words[word] & (@as(u64, 1) << bit)) != 0;
    }

    pub fn count(self: *const EnchantmentSet) usize {
        var total: usize = 0;
        for (self.words) |word| total += @popCount(word);
        return total;
    }

    pub fn matches(self: *const EnchantmentSet, enchantments: *const storage.EnchantmentStorage) bool {
        for (enchantments.items()) |entry| {
            if (self.contains(entry.id)) return true;
        }
        return false;
    }
};

test "set membership is exact and ignores out of range ids" {
    const set = EnchantmentSet.fromIds(&.{ 9, 17, 255 });
    try std.testing.expect(set.contains(9));
    try std.testing.expect(set.contains(17));
    try std.testing.expect(set.contains(255));
    try std.testing.expect(!set.contains(10));
    try std.testing.expectEqual(@as(usize, 3), set.count());
    try std.testing.expect(WIDTH == enchantment.MAX_ENCHANTMENT_ID + 1);
}

test "matches reports any enchantment of the set" {
    var enchantments: storage.EnchantmentStorage = .{};
    _ = enchantments.set(26, 1);
    const mending = EnchantmentSet.fromIds(&.{26});
    const sharpness = EnchantmentSet.fromIds(&.{9});
    try std.testing.expect(mending.matches(&enchantments));
    try std.testing.expect(!sharpness.matches(&enchantments));
}
