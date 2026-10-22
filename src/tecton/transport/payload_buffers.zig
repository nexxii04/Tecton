const std = @import("std");

pub const PayloadBuffers = struct {
    pub const class_sizes = [_]usize{ 64, 1024, 4096, 16384 };
    pub const class_counts = [_]usize{ 128, 32, 16, 8 };

    const Slot = struct {
        class_index: usize,
        slot: u32,
    };

    const Class = struct {
        memory: []align(64) u8 = &.{},
        free_slots: []u32 = &.{},
        in_use: []bool = &.{},
        free_len: usize = 0,
    };

    parent: std.mem.Allocator,
    classes: [class_sizes.len]Class = [_]Class{.{}} ** class_sizes.len,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn init(parent: std.mem.Allocator) PayloadBuffers {
        return .{ .parent = parent };
    }

    pub fn deinit(self: *PayloadBuffers) void {
        const parent = self.parent;
        for (&self.classes) |*class| {
            if (class.memory.len > 0) parent.free(class.memory);
            if (class.free_slots.len > 0) parent.free(class.free_slots);
            if (class.in_use.len > 0) parent.free(class.in_use);
        }
        self.classes = [_]Class{.{}} ** class_sizes.len;
    }

    pub fn allocator(self: *PayloadBuffers) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn available(self: *PayloadBuffers, class_index: usize) usize {
        self.acquire();
        defer self.release();
        return self.classes[class_index].free_len;
    }

    pub fn capacity(self: *PayloadBuffers, class_index: usize) usize {
        self.acquire();
        defer self.release();
        return self.classes[class_index].free_slots.len;
    }

    pub fn mappedBytes(self: *PayloadBuffers) usize {
        self.acquire();
        defer self.release();
        var total: usize = 0;
        for (self.classes) |class| total += class.memory.len;
        return total;
    }

    fn acquire(self: *PayloadBuffers) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *PayloadBuffers) void {
        self.locked.store(false, .release);
    }

    fn classFor(len: usize) ?usize {
        for (class_sizes, 0..) |slot_size, index| {
            if (len <= slot_size) return index;
        }
        return null;
    }

    fn materialize(self: *PayloadBuffers, class_index: usize) bool {
        const class = &self.classes[class_index];
        if (class.memory.len > 0) return true;

        const slot_size = class_sizes[class_index];
        const slot_count = class_counts[class_index];
        const memory = self.parent.alignedAlloc(u8, .fromByteUnits(64), slot_count * slot_size) catch return false;
        const free_slots = self.parent.alloc(u32, slot_count) catch {
            self.parent.free(memory);
            return false;
        };
        const in_use = self.parent.alloc(bool, slot_count) catch {
            self.parent.free(free_slots);
            self.parent.free(memory);
            return false;
        };

        @memset(in_use, false);
        for (free_slots, 0..) |*slot, index| slot.* = @intCast(slot_count - 1 - index);
        class.memory = memory;
        class.free_slots = free_slots;
        class.in_use = in_use;
        class.free_len = slot_count;
        return true;
    }

    fn claim(self: *PayloadBuffers, class_index: usize) ?u32 {
        if (!self.materialize(class_index)) return null;
        const class = &self.classes[class_index];
        if (class.free_len == 0) return null;
        class.free_len -= 1;
        const slot = class.free_slots[class.free_len];
        std.debug.assert(!class.in_use[slot]);
        class.in_use[slot] = true;
        return slot;
    }

    fn give(self: *PayloadBuffers, class_index: usize, slot: u32) void {
        const class = &self.classes[class_index];
        std.debug.assert(class.in_use[slot]);
        std.debug.assert(class.free_len < class.free_slots.len);
        class.in_use[slot] = false;
        class.free_slots[class.free_len] = slot;
        class.free_len += 1;
    }

    fn slotOf(self: *PayloadBuffers, memory: []u8) ?Slot {
        if (memory.len == 0) return null;
        const address = @intFromPtr(memory.ptr);
        for (&self.classes, 0..) |class, class_index| {
            if (class.memory.len == 0) continue;
            const base = @intFromPtr(class.memory.ptr);
            if (address < base or address >= base + class.memory.len) continue;
            const offset = address - base;
            if (offset % class_sizes[class_index] != 0) return null;
            return .{ .class_index = class_index, .slot = @intCast(offset / class_sizes[class_index]) };
        }
        return null;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PayloadBuffers = @ptrCast(@alignCast(context));
        if (len == 0 or alignment.toByteUnits() > 64) {
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
        }
        const class_index = classFor(len) orelse return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);

        self.acquire();
        const slot = self.claim(class_index);
        self.release();
        const claimed = slot orelse return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
        return self.classes[class_index].memory[@as(usize, claimed) * class_sizes[class_index] ..].ptr;
    }

    fn resizeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PayloadBuffers = @ptrCast(@alignCast(context));
        self.acquire();
        const found = self.slotOf(memory);
        self.release();
        const pooled = found orelse {
            return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
        };
        return new_len <= class_sizes[pooled.class_index];
    }

    fn remapFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PayloadBuffers = @ptrCast(@alignCast(context));
        self.acquire();
        const found = self.slotOf(memory);
        self.release();
        const pooled = found orelse {
            return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
        };
        if (new_len > class_sizes[pooled.class_index]) return null;
        return memory.ptr;
    }

    fn freeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PayloadBuffers = @ptrCast(@alignCast(context));

        self.acquire();
        if (self.slotOf(memory)) |found| {
            self.give(found.class_index, found.slot);
            self.release();
            return;
        }
        self.release();

        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

test "a class recycles the same slot in place" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    try std.testing.expectEqual(@as(usize, 0), buffers.mappedBytes());

    const payload = try pool.alloc(u8, 700);
    const mapped = buffers.mappedBytes();
    try std.testing.expectEqual(PayloadBuffers.class_sizes[1] * PayloadBuffers.class_counts[1], mapped);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[1] - 1), buffers.available(1));

    pool.free(payload);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[1]), buffers.available(1));

    const recycled = try pool.alloc(u8, 700);
    defer pool.free(recycled);
    try std.testing.expectEqual(@intFromPtr(payload.ptr), @intFromPtr(recycled.ptr));
    try std.testing.expectEqual(mapped, buffers.mappedBytes());
}

test "the smallest fitting class serves the allocation" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    const exact = try pool.alloc(u8, PayloadBuffers.class_sizes[0]);
    defer pool.free(exact);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[0] - 1), buffers.available(0));
    try std.testing.expectEqual(@as(usize, 0), buffers.capacity(1));

    const next = try pool.alloc(u8, PayloadBuffers.class_sizes[0] + 1);
    defer pool.free(next);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[1] - 1), buffers.available(1));
    try std.testing.expectEqual(@as(usize, 0), buffers.capacity(2));
}

test "exhaustion falls back to the parent and reclaims exactly the pooled slots" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var buffers = PayloadBuffers.init(failing.allocator());
    defer buffers.deinit();

    const pool = buffers.allocator();
    var claimed: [PayloadBuffers.class_counts[2] + 2][]u8 = undefined;
    for (&claimed) |*slice| slice.* = try pool.alloc(u8, PayloadBuffers.class_sizes[2]);
    try std.testing.expectEqual(@as(usize, 0), buffers.available(2));

    const allocations = failing.alloc_index;
    const extra = try pool.alloc(u8, PayloadBuffers.class_sizes[2]);
    try std.testing.expectEqual(allocations + 1, failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), buffers.available(2));

    for (claimed) |slice| pool.free(slice);
    pool.free(extra);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[2]), buffers.available(2));
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[2]), buffers.capacity(2));
}

test "a foreign slice is released through the parent" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    const foreign = try allocator.alloc(u8, 48);
    pool.free(foreign);
    try std.testing.expectEqual(@as(usize, 0), buffers.mappedBytes());
}

test "growth moves a small buffer into a larger class without losing bytes" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    var slice = try pool.alloc(u8, 64);
    for (slice, 0..) |*byte, index| byte.* = @intCast(index);
    const original = @intFromPtr(slice.ptr);

    slice = try pool.realloc(slice, 4096);
    defer pool.free(slice);
    for (0..64) |index| try std.testing.expectEqual(@as(u8, @intCast(index)), slice[index]);
    try std.testing.expect(@intFromPtr(slice.ptr) != original);
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[0]), buffers.available(0));
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[2] - 1), buffers.available(2));
}

test "concurrent claims never alias" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    defer buffers.deinit();

    const Worker = struct {
        fn run(pool: std.mem.Allocator, seen: []std.atomic.Value(usize), duplicates: *std.atomic.Value(usize), start: usize) void {
            for (0..512) |_| {
                const slice = pool.alloc(u8, 700) catch continue;
                const index = (@intFromPtr(slice.ptr) - start) / PayloadBuffers.class_sizes[1];
                if (seen[index].swap(1, .acq_rel) != 0) _ = duplicates.fetchAdd(1, .monotonic);
                seen[index].store(0, .release);
                pool.free(slice);
            }
        }
    };

    const probe = try buffers.allocator().alloc(u8, PayloadBuffers.class_sizes[1]);
    const start = @intFromPtr(probe.ptr);
    buffers.allocator().free(probe);

    var seen: [PayloadBuffers.class_counts[1]]std.atomic.Value(usize) = undefined;
    for (&seen) |*entry| entry.* = .init(0);
    var duplicates = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ buffers.allocator(), &seen, &duplicates, start });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), duplicates.load(.monotonic));
    try std.testing.expectEqual(@as(usize, PayloadBuffers.class_counts[1]), buffers.available(1));
}

test "deinit releases every materialized class" {
    const allocator = std.testing.allocator;
    var buffers = PayloadBuffers.init(allocator);
    const pool = buffers.allocator();

    const small = try pool.alloc(u8, 16);
    const large = try pool.alloc(u8, 9000);
    try std.testing.expect(buffers.mappedBytes() > 0);
    pool.free(small);
    pool.free(large);

    buffers.deinit();
    try std.testing.expectEqual(@as(usize, 0), buffers.mappedBytes());
    try std.testing.expectEqual(@as(usize, 0), buffers.capacity(3));
}
