const std = @import("std");

const Protocol = @import("protocol");

const block_pos = @import("./block-pos.zig");

pub const TickScheduler = struct {
    const RING_SIZE: usize = 200;

    const TickKey = struct {
        pos_hash: i64,
        block_hash: u64,
    };

    const ScheduledTick = struct {
        pos: Protocol.BlockPosition,
        block_hash: u64,
    };

    ring: [RING_SIZE]std.ArrayList(ScheduledTick),
    offset: usize,
    queued: std.AutoHashMap(TickKey, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TickScheduler {
        var sched: TickScheduler = .{
            .ring = undefined,
            .offset = 0,
            .queued = std.AutoHashMap(TickKey, void).init(allocator),
            .allocator = allocator,
        };
        for (&sched.ring) |*slot| {
            slot.* = std.ArrayList(ScheduledTick){ .items = &.{}, .capacity = 0 };
        }
        return sched;
    }

    pub fn deinit(self: *TickScheduler) void {
        for (&self.ring) |*slot| {
            slot.deinit(self.allocator);
        }
        self.queued.deinit();
    }

    pub fn schedule(self: *TickScheduler, pos: Protocol.BlockPosition, block_hash: u64, delay: usize) void {
        if (delay == 0 or delay >= RING_SIZE) return;
        const key = TickKey{ .pos_hash = block_pos.blockPosHash(pos), .block_hash = block_hash };
        if (self.queued.contains(key)) return;
        self.queued.put(key, {}) catch return;
        const slot_idx = (self.offset + delay - 1) % RING_SIZE;
        self.ring[slot_idx].append(self.allocator, .{ .pos = pos, .block_hash = block_hash }) catch {
            _ = self.queued.remove(key);
            return;
        };
    }

    pub fn stepTick(self: *TickScheduler) []const ScheduledTick {
        const slot = &self.ring[self.offset];
        for (slot.items) |tick| {
            const key = TickKey{ .pos_hash = block_pos.blockPosHash(tick.pos), .block_hash = tick.block_hash };
            _ = self.queued.remove(key);
        }
        const result = slot.items;
        self.offset = (self.offset + 1) % RING_SIZE;
        return result;
    }

    pub fn clearCurrentSlot(self: *TickScheduler) void {
        const prev = if (self.offset == 0) RING_SIZE - 1 else self.offset - 1;
        self.ring[prev].clearRetainingCapacity();
    }
};

test "tick scheduler delivers at correct delay" {
    var sched = TickScheduler.init(std.testing.allocator);
    defer sched.deinit();

    var rng = std.Random.DefaultPrng.init(0xaabb1122);
    const random = rng.random();

    for (0..100) |_| {
        const delay = random.intRangeAtMost(usize, 1, TickScheduler.RING_SIZE - 1);
        const pos = Protocol.BlockPosition{
            .x = random.intRangeAtMost(i32, -1000, 1000),
            .y = random.intRangeAtMost(i32, 0, 255),
            .z = random.intRangeAtMost(i32, -1000, 1000),
        };
        const block_hash = random.int(u64);

        sched.schedule(pos, block_hash, delay);

        for (0..delay - 1) |_| {
            const ticks = sched.stepTick();
            // Read before clearCurrentSlot(): it clears the same list.
            for (ticks) |t| {
                try std.testing.expect(t.block_hash != block_hash or
                    block_pos.blockPosHash(t.pos) != block_pos.blockPosHash(pos));
            }
            sched.clearCurrentSlot();
        }

        const delivered = sched.stepTick();
        var found = false;
        for (delivered) |t| {
            if (t.block_hash == block_hash and block_pos.blockPosHash(t.pos) == block_pos.blockPosHash(pos)) {
                found = true;
                break;
            }
        }
        sched.clearCurrentSlot();
        try std.testing.expect(found);
    }
}

test "tick scheduler rejects duplicates" {
    var sched = TickScheduler.init(std.testing.allocator);
    defer sched.deinit();

    var rng = std.Random.DefaultPrng.init(0xccdd3344);
    const random = rng.random();

    for (0..100) |_| {
        const delay = random.intRangeAtMost(usize, 1, 50);
        const pos = Protocol.BlockPosition{
            .x = random.intRangeAtMost(i32, -100, 100),
            .y = random.intRangeAtMost(i32, 0, 255),
            .z = random.intRangeAtMost(i32, -100, 100),
        };
        const block_hash = random.int(u64);

        sched.schedule(pos, block_hash, delay);
        sched.schedule(pos, block_hash, delay);

        for (0..delay) |_| {
            _ = sched.stepTick();
            sched.clearCurrentSlot();
        }

        try std.testing.expect(!sched.queued.contains(.{
            .pos_hash = block_pos.blockPosHash(pos),
            .block_hash = block_hash,
        }));
    }
}

test "tick scheduler delay one fires on next step" {
    var sched = TickScheduler.init(std.testing.allocator);
    defer sched.deinit();

    const pos = Protocol.BlockPosition{ .x = 3, .y = 64, .z = -9 };
    const block_hash: u64 = 0x1234;

    sched.schedule(pos, block_hash, 1);

    const delivered = sched.stepTick();
    defer sched.clearCurrentSlot();

    try std.testing.expectEqual(@as(usize, 1), delivered.len);
    try std.testing.expectEqual(block_hash, delivered[0].block_hash);
    try std.testing.expectEqual(block_pos.blockPosHash(pos), block_pos.blockPosHash(delivered[0].pos));
}
