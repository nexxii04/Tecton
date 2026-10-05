//! `std.heap.smp_allocator` keeps per-thread freelists, so frees on another thread are never reused; this pool shares one freelist per size class.
const std = @import("std");

pub const PoolAllocator = struct {
    pub const slot_min: usize = 32;
    pub const class_count: usize = 16;
    pub const max_slot: usize = slot_min << (class_count - 1);
    pub const chunk_size: usize = 1 << 20;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    const Node = struct { next: ?*Node };

    const Class = struct {
        head: ?*Node = null,
        bump: [*]u8 = undefined,
        bump_left: usize = 0,
        // Spinlock: short critical section, never held across an allocation.
        lock: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
        chunks: usize = 0,

        fn acquire(self: *Class) void {
            while (self.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn release(self: *Class) void {
            self.lock.store(false, .release);
        }
    };

    classes: [class_count]Class = @splat(.{}),
    large: std.mem.Allocator = std.heap.page_allocator,
    mapped_bytes: std.atomic.Value(u64) = .init(0),

    pub fn allocator(self: *PoolAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn mappedBytes(self: *const PoolAllocator) u64 {
        return self.mapped_bytes.load(.monotonic);
    }

    fn slotSize(index: usize) usize {
        return slot_min << @intCast(index);
    }

    // Null means the backing allocator handles it; the result depends only on the arguments, which is how `free` routes back to the same class.
    fn classIndex(len: usize, alignment: std.mem.Alignment) ?usize {
        if (len == 0) return null;
        const need = @max(len, @max(alignment.toByteUnits(), slot_min));
        if (need > max_slot) return null;
        const slot = std.math.ceilPowerOfTwo(usize, need) catch return null;
        var index: usize = 0;
        var size: usize = slot_min;
        while (size < slot) : (size <<= 1) index += 1;
        return index;
    }

    fn mapChunk(self: *PoolAllocator, index: usize) ?[*]u8 {
        const alignment = std.mem.Alignment.fromByteUnits(@min(slotSize(index), chunk_size));
        const chunk = self.large.rawAlloc(chunk_size, alignment, 0) orelse return null;
        _ = self.mapped_bytes.fetchAdd(chunk_size, .monotonic);
        return chunk;
    }

    fn allocFn(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const index = classIndex(len, alignment) orelse
            return self.large.rawAlloc(len, alignment, ra);

        const class = &self.classes[index];
        const slot = slotSize(index);
        class.acquire();
        defer class.release();

        if (class.head) |node| {
            class.head = node.next;
            return @ptrCast(node);
        }
        if (class.bump_left > 0) {
            const next = class.bump;
            class.bump += slot;
            class.bump_left -= 1;
            return next;
        }
        const chunk = self.mapChunk(index) orelse return null;
        class.chunks += 1;
        class.bump = chunk + slot;
        class.bump_left = chunk_size / slot - 1;
        return chunk;
    }

    fn freeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const index = classIndex(memory.len, alignment) orelse
            return self.large.rawFree(memory, alignment, ra);

        const class = &self.classes[index];
        const node: *Node = @ptrCast(@alignCast(memory.ptr));
        class.acquire();
        node.next = class.head;
        class.head = node;
        class.release();
    }

    fn resizeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const old = classIndex(memory.len, alignment);
        const new = classIndex(new_len, alignment);
        if (old == null and new == null) return self.large.rawResize(memory, alignment, new_len, ra);
        if (old == null or new == null) return false;
        return old.? == new.?;
    }

    fn remapFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const old = classIndex(memory.len, alignment);
        const new = classIndex(new_len, alignment);
        if (old == null and new == null) return self.large.rawRemap(memory, alignment, new_len, ra);
        if (old == null or new == null) return null;
        return if (old.? == new.?) memory.ptr else null;
    }
};

// Process-wide: the release server hands this allocator to `Server`.
var instance: PoolAllocator = .{};

pub fn allocator() std.mem.Allocator {
    return instance.allocator();
}

pub fn mappedBytes() u64 {
    return instance.mappedBytes();
}

const testing = std.testing;

// Page allocator on purpose: pool chunks are retained by design, so the leak-checking test allocator would flag every test.

fn testPool() PoolAllocator {
    return .{ .large = std.heap.page_allocator };
}

test "small allocations reuse freed slots across classes" {
    var pool = testPool();
    const alloc = pool.allocator();

    const a = try alloc.alloc(u8, 100);
    @memset(a, 0xAB);
    alloc.free(a);

    const b = try alloc.alloc(u8, 100);
    defer alloc.free(b);
    try testing.expectEqual(a.ptr, b.ptr);
    try testing.expectEqual(@as(u64, 1), pool.mapped_bytes.load(.monotonic) / PoolAllocator.chunk_size);
}

test "a free on another class does not hand out the wrong slot" {
    var pool = testPool();
    const alloc = pool.allocator();

    const small = try alloc.alloc(u8, 40);
    const big = try alloc.alloc(u8, 5000);
    alloc.free(small);
    alloc.free(big);

    const again_small = try alloc.alloc(u8, 40);
    const again_big = try alloc.alloc(u8, 5000);
    defer alloc.free(again_small);
    defer alloc.free(again_big);
    try testing.expectEqual(small.ptr, again_small.ptr);
    try testing.expectEqual(big.ptr, again_big.ptr);
}

test "requested alignment is honoured for pool slots" {
    var pool = testPool();
    const alloc = pool.allocator();

    inline for (.{ 32, 64, 4096, 16 * 1024 }) |alignment| {
        const memory = try alloc.alignedAlloc(u8, .fromByteUnits(alignment), 64);
        defer alloc.free(memory);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % alignment);
    }
}

test "allocations above the largest class fall through to the backing allocator" {
    var pool = testPool();
    const alloc = pool.allocator();

    const big = try alloc.alloc(u8, PoolAllocator.max_slot + 1);
    defer alloc.free(big);
    @memset(big, 0x5A);
    try testing.expectEqual(@as(u64, 0), pool.mapped_bytes.load(.monotonic));
}

test "buffers above 64 KiB reuse a slot from the shared pool instead of remapping" {
    var pool = testPool();
    const alloc = pool.allocator();

    const big_len = 100 * 1024;
    const first = try alloc.alloc(u8, big_len);
    @memset(first, 0xC3);
    alloc.free(first);

    const second = try alloc.alloc(u8, big_len);
    defer alloc.free(second);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(@as(u64, PoolAllocator.chunk_size), pool.mapped_bytes.load(.monotonic));
}

test "the largest class serves one slot per chunk and reuses it" {
    var pool = testPool();
    const alloc = pool.allocator();

    const first = try alloc.alloc(u8, PoolAllocator.max_slot);
    @memset(first, 0x7E);
    alloc.free(first);

    const second = try alloc.alloc(u8, PoolAllocator.max_slot);
    defer alloc.free(second);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(@as(u64, PoolAllocator.chunk_size), pool.mapped_bytes.load(.monotonic));
}

test "resize keeps the pointer within a class and rejects moves across classes" {
    var pool = testPool();
    const alloc = pool.allocator();

    const first = try alloc.alloc(u8, 1000);
    try testing.expect(alloc.resize(first, 1024));
    try testing.expect(!alloc.resize(first, 4096));
    alloc.free(first);

    const twice = try alloc.alloc(u8, 1024);
    defer alloc.free(twice);
    try testing.expectEqual(first.ptr, twice.ptr);
}
