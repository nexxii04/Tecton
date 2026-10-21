const std = @import("std");
const Raknet = @import("Raknet");

pub const InboundRing = struct {
    pub const overflow_slot_size: usize = 1024 * 1024;
    const overflow_slots: usize = 2;
    const SlotState = enum(u8) { free, filled, taken };

    pub const Entry = struct {
        state: std.atomic.Value(u8) = .init(@intFromEnum(SlotState.free)),
        conn: *Raknet.Connection = undefined,
        generation: u64 = 0,
        len: u32 = 0,

        heap: ?[]u8 = null,
    };

    pub const Popped = struct {
        slot: u32,
        entry: *Entry,

        heap: ?[]u8,
    };

    allocator: std.mem.Allocator,
    slab: []u8,
    overflow_slab: []u8,
    overflow_free: std.atomic.Value(u8) = .init((1 << overflow_slots) - 1),
    entries: []Entry,
    slot_size: usize,
    mask: usize,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    dropped_full: std.atomic.Value(usize) = .init(0),
    oversize_count: std.atomic.Value(usize) = .init(0),

    pub fn create(allocator: std.mem.Allocator, slots: usize, slot_size: usize) !*InboundRing {
        if (slots == 0 or !std.math.isPowerOfTwo(slots) or slots > std.math.maxInt(u32)) return error.InvalidRingSize;
        if (slot_size == 0 or slot_size > std.math.maxInt(u32)) return error.InvalidSlotSize;
        const slab_bytes = std.math.mul(usize, slots, slot_size) catch return error.InvalidRingSize;

        const self = try allocator.create(InboundRing);
        errdefer allocator.destroy(self);

        const entries = try allocator.alloc(Entry, slots);
        errdefer allocator.free(entries);
        for (entries) |*entry| entry.* = .{};

        const slab = try allocator.alloc(u8, slab_bytes);
        errdefer allocator.free(slab);
        const overflow_slab = try allocator.alloc(u8, overflow_slots * overflow_slot_size);

        self.* = .{
            .allocator = allocator,
            .slab = slab,
            .overflow_slab = overflow_slab,
            .entries = entries,
            .slot_size = slot_size,
            .mask = slots - 1,
        };
        return self;
    }

    pub fn deinit(self: *InboundRing) void {
        const allocator = self.allocator;
        allocator.free(self.overflow_slab);
        allocator.free(self.slab);
        allocator.free(self.entries);
        allocator.destroy(self);
    }

    pub fn capacity(self: *const InboundRing) usize {
        return self.entries.len;
    }

    pub fn depth(self: *const InboundRing) usize {
        const tail = self.tail.load(.acquire);
        return @min(self.entries.len, self.head.load(.acquire) -% tail);
    }

    pub fn publish(
        self: *InboundRing,
        conn: *Raknet.Connection,
        generation: u64,
        payload: []const u8,
    ) ?bool {
        const head = self.head.load(.acquire);
        const slot: usize = head & self.mask;
        const entry = &self.entries[slot];

        if (entry.state.load(.acquire) != @intFromEnum(SlotState.free)) {
            _ = self.dropped_full.fetchAdd(1, .monotonic);
            return null;
        }

        var heap: ?[]u8 = null;
        if (payload.len <= self.slot_size) {
            @memcpy(self.slab[slot * self.slot_size ..][0..payload.len], payload);
        } else {
            _ = self.oversize_count.fetchAdd(1, .monotonic);
            heap = self.acquireOverflow(payload.len) orelse {
                _ = self.dropped_full.fetchAdd(1, .monotonic);
                return null;
            };
            @memcpy(heap.?, payload);
        }

        entry.conn = conn;
        entry.generation = generation;
        entry.len = @intCast(payload.len);
        entry.heap = heap;
        entry.state.store(@intFromEnum(SlotState.filled), .release);
        self.head.store(head +% 1, .release);
        return heap != null;
    }

    pub fn pop(self: *InboundRing) ?Popped {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.monotonic);
        if (head == tail) return null;

        const slot: usize = tail & self.mask;
        const entry = &self.entries[slot];
        std.debug.assert(entry.state.load(.acquire) == @intFromEnum(SlotState.filled));

        const heap = entry.heap;
        entry.heap = null;
        entry.state.store(@intFromEnum(SlotState.taken), .release);
        self.tail.store(tail +% 1, .release);

        return .{ .slot = @intCast(slot), .entry = entry, .heap = heap };
    }

    pub fn release(self: *InboundRing, slot: u32) void {
        const entry = &self.entries[slot];
        if (entry.heap) |heap| {
            self.releaseOverflow(heap);
            entry.heap = null;
        }
        entry.state.store(@intFromEnum(SlotState.free), .release);
    }

    fn acquireOverflow(self: *InboundRing, len: usize) ?[]u8 {
        if (len > overflow_slot_size) return null;
        var free = self.overflow_free.load(.acquire);
        while (free != 0) {
            const slot: u3 = @intCast(@ctz(free));
            const bit = @as(u8, 1) << slot;
            if (self.overflow_free.cmpxchgWeak(free, free & ~bit, .acq_rel, .acquire)) |actual| {
                free = actual;
                continue;
            }
            return self.overflow_slab[@as(usize, slot) * overflow_slot_size ..][0..len];
        }
        return null;
    }

    pub fn releaseOverflow(self: *InboundRing, payload: []const u8) void {
        const base = @intFromPtr(self.overflow_slab.ptr);
        const addr = @intFromPtr(payload.ptr);
        std.debug.assert(addr >= base);
        const offset = addr - base;
        std.debug.assert(offset % overflow_slot_size == 0);
        const slot = offset / overflow_slot_size;
        std.debug.assert(slot < overflow_slots);
        const bit = @as(u8, 1) << @as(u3, @intCast(slot));
        const previous = self.overflow_free.fetchOr(bit, .release);
        std.debug.assert(previous & bit == 0);
    }

    pub fn discard(self: *InboundRing, popped: Popped) void {
        if (popped.heap) |heap| {
            self.releaseOverflow(heap);
            popped.entry.heap = null;
        }
        self.release(popped.slot);
    }
};

const testing = std.testing;

fn testConnection(storage: *u128) *Raknet.Connection {
    return @ptrCast(@alignCast(storage));
}

test "ring round-trips payloads in publish order" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 64);
    defer ring.deinit();

    var conn_storage: [2]u128 align(16) = .{ 0, 0 };
    const first = testConnection(&conn_storage[0]);
    const second = testConnection(&conn_storage[1]);

    var payload_a = [_]u8{1} ** 32;
    var payload_b = [_]u8{2} ** 8;
    try testing.expectEqual(false, ring.publish(first, 7, &payload_a).?);
    try testing.expectEqual(false, ring.publish(second, 9, &payload_b).?);
    try testing.expectEqual(@as(usize, 2), ring.depth());

    const a = ring.pop().?;
    try testing.expectEqual(@as(u32, 0), a.slot);
    try testing.expectEqual(first, a.entry.conn);
    try testing.expectEqual(@as(u64, 7), a.entry.generation);
    try testing.expectEqualSlices(u8, &payload_a, ring.slab[a.slot * ring.slot_size ..][0..a.entry.len]);
    ring.discard(a);

    const b = ring.pop().?;
    try testing.expectEqual(@as(u32, 1), b.slot);
    try testing.expectEqual(second, b.entry.conn);
    try testing.expectEqualSlices(u8, &payload_b, ring.slab[b.slot * ring.slot_size ..][0..b.entry.len]);
    ring.discard(b);

    try testing.expect(ring.pop() == null);
    try testing.expectEqual(@as(usize, 0), ring.depth());
}

test "a full ring drops instead of allocating and recovers after release" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 32);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0xAB} ** 16;

    for (0..4) |i| {
        try testing.expectEqual(false, ring.publish(conn, @intCast(i), &payload).?);
    }
    try testing.expectEqual(@as(?bool, null), ring.publish(conn, 4, &payload));
    try testing.expectEqual(@as(usize, 1), ring.dropped_full.load(.monotonic));
    try testing.expectEqual(@as(usize, 4), ring.depth());

    const popped = ring.pop().?;
    ring.release(popped.slot);
    try testing.expectEqual(false, ring.publish(conn, 4, &payload).?);
    try testing.expectEqual(@as(usize, 4), ring.depth());
}

test "oversize payloads use reserved overflow slots and are recycled on discard" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 16);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0x5A} ** 48;

    try testing.expectEqual(true, ring.publish(conn, 1, &payload).?);
    try testing.expectEqual(@as(usize, 1), ring.oversize_count.load(.monotonic));

    const popped = ring.pop().?;
    try testing.expectEqualSlices(u8, &payload, popped.heap.?);
    ring.discard(popped);
    try testing.expect(ring.pop() == null);
}

test "release recycles an overflow payload still owned by the descriptor" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 16);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0x11} ** 64;

    _ = ring.publish(conn, 1, &payload);
    const popped = ring.pop().?;
    popped.entry.heap = popped.heap;
    ring.release(popped.slot);
    try testing.expect(ring.pop() == null);
}

fn exerciseRingInit(allocator: std.mem.Allocator) !void {
    const ring = try InboundRing.create(allocator, 4, 64);
    defer ring.deinit();
}

test "ring construction unwinds every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseRingInit, .{});
}

test "overflow exhaustion is bounded and does not allocate" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const ring = try InboundRing.create(failing.allocator(), 4, 16);
    defer ring.deinit();
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0x77} ** 128;
    for (0..InboundRing.overflow_slots) |_| try testing.expectEqual(true, ring.publish(conn, 1, &payload).?);
    try testing.expect(ring.publish(conn, 1, &payload) == null);
    ring.discard(ring.pop().?);
    try testing.expectEqual(true, ring.publish(conn, 1, &payload).?);
    while (ring.pop()) |popped| ring.discard(popped);
    const large = try testing.allocator.alloc(u8, InboundRing.overflow_slot_size + 1);
    defer testing.allocator.free(large);
    try testing.expect(ring.publish(conn, 1, large) == null);
    try testing.expectEqual(@as(usize, 0), ring.depth());
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}

test "slots are recycled strictly in publish order after wrap" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 2, 8);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);

    var payload = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    for (0..6) |i| {
        payload[0] = @intCast(i);
        _ = ring.publish(conn, i, &payload);
        const popped = ring.pop().?;
        try testing.expectEqual(popped.entry.generation, @as(u64, @intCast(i)));
        ring.release(popped.slot);
    }
}
