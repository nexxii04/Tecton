const std = @import("std");
const enchantment = @import("enchantment.zig");
const EnchantmentInstance = enchantment.EnchantmentInstance;

pub const MAX_ENCHANTMENTS: u8 = 16;

pub const MergeMode = enum {
    replace,
    merge,
    keep_existing,
};

pub const SetResult = enum {
    inserted,
    updated,
    removed,
    unchanged,
    full,
};

pub const EnchantmentStorage = struct {
    entries: [MAX_ENCHANTMENTS]EnchantmentInstance = undefined,
    len: u8 = 0,
    dirty: bool = false,

    pub fn count(self: *const EnchantmentStorage) u8 {
        return self.len;
    }

    pub fn isEmpty(self: *const EnchantmentStorage) bool {
        return self.len == 0;
    }

    pub fn items(self: *const EnchantmentStorage) []const EnchantmentInstance {
        return self.entries[0..self.len];
    }

    pub fn level(self: *const EnchantmentStorage, id: u16) ?u8 {
        for (self.items()) |entry| {
            if (entry.id == id) return entry.level;
        }
        return null;
    }

    pub fn contains(self: *const EnchantmentStorage, id: u16) bool {
        return self.level(id) != null;
    }

    pub fn set(self: *EnchantmentStorage, id: u16, new_level: u8) SetResult {
        if (new_level == 0) {
            return if (self.remove(id)) .removed else .unchanged;
        }

        var index: usize = 0;
        while (index < self.len and self.entries[index].id < id) : (index += 1) {}

        if (index < self.len and self.entries[index].id == id) {
            if (self.entries[index].level == new_level) return .unchanged;
            self.entries[index].level = new_level;
            self.dirty = true;
            return .updated;
        }

        if (self.len == MAX_ENCHANTMENTS) return .full;

        var cursor: usize = self.len;
        while (cursor > index) : (cursor -= 1) {
            self.entries[cursor] = self.entries[cursor - 1];
        }
        self.entries[index] = .{ .id = id, .level = new_level };
        self.len += 1;
        self.dirty = true;
        return .inserted;
    }

    pub fn setMany(self: *EnchantmentStorage, updates: []const EnchantmentInstance, mode: MergeMode) SetResult {
        if (mode == .replace) {
            if (updates.len > MAX_ENCHANTMENTS) return .full;
            var next: EnchantmentStorage = .{};
            for (updates) |item| {
                if (item.level == 0) continue;
                _ = next.set(item.id, item.level);
            }
            const changed = !self.eql(&next);
            if (!changed) return .unchanged;
            self.* = next;
            self.dirty = true;
            return .inserted;
        }

        var result: SetResult = .unchanged;
        for (updates) |item| {
            if (item.level == 0) continue;
            const adjusted = switch (mode) {
                .merge => blk: {
                    const current = self.level(item.id) orelse break :blk item.level;
                    break :blk @max(current, item.level);
                },
                .keep_existing => blk: {
                    if (self.level(item.id) != null) continue;
                    break :blk item.level;
                },
                .replace => item.level,
            };
            switch (self.set(item.id, adjusted)) {
                .unchanged => {},
                .full => return .full,
                else => result = .inserted,
            }
        }
        return result;
    }

    pub fn remove(self: *EnchantmentStorage, id: u16) bool {
        for (self.items(), 0..) |entry, index| {
            if (entry.id != id) continue;
            var cursor: usize = index;
            while (cursor + 1 < self.len) : (cursor += 1) {
                self.entries[cursor] = self.entries[cursor + 1];
            }
            self.len -= 1;
            self.dirty = true;
            return true;
        }
        return false;
    }

    pub fn clear(self: *EnchantmentStorage) void {
        if (self.len == 0) return;
        self.len = 0;
        self.dirty = true;
    }

    pub fn eql(self: *const EnchantmentStorage, other: *const EnchantmentStorage) bool {
        if (self.len != other.len) return false;
        for (self.items(), other.items()) |left, right| {
            if (left.id != right.id or left.level != right.level) return false;
        }
        return true;
    }

    pub fn hash(self: *const EnchantmentStorage) u64 {
        var value: u64 = 0xcbf29ce484222325;
        for (self.items()) |entry| {
            value = fnvStep(value, @as(u8, @truncate(entry.id)));
            value = fnvStep(value, @as(u8, @truncate(entry.id >> 8)));
            value = fnvStep(value, entry.level);
        }
        return value;
    }

    pub fn copyFrom(self: *EnchantmentStorage, other: *const EnchantmentStorage) void {
        self.entries = other.entries;
        self.len = other.len;
        self.dirty = other.dirty;
    }
};

fn fnvStep(state: u64, byte: u8) u64 {
    return (state ^ byte) *% 0x100000001b3;
}

test "set keeps entries ordered by id" {
    var storage: EnchantmentStorage = .{};
    try std.testing.expectEqual(SetResult.inserted, storage.set(17, 3));
    try std.testing.expectEqual(SetResult.inserted, storage.set(9, 5));
    try std.testing.expectEqual(SetResult.inserted, storage.set(26, 1));
    try std.testing.expectEqual(@as(u8, 3), storage.count());
    try std.testing.expectEqual(@as(u16, 9), storage.items()[0].id);
    try std.testing.expectEqual(@as(u16, 17), storage.items()[1].id);
    try std.testing.expectEqual(@as(u16, 26), storage.items()[2].id);
}

test "set updates an existing entry without duplicating it" {
    var storage: EnchantmentStorage = .{};
    _ = storage.set(9, 3);
    try std.testing.expectEqual(SetResult.updated, storage.set(9, 5));
    try std.testing.expectEqual(@as(u8, 1), storage.count());
    try std.testing.expectEqual(@as(u8, 5), storage.level(9).?);
}

test "set with level zero removes the entry" {
    var storage: EnchantmentStorage = .{};
    _ = storage.set(9, 3);
    try std.testing.expectEqual(SetResult.removed, storage.set(9, 0));
    try std.testing.expectEqual(SetResult.unchanged, storage.set(9, 0));
    try std.testing.expect(storage.isEmpty());
}

test "set reports full at the cap without mutating" {
    var storage: EnchantmentStorage = .{};
    var id: u16 = 0;
    while (id < MAX_ENCHANTMENTS) : (id += 1) {
        try std.testing.expectEqual(SetResult.inserted, storage.set(id + 1, 1));
    }
    try std.testing.expectEqual(SetResult.full, storage.set(99, 1));
    try std.testing.expectEqual(@as(u8, MAX_ENCHANTMENTS), storage.count());
    try std.testing.expect(storage.level(99) == null);
}

test "setMany replace is canonical and detects no-op" {
    var storage: EnchantmentStorage = .{};
    const wanted = [_]EnchantmentInstance{
        .{ .id = 26, .level = 1 },
        .{ .id = 9, .level = 5 },
    };
    try std.testing.expectEqual(SetResult.inserted, storage.setMany(&wanted, .replace));
    try std.testing.expectEqual(@as(u16, 9), storage.items()[0].id);
    try std.testing.expectEqual(SetResult.unchanged, storage.setMany(&wanted, .replace));
    try std.testing.expectEqual(SetResult.unchanged, storage.setMany(&wanted, .merge));
}

test "setMany merge keeps the higher level and keep_existing preserves" {
    var storage: EnchantmentStorage = .{};
    _ = storage.set(9, 3);
    try std.testing.expectEqual(SetResult.unchanged, storage.setMany(&.{.{ .id = 9, .level = 2 }}, .merge));
    try std.testing.expectEqual(@as(u8, 3), storage.level(9).?);
    try std.testing.expectEqual(SetResult.inserted, storage.setMany(&.{.{ .id = 9, .level = 5 }}, .merge));
    try std.testing.expectEqual(@as(u8, 5), storage.level(9).?);
    try std.testing.expectEqual(SetResult.unchanged, storage.setMany(&.{.{ .id = 9, .level = 1 }}, .keep_existing));
    try std.testing.expectEqual(@as(u8, 5), storage.level(9).?);
}

test "eql and hash are independent of insertion order" {
    var left: EnchantmentStorage = .{};
    _ = left.set(9, 5);
    _ = left.set(17, 3);
    var right: EnchantmentStorage = .{};
    _ = right.set(17, 3);
    _ = right.set(9, 5);
    try std.testing.expect(left.eql(&right));
    try std.testing.expectEqual(left.hash(), right.hash());
    _ = right.set(9, 4);
    try std.testing.expect(!left.eql(&right));
}

test "clear only marks dirty when there is something to clear" {
    var storage: EnchantmentStorage = .{};
    storage.dirty = false;
    storage.clear();
    try std.testing.expect(!storage.dirty);
    _ = storage.set(9, 1);
    storage.dirty = false;
    storage.clear();
    try std.testing.expect(storage.dirty);
    try std.testing.expectEqual(@as(u8, 0), storage.count());
}
