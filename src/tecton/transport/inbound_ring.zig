const std = @import("std");
const Raknet = @import("Raknet");

pub const InboundRing = struct {
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
    entries: []Entry,
    slot_size: usize,
    mask: usize,
    head: std.atomic.Value(usize) = .init(0),
    tail: usize = 0,
    dropped_full: std.atomic.Value(usize) = .init(0),
    oversize_count: std.atomic.Value(usize) = .init(0),

    pub fn create(allocator: std.mem.Allocator, slots: usize, slot_size: usize) !*InboundRing {
        std.debug.assert(slots > 0 and std.math.isPowerOfTwo(slots));
        std.debug.assert(slot_size > 0);

        const self = try allocator.create(InboundRing);
        errdefer allocator.destroy(self);

        const entries = try allocator.alloc(Entry, slots);
        errdefer allocator.free(entries);
        for (entries, 0..) |*entry, i| {
            entry.* = .{};
            _ = i;
        }

        const slab = try allocator.alloc(u8, slots * slot_size);
        errdefer allocator.free(slab);

        self.* = .{
            .allocator = allocator,
            .slab = slab,
            .entries = entries,
            .slot_size = slot_size,
            .mask = slots - 1,
        };
        return self;
    }

    pub fn deinit(self: *InboundRing) void {
        const allocator = self.allocator;
        for (self.entries) |*entry| {
            if (entry.heap) |heap| allocator.free(heap);
        }
        allocator.free(self.slab);
        allocator.free(self.entries);
        allocator.destroy(self);
    }

    pub fn capacity(self: *const InboundRing) usize {
        return self.entries.len;
    }

    pub fn depth(self: *const InboundRing) usize {
        return self.head.load(.acquire) -% self.tail;
    }

    pub fn publish(
        self: *InboundRing,
        allocator: std.mem.Allocator,
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
            heap = allocator.dupe(u8, payload) catch {
                _ = self.dropped_full.fetchAdd(1, .monotonic);
                return null;
            };
            _ = self.oversize_count.fetchAdd(1, .monotonic);
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
        if (head == self.tail) return null;

        const slot: usize = self.tail & self.mask;
        const entry = &self.entries[slot];
        std.debug.assert(entry.state.load(.acquire) == @intFromEnum(SlotState.filled));

        const heap = entry.heap;
        entry.heap = null;
        entry.state.store(@intFromEnum(SlotState.taken), .release);
        self.tail +%= 1;

        return .{ .slot = @intCast(slot), .entry = entry, .heap = heap };
    }

    pub fn release(self: *InboundRing, slot: u32) void {
        const entry = &self.entries[slot];
        if (entry.heap) |heap| {
            self.allocator.free(heap);
            entry.heap = null;
        }
        entry.state.store(@intFromEnum(SlotState.free), .release);
    }

    pub fn discard(self: *InboundRing, popped: Popped) void {
        if (popped.heap) |heap| self.allocator.free(heap);
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
    try testing.expectEqual(false, ring.publish(allocator, first, 7, &payload_a).?);
    try testing.expectEqual(false, ring.publish(allocator, second, 9, &payload_b).?);
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
        try testing.expectEqual(false, ring.publish(allocator, conn, @intCast(i), &payload).?);
    }
    try testing.expectEqual(@as(?bool, null), ring.publish(allocator, conn, 4, &payload));
    try testing.expectEqual(@as(usize, 1), ring.dropped_full.load(.monotonic));
    try testing.expectEqual(@as(usize, 4), ring.depth());

    const popped = ring.pop().?;
    ring.release(popped.slot);
    try testing.expectEqual(false, ring.publish(allocator, conn, 4, &payload).?);
    try testing.expectEqual(@as(usize, 4), ring.depth());
}

test "oversize payloads fall back to the heap and are freed on discard" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 16);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0x5A} ** 48;

    try testing.expectEqual(true, ring.publish(allocator, conn, 1, &payload).?);
    try testing.expectEqual(@as(usize, 1), ring.oversize_count.load(.monotonic));

    const popped = ring.pop().?;
    try testing.expectEqualSlices(u8, &payload, popped.heap.?);
    ring.discard(popped);
    try testing.expect(ring.pop() == null);
}

test "release frees a heap payload still owned by the descriptor" {
    const allocator = testing.allocator;
    const ring = try InboundRing.create(allocator, 4, 16);
    defer ring.deinit();

    var conn_storage: u128 align(16) = 0;
    const conn = testConnection(&conn_storage);
    const payload = [_]u8{0x11} ** 64;

    _ = ring.publish(allocator, conn, 1, &payload);
    const popped = ring.pop().?;
    popped.entry.heap = popped.heap;
    ring.release(popped.slot);
    try testing.expect(ring.pop() == null);
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
        _ = ring.publish(allocator, conn, i, &payload);
        const popped = ring.pop().?;
        try testing.expectEqual(popped.entry.generation, @as(u64, @intCast(i)));
        ring.release(popped.slot);
    }
}
