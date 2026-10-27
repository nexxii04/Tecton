const std = @import("std");

/// Scratch space for the outbound path: one frame is compressed into a slot and handed to
/// the port, so a tick never allocates. A slot is held only for the copy and the delivery.
pub const SendBuffers = struct {
    pub const default_slot_size: usize = 64 * 1024;
    pub const default_slot_count: usize = 8;

    /// A slot is claimed with a compare-and-swap, so several workers can send at once
    /// without a lock on the hot path.
    const Slot = struct {
        in_use: std.atomic.Value(bool) = .init(false),
    };

    /// A handler that never sends (a stub) starts here instead of at `undefined`.
    pub const empty: SendBuffers = .{
        .parent = undefined,
        .region = &.{},
        .slots = &.{},
        .slot_size = 0,
    };

    parent: std.mem.Allocator,
    region: []align(64) u8,
    slots: []Slot,
    slot_size: usize,
    cursor: std.atomic.Value(usize) = .init(0),

    pub fn init(parent: std.mem.Allocator, slot_size: usize, slot_count: usize) !SendBuffers {
        const size = @max(slot_size, 64);
        const count = @max(slot_count, 1);

        const region = try parent.alignedAlloc(u8, .fromByteUnits(64), size * count);
        errdefer parent.free(region);
        const slots = try parent.alloc(Slot, count);
        for (slots) |*slot| slot.* = .{};

        return .{
            .parent = parent,
            .region = region,
            .slots = slots,
            .slot_size = size,
        };
    }

    pub fn deinit(self: *SendBuffers) void {
        const parent = self.parent;
        if (self.region.len > 0) parent.free(self.region);
        if (self.slots.len > 0) parent.free(self.slots);
        self.* = undefined;
    }

    pub fn slotSize(self: *const SendBuffers) usize {
        return self.slot_size;
    }

    pub fn capacity(self: *const SendBuffers) usize {
        return self.slots.len;
    }

    /// How many slots a sender could claim right now.
    pub fn available(self: *const SendBuffers) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (!slot.in_use.load(.acquire)) count += 1;
        }
        return count;
    }

    /// Returns the whole slot, or null when every slot is busy. The caller must `release` it.
    pub fn acquire(self: *SendBuffers) ?[]u8 {
        const count = self.slots.len;
        if (count == 0) return null;
        const start = self.cursor.fetchAdd(1, .monotonic) % count;
        for (0..count) |step| {
            const index = (start + step) % count;
            const slot = &self.slots[index];
            if (slot.in_use.load(.acquire)) continue;
            if (slot.in_use.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) continue;
            return self.region[index * self.slot_size ..][0..self.slot_size];
        }
        return null;
    }

    /// A buffer that did not come from this pool is ignored: a stray release must not free
    /// another sender's slot.
    pub fn release(self: *SendBuffers, buffer: []u8) void {
        if (self.slot_size == 0 or buffer.len != self.slot_size) return;
        const base = @intFromPtr(self.region.ptr);
        const start = @intFromPtr(buffer.ptr);
        if (start < base) return;
        const offset = start - base;
        if (offset >= self.region.len or offset % self.slot_size != 0) return;
        self.slots[offset / self.slot_size].in_use.store(false, .release);
    }
};

const testing = std.testing;

test "slots are handed out once each and come back on release" {
    var buffers = try SendBuffers.init(testing.allocator, 128, 3);
    defer buffers.deinit();

    try testing.expectEqual(@as(usize, 3), buffers.capacity());
    try testing.expectEqual(@as(usize, 128), buffers.slotSize());
    try testing.expectEqual(@as(usize, 3), buffers.available());

    const first = buffers.acquire().?;
    const second = buffers.acquire().?;
    const third = buffers.acquire().?;
    try testing.expect(buffers.acquire() == null);
    try testing.expectEqual(@as(usize, 0), buffers.available());
    try testing.expect(first.ptr != second.ptr and second.ptr != third.ptr and first.ptr != third.ptr);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % 64);

    buffers.release(second);
    try testing.expectEqual(@as(usize, 1), buffers.available());
    const again = buffers.acquire().?;
    try testing.expectEqual(second.ptr, again.ptr);

    buffers.release(first);
    buffers.release(again);
    buffers.release(third);
    try testing.expectEqual(@as(usize, 3), buffers.available());
}

test "a buffer from outside the pool does not disturb the accounting" {
    var buffers = try SendBuffers.init(testing.allocator, 64, 2);
    defer buffers.deinit();

    var outside: [64]u8 = undefined;
    const held = buffers.acquire().?;
    buffers.release(&outside);
    buffers.release(&outside);
    try testing.expectEqual(@as(usize, 1), buffers.available());
    buffers.release(held);
    try testing.expectEqual(@as(usize, 2), buffers.available());
}

test "an exhausted pool reports backpressure instead of growing" {
    var buffers = try SendBuffers.init(testing.allocator, 64, 2);
    defer buffers.deinit();

    const first = buffers.acquire().?;
    defer buffers.release(first);
    const second = buffers.acquire().?;
    defer buffers.release(second);

    for (0..4) |_| try testing.expect(buffers.acquire() == null);
    try testing.expectEqual(@as(usize, 2 * 64), buffers.region.len);
}
