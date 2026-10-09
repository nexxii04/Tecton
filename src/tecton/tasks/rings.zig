const std = @import("std");

pub fn SpscRing(comptime T: type) type {
    return struct {
        const Self = @This();

        slots: []T = &.{},
        mask: usize = 0,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const size = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(T, size);
            return .{ .slots = slots, .mask = size - 1 };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.slots.len > 0) allocator.free(self.slots);
            self.slots = &.{};
        }

        pub fn empty(self: *const Self) bool {
            return self.tail.load(.acquire) == self.head.load(.acquire);
        }

        pub fn push(self: *Self, item: T) bool {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            if (head -% tail >= self.slots.len) return false;
            self.slots[head & self.mask] = item;
            self.head.store(head +% 1, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            const head = self.head.load(.acquire);
            if (tail == head) return null;
            const item = self.slots[tail & self.mask];
            self.tail.store(tail +% 1, .release);
            return item;
        }
    };
}

pub fn MpmcRing(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T = undefined,
        };

        slots: []Slot = &.{},
        mask: usize = 0,
        enqueue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const size = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
            const slots = try allocator.alloc(Slot, size);
            for (slots, 0..) |*slot, i| slot.* = .{ .sequence = std.atomic.Value(usize).init(i) };
            return .{ .slots = slots, .mask = size - 1 };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.slots.len > 0) allocator.free(self.slots);
            self.slots = &.{};
        }

        pub fn push(self: *Self, value: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const sequence = slot.sequence.load(.acquire);
                const diff = sequence -% pos;
                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    slot.value = value;
                    slot.sequence.store(pos +% 1, .release);
                    return true;
                }
                if (@as(isize, @bitCast(diff)) < 0) return false;
                pos = self.enqueue_pos.load(.monotonic);
            }
        }

        pub fn pop(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const sequence = slot.sequence.load(.acquire);
                const diff = sequence -% (pos +% 1);
                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    break;
                }
                if (@as(isize, @bitCast(diff)) < 0) return null;
                pos = self.dequeue_pos.load(.monotonic);
            }
            const value = self.slots[pos & self.mask].value;
            self.slots[pos & self.mask].sequence.store(pos +% self.slots.len, .release);
            return value;
        }
    };
}
