const std = @import("std");

pub const FrameBuffers = struct {
    pub const slot_size: usize = 1536;
    pub const slot_count: usize = 128;

    parent: std.mem.Allocator,
    memory: []align(64) u8 = &.{},
    free_slots: []u32 = &.{},
    in_use: []bool = &.{},
    free_len: usize = 0,
    locked: std.atomic.Value(bool) = .init(false),
    fallback_allocs: std.atomic.Value(usize) = .init(0),
    warned_fallback: std.atomic.Value(bool) = .init(false),

    pub fn init(parent: std.mem.Allocator) FrameBuffers {
        return .{ .parent = parent };
    }

    pub fn deinit(self: *FrameBuffers) void {
        const parent = self.parent;
        if (self.memory.len > 0) parent.free(self.memory);
        if (self.free_slots.len > 0) parent.free(self.free_slots);
        if (self.in_use.len > 0) parent.free(self.in_use);
        self.* = .{ .parent = parent };
    }

    pub fn allocator(self: *FrameBuffers) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn available(self: *FrameBuffers) usize {
        self.acquire();
        defer self.release();
        return self.free_len;
    }

    pub fn capacity(self: *FrameBuffers) usize {
        self.acquire();
        defer self.release();
        return self.free_slots.len;
    }

    pub fn mappedBytes(self: *FrameBuffers) usize {
        self.acquire();
        defer self.release();
        return self.memory.len;
    }

    fn acquire(self: *FrameBuffers) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *FrameBuffers) void {
        self.locked.store(false, .release);
    }

    fn materialize(self: *FrameBuffers) void {
        if (self.memory.len > 0) return;

        const memory = self.parent.alignedAlloc(u8, .fromByteUnits(64), slot_count * slot_size) catch return;
        const free_slots = self.parent.alloc(u32, slot_count) catch {
            self.parent.free(memory);
            return;
        };
        const in_use = self.parent.alloc(bool, slot_count) catch {
            self.parent.free(free_slots);
            self.parent.free(memory);
            return;
        };

        @memset(in_use, false);
        for (free_slots, 0..) |*slot, index| slot.* = @intCast(slot_count - 1 - index);
        self.memory = memory;
        self.free_slots = free_slots;
        self.in_use = in_use;
        self.free_len = slot_count;
    }

    fn claim(self: *FrameBuffers) ?u32 {
        if (self.memory.len == 0) self.materialize();
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        const slot = self.free_slots[self.free_len];
        std.debug.assert(!self.in_use[slot]);
        self.in_use[slot] = true;
        return slot;
    }

    fn give(self: *FrameBuffers, slot: u32) void {
        std.debug.assert(self.in_use[slot]);
        std.debug.assert(self.free_len < self.free_slots.len);
        self.in_use[slot] = false;
        self.free_slots[self.free_len] = slot;
        self.free_len += 1;
    }

    fn slotOf(self: *FrameBuffers, memory: []u8) ?u32 {
        if (self.memory.len == 0 or memory.len == 0) return null;
        const base = @intFromPtr(self.memory.ptr);
        const address = @intFromPtr(memory.ptr);
        if (address < base) return null;
        const offset = address - base;
        if (offset >= self.memory.len) return null;
        if (offset % slot_size != 0) return null;
        return @intCast(offset / slot_size);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FrameBuffers = @ptrCast(@alignCast(context));
        if (len == 0 or len > slot_size or alignment.toByteUnits() > 64) {
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
        }

        self.acquire();
        defer self.release();

        const slot = self.claim() orelse {
            _ = self.fallback_allocs.fetchAdd(1, .monotonic);
            if (!self.warned_fallback.swap(true, .monotonic)) {
                std.log.warn("frame buffer pool exhausted; outgoing frames fall back to the heap", .{});
            }
            return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
        };
        return self.memory[@as(usize, slot) * slot_size ..].ptr;
    }

    fn resizeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *FrameBuffers = @ptrCast(@alignCast(context));
        self.acquire();
        const pooled = self.slotOf(memory) != null;
        self.release();
        if (!pooled) return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ra);
        return new_len <= slot_size;
    }

    fn remapFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *FrameBuffers = @ptrCast(@alignCast(context));
        self.acquire();
        const pooled = self.slotOf(memory) != null;
        self.release();
        if (!pooled) return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra);
        if (new_len > slot_size) return null;
        return memory.ptr;
    }

    fn freeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FrameBuffers = @ptrCast(@alignCast(context));

        self.acquire();
        if (self.slotOf(memory)) |slot| {
            self.give(slot);
            self.release();
            return;
        }
        self.release();

        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
    }
};

test "a slot is handed out once and recycled in place" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    const before = buffers.mappedBytes();
    const first = try pool.alloc(u8, 64);

    try std.testing.expect(before == 0);
    try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count * FrameBuffers.slot_size), buffers.mappedBytes());
    try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count - 1), buffers.available());

    pool.free(first);
    try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count), buffers.available());

    const recycled = try pool.alloc(u8, FrameBuffers.slot_size);
    defer pool.free(recycled);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(recycled.ptr));
}

test "claims never alias and exhaustion falls back to the parent" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    var claimed: [FrameBuffers.slot_count][]u8 = undefined;
    for (&claimed) |*slice| slice.* = try pool.alloc(u8, 32);

    try std.testing.expectEqual(@as(usize, 0), buffers.available());
    for (claimed, 0..) |slice, index| {
        for (claimed[index + 1 ..]) |other| try std.testing.expect(slice.ptr != other.ptr);
    }

    const oversize = try pool.alloc(u8, FrameBuffers.slot_size + 1);
    pool.free(oversize);

    const beyond = try pool.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 0), buffers.available());

    for (claimed) |slice| pool.free(slice);
    pool.free(beyond);
    try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count), buffers.available());
}

test "a foreign slice is freed through the parent" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    const foreign = try allocator.alloc(u8, 24);
    pool.free(foreign);

    const inside = try pool.alloc(u8, 24);
    try std.testing.expect(buffers.slotOf(inside) != null);
    pool.free(inside);
}

test "concurrent claims never alias and every slot returns" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    defer buffers.deinit();

    const probe = try buffers.allocator().alloc(u8, 8);
    const base = @intFromPtr(probe.ptr);
    buffers.allocator().free(probe);

    const Worker = struct {
        fn run(
            pool: std.mem.Allocator,
            slab_base: usize,
            owners: []std.atomic.Value(u32),
            me: u32,
            claimed: *std.atomic.Value(usize),
            conflicts: *std.atomic.Value(usize),
        ) void {
            for (0..512) |_| {
                const slice = pool.alloc(u8, 48) catch continue;
                const index = (@intFromPtr(slice.ptr) - slab_base) / FrameBuffers.slot_size;
                if (owners[index].swap(me, .acq_rel) != 0) _ = conflicts.fetchAdd(1, .monotonic);
                owners[index].store(0, .release);
                _ = claimed.fetchAdd(1, .monotonic);
                pool.free(slice);
            }
        }
    };

    var owners: [FrameBuffers.slot_count]std.atomic.Value(u32) = undefined;
    for (&owners) |*owner| owner.* = .init(0);
    var claimed = std.atomic.Value(usize).init(0);
    var conflicts = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{
            buffers.allocator(),
            base,
            &owners,
            @as(u32, @intCast(index + 1)),
            &claimed,
            &conflicts,
        });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), conflicts.load(.monotonic));
    try std.testing.expect(claimed.load(.monotonic) > 0);
    try std.testing.expectEqual(@as(usize, FrameBuffers.slot_count), buffers.available());
}

test "remap shrinks inside a slot and refuses growth" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    defer buffers.deinit();

    const pool = buffers.allocator();
    const full = try pool.alloc(u8, FrameBuffers.slot_size);
    defer pool.free(full);

    const shrunk = pool.remap(full, 128) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(full.ptr), @intFromPtr(shrunk.ptr));
    try std.testing.expect(pool.remap(full, FrameBuffers.slot_size + 1) == null);
    try std.testing.expect(pool.resize(full, FrameBuffers.slot_size));
    try std.testing.expect(!pool.resize(full, FrameBuffers.slot_size + 1));
}

test "deinit releases the backing slab" {
    const allocator = std.testing.allocator;
    var buffers = FrameBuffers.init(allocator);
    const slice = try buffers.allocator().alloc(u8, 64);
    _ = slice;
    try std.testing.expect(buffers.mappedBytes() > 0);
    buffers.deinit();
    try std.testing.expectEqual(@as(usize, 0), buffers.mappedBytes());
    try std.testing.expectEqual(@as(usize, 0), buffers.capacity());
}
