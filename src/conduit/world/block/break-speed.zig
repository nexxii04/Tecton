const std = @import("std");

const Protocol = @import("protocol");

/// Per-block break rates for the crack animation, the client
/// registers a block cracking animation
/// when it receives LevelEvent 3600 and advances it at data/65535 progress per
/// tick, so the data value must be the real break rate, never the
/// instant-break maximum (65535) or the animation completes invisibly.
pub const BreakSpeed = struct {
    var table: ?std.StringHashMapUnmanaged(f32) = null;
    var table_allocator: ?std.mem.Allocator = null;

    pub fn init(allocator: std.mem.Allocator) !void {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            Protocol.Data.block_metadata_json,
            .{},
        );
        defer parsed.deinit();

        const entries = if (parsed.value == .array) parsed.value.array.items else return error.InvalidJsonFormat;

        var map = std.StringHashMapUnmanaged(f32){};
        errdefer map.deinit(allocator);

        for (entries) |entry| {
            const object = switch (entry) {
                .object => |o| o,
                else => continue,
            };
            const identifier = object.get("identifier") orelse continue;
            const hardness = object.get("hardness") orelse continue;
            if (identifier != .string) continue;
            const value = switch (hardness) {
                .float => |f| @as(f32, @floatCast(f)),
                .integer => |i| @as(f32, @floatFromInt(i)),
                else => continue,
            };
            try map.put(allocator, try allocator.dupe(u8, identifier.string), value);
        }

        table = map;
        table_allocator = allocator;
    }

    pub fn deinit() void {
        if (table) |*map| {
            const allocator = table_allocator.?;
            var iter = map.keyIterator();
            while (iter.next()) |key| allocator.free(key.*);
            map.deinit(allocator);
        }
        table = null;
        table_allocator = null;
    }

    pub fn hardnessFor(identifier: []const u8) ?f32 {
        const map = &(table orelse return null);
        return map.get(identifier);
    }

    pub fn progressPerTick(hardness: f32) f32 {
        if (hardness <= 0) return 1.0;
        return 1.0 / (hardness * 1.5 * 20.0);
    }

    /// Wire value of LevelEvent 3600/3602 for the given per-tick progress.
    pub fn eventData(progress: f32) i32 {
        const clamped = @min(@max(progress, 1.0 / 65535.0), 1.0);
        return @intFromFloat(clamped * 65535.0);
    }

    pub fn startBreakData(identifier: []const u8) ?i32 {
        const hardness = hardnessFor(identifier) orelse 1.0;
        if (hardness <= 0) return null;
        return eventData(progressPerTick(hardness));
    }
};

const testing = std.testing;

test "progress per tick matches pmmp's break-time formula" {
    try testing.expectEqual(@as(f32, 1.0), BreakSpeed.progressPerTick(0));
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 45.0), BreakSpeed.progressPerTick(1.5), 0.000001);
}

test "event data is the 65535-scaled per-tick progress" {
    try testing.expectEqual(@as(i32, 1456), BreakSpeed.eventData(BreakSpeed.progressPerTick(1.5)));
    try testing.expectEqual(@as(i32, 65535), BreakSpeed.eventData(1.0));
}

test "hardness table loads from embedded block metadata" {
    try BreakSpeed.init(testing.allocator);
    defer BreakSpeed.deinit();

    try testing.expectEqual(@as(?f32, 1.5), BreakSpeed.hardnessFor("minecraft:stone"));
    // Unknown identifiers fall back to a plain breakable block.
    try testing.expectEqual(@as(?f32, null), BreakSpeed.hardnessFor("minecraft:not_a_real_block"));
    try testing.expect(BreakSpeed.startBreakData("minecraft:not_a_real_block") != null);
    try testing.expect(BreakSpeed.startBreakData("minecraft:stone") != null);
}

test "unbreakable and instant blocks request no start event" {
    try BreakSpeed.init(testing.allocator);
    defer BreakSpeed.deinit();

    try testing.expectEqual(@as(?i32, null), BreakSpeed.startBreakData("minecraft:bedrock"));
    try testing.expectEqual(@as(?i32, null), BreakSpeed.startBreakData("minecraft:torch"));
}
