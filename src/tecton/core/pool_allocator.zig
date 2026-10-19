const std = @import("std");

pub const PoolAllocator = struct {
    pub const slot_min: usize = 32;
    pub const class_count: usize = 14;
    pub const max_slot: usize = slot_min << (class_count - 1);
    pub const min_chunk_size: usize = 64 * 1024;
    pub const chunk_size: usize = 1 << 20;
    pub const shard_count: usize = 4;

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    const Node = struct { next: ?*Node };

    const ChunkHeader = struct {
        all_prev: ?*ChunkHeader = null,
        all_next: ?*ChunkHeader = null,
        live: u32 = 0,
        shard: u8 = 0,
    };

    const Shard = struct {
        lock: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
        head: ?*Node = null,
        bump: [*]u8 = undefined,
        bump_left: usize = 0,
        all: ?*ChunkHeader = null,
        chunks: usize = 0,
        mapped_bytes: usize = 0,
        live: usize = 0,
        spins: u64 = 0,

        fn acquire(self: *Shard) void {
            var spins: u64 = 0;
            while (self.lock.swap(true, .acquire)) {
                std.atomic.spinLoopHint();
                spins += 1;
            }
            self.spins += spins;
        }

        fn release(self: *Shard) void {
            self.lock.store(false, .release);
        }

        fn linkAll(self: *Shard, header: *ChunkHeader) void {
            header.all_prev = null;
            header.all_next = self.all;
            if (self.all) |head| head.all_prev = header;
            self.all = header;
        }

        fn unlinkAll(self: *Shard, header: *ChunkHeader) void {
            if (header.all_prev) |prev| prev.all_next = header.all_next else self.all = header.all_next;
            if (header.all_next) |next| next.all_prev = header.all_prev;
            header.all_prev = null;
            header.all_next = null;
        }
    };

    const Class = struct {
        shards: [shard_count]Shard = @splat(.{}),
    };

    classes: [class_count]Class = @splat(.{}),
    large: std.mem.Allocator = std.heap.page_allocator,
    mapped_bytes: std.atomic.Value(u64) = .init(0),

    pub const ClassStats = struct { slot: usize, chunks: usize, live: usize, mapped_bytes: usize };

    comptime {
        if (@sizeOf(ChunkHeader) > slot_min) @compileError("chunk header does not fit in the smallest slot");
    }

    pub fn allocator(self: *PoolAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn mappedBytes(self: *const PoolAllocator) u64 {
        return self.mapped_bytes.load(.monotonic);
    }

    pub fn contentionSpins(self: *PoolAllocator) u64 {
        var total: u64 = 0;
        for (&self.classes) |*class| {
            for (&class.shards) |*shard| {
                shard.acquire();
                defer shard.release();
                total += shard.spins;
            }
        }
        return total;
    }

    pub fn poolChunks(self: *PoolAllocator) usize {
        var total: usize = 0;
        for (&self.classes) |*class| {
            for (&class.shards) |*shard| {
                shard.acquire();
                defer shard.release();
                total += shard.chunks;
            }
        }
        return total;
    }

    pub fn classStats(self: *PoolAllocator, index: usize) ClassStats {
        const class = &self.classes[index];
        var chunks: usize = 0;
        var live: usize = 0;
        var mapped: usize = 0;
        for (&class.shards) |*shard| {
            shard.acquire();
            defer shard.release();
            chunks += shard.chunks;
            live += shard.live;
            mapped += shard.mapped_bytes;
        }
        return .{
            .slot = slotSize(index),
            .chunks = chunks,
            .live = live,
            .mapped_bytes = mapped,
        };
    }

    pub fn deinit(self: *PoolAllocator) void {
        for (&self.classes, 0..) |*class, class_index| {
            const chunk_len = chunkSizeForSlot(slotSize(class_index));
            for (&class.shards) |*shard| {
                var cursor = shard.all;
                while (cursor) |header| {
                    const next = header.all_next;
                    const base: [*]u8 = @ptrFromInt(@intFromPtr(header));
                    self.large.rawFree(base[0..chunk_len], .fromByteUnits(chunk_len), 0);
                    cursor = next;
                }
                shard.* = .{};
            }
        }
        self.mapped_bytes.store(0, .monotonic);
    }

    fn slotSize(index: usize) usize {
        return slot_min << @intCast(index);
    }

    fn chunkSizeForSlot(slot: usize) usize {
        if (slot >= chunk_size) return slot;
        return std.math.clamp(slot * 8, min_chunk_size, chunk_size);
    }

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

    fn chunkBase(addr: usize, chunk_len: usize) usize {
        return addr & ~(chunk_len - 1);
    }

    fn headerAt(addr: usize, chunk_len: usize) *ChunkHeader {
        return @ptrFromInt(chunkBase(addr, chunk_len));
    }

    fn mapChunk(self: *PoolAllocator, chunk_len: usize) ?[*]u8 {
        const chunk = self.large.rawAlloc(chunk_len, .fromByteUnits(chunk_len), 0) orelse return null;
        _ = self.mapped_bytes.fetchAdd(chunk_len, .monotonic);
        return chunk;
    }

    fn allocSmall(self: *PoolAllocator, index: usize, shard_index: usize) ?[*]u8 {
        const slot = slotSize(index);
        const chunk_len = chunkSizeForSlot(slot);
        const shard = &self.classes[index].shards[shard_index];

        shard.acquire();
        defer shard.release();

        if (shard.head) |node| {
            shard.head = node.next;
            shard.live += 1;
            headerAt(@intFromPtr(node), chunk_len).live += 1;
            return @ptrCast(node);
        }

        if (shard.bump_left > 0) {
            const next = shard.bump;
            shard.bump += slot;
            shard.bump_left -= 1;
            shard.live += 1;
            headerAt(@intFromPtr(next), chunk_len).live += 1;
            return next;
        }

        const chunk = self.mapChunk(chunk_len) orelse return null;
        const header: *ChunkHeader = @ptrCast(@alignCast(chunk));
        header.* = .{ .shard = @intCast(shard_index) };
        shard.chunks += 1;
        shard.mapped_bytes += chunk_len;
        shard.linkAll(header);
        shard.bump = chunk + slot * 2;
        shard.bump_left = chunk_len / slot - 2;
        shard.live += 1;
        header.live = 1;
        return chunk + slot;
    }

    fn freeSmall(self: *PoolAllocator, index: usize, chunk_len: usize, memory: []u8) void {
        const addr = @intFromPtr(memory.ptr);
        const header = headerAt(addr, chunk_len);
        const shard = &self.classes[index].shards[header.shard];

        shard.acquire();
        defer shard.release();

        std.debug.assert(header.live > 0);
        header.live -= 1;
        shard.live -= 1;

        if (header.live == 0 and shard.chunks > 1) {
            retireChunk(self, shard, chunkBase(addr, chunk_len), chunk_len);
            return;
        }

        const node: *Node = @ptrCast(@alignCast(memory.ptr));
        node.next = shard.head;
        shard.head = node;
    }

    fn retireChunk(self: *PoolAllocator, shard: *Shard, base: usize, chunk_len: usize) void {
        var link = &shard.head;
        while (link.*) |node| {
            if (chunkBase(@intFromPtr(node), chunk_len) == base) {
                link.* = node.next;
            } else {
                link = &node.next;
            }
        }

        if (shard.bump_left > 0 and chunkBase(@intFromPtr(shard.bump), chunk_len) == base) {
            shard.bump_left = 0;
        }

        const header: *ChunkHeader = @ptrFromInt(base);
        shard.unlinkAll(header);
        shard.chunks -= 1;
        shard.mapped_bytes -= chunk_len;
        _ = self.mapped_bytes.fetchSub(chunk_len, .monotonic);

        const bytes: [*]u8 = @ptrFromInt(base);
        self.large.rawFree(bytes[0..chunk_len], .fromByteUnits(chunk_len), 0);
    }

    fn allocFn(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const index = classIndex(len, alignment) orelse
            return self.large.rawAlloc(len, alignment, ra);
        return self.allocSmall(index, currentShard());
    }

    fn freeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *PoolAllocator = @ptrCast(@alignCast(context));
        const index = classIndex(memory.len, alignment) orelse
            return self.large.rawFree(memory, alignment, ra);
        self.freeSmall(index, chunkSizeForSlot(slotSize(index)), memory);
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

threadlocal var thread_shard: usize = std.math.maxInt(usize);

var shard_sequence: std.atomic.Value(usize) = .init(0);

fn currentShard() usize {
    var index = thread_shard;
    if (index == std.math.maxInt(usize)) {
        index = shard_sequence.fetchAdd(1, .monotonic) & (PoolAllocator.shard_count - 1);
        thread_shard = index;
    }
    return index;
}

var instance: PoolAllocator = .{};

pub fn allocator() std.mem.Allocator {
    return instance.allocator();
}

pub fn mappedBytes() u64 {
    return instance.mappedBytes();
}

pub fn contentionSpins() u64 {
    return instance.contentionSpins();
}

pub fn poolChunks() usize {
    return instance.poolChunks();
}

pub fn classStats(index: usize) PoolAllocator.ClassStats {
    return instance.classStats(index);
}

pub const class_total = PoolAllocator.class_count;

pub fn chunkBytesForSlot(slot: usize) usize {
    return PoolAllocator.chunkSizeForSlot(slot);
}

const testing = std.testing;

fn testPool() PoolAllocator {
    return .{ .large = std.heap.page_allocator };
}

test "small allocations reuse freed slots across classes" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();

    const a = try alloc.alloc(u8, 100);
    @memset(a, 0xAB);
    alloc.free(a);

    const b = try alloc.alloc(u8, 100);
    defer alloc.free(b);
    try testing.expectEqual(a.ptr, b.ptr);
    try testing.expectEqual(chunkBytesForSlot(128), pool.mapped_bytes.load(.monotonic));
}

test "a free on another class does not hand out the wrong slot" {
    var pool = testPool();
    defer pool.deinit();
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
    defer pool.deinit();
    const alloc = pool.allocator();

    inline for (.{ 32, 64, 4096, 16 * 1024 }) |alignment| {
        const memory = try alloc.alignedAlloc(u8, .fromByteUnits(alignment), 64);
        defer alloc.free(memory);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % alignment);
    }
}

test "allocations above the largest class fall through to the backing allocator" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();

    const big = try alloc.alloc(u8, PoolAllocator.max_slot + 1);
    defer alloc.free(big);
    @memset(big, 0x5A);
    try testing.expectEqual(@as(u64, 0), pool.mapped_bytes.load(.monotonic));
}

test "buffers above 64 KiB reuse a slot from the shared pool instead of remapping" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();

    const big_len = 100 * 1024;
    const first = try alloc.alloc(u8, big_len);
    @memset(first, 0xC3);
    alloc.free(first);

    const second = try alloc.alloc(u8, big_len);
    defer alloc.free(second);
    try testing.expectEqual(first.ptr, second.ptr);
    try testing.expectEqual(chunkBytesForSlot(128 * 1024), pool.mapped_bytes.load(.monotonic));
}

test "the largest class serves a slot from a dedicated chunk" {
    var pool = testPool();
    defer pool.deinit();
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
    defer pool.deinit();
    const alloc = pool.allocator();

    const first = try alloc.alloc(u8, 1000);
    try testing.expect(alloc.resize(first, 1024));
    try testing.expect(!alloc.resize(first, 4096));
    alloc.free(first);

    const twice = try alloc.alloc(u8, 1024);
    defer alloc.free(twice);
    try testing.expectEqual(first.ptr, twice.ptr);
}

test "an empty chunk goes back to the backing allocator" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();
    const chunk_len = chunkBytesForSlot(64);

    var slots: [1500][]u8 = undefined;
    for (&slots) |*slot| slot.* = try alloc.alloc(u8, 64);
    try testing.expect(pool.mapped_bytes.load(.monotonic) > chunk_len);
    try testing.expectEqual(@as(usize, 2), pool.poolChunks());

    for (slots) |slot| alloc.free(slot);
    try testing.expectEqual(@as(u64, chunk_len), pool.mapped_bytes.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), pool.poolChunks());

    const after = try alloc.alloc(u8, 64);
    defer alloc.free(after);
    @memset(after, 0x33);
    try testing.expectEqual(@as(u8, 0x33), after[0]);
}

test "a retired chunk is not reached through a stale free-list entry" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();
    const chunk_len = chunkBytesForSlot(64);

    var round: u8 = 0;
    while (round < 4) : (round += 1) {
        var slots: [1200][]u8 = undefined;
        for (&slots) |*slot| {
            const memory = try alloc.alloc(u8, 64);
            @memset(memory, round);
            slot.* = memory;
        }
        for (slots) |slot| {
            try testing.expectEqual(round, slot[0]);
            alloc.free(slot);
        }
        try testing.expect(pool.mapped_bytes.load(.monotonic) <= chunk_len);
    }
}

test "interleaved frees still retire whole chunks" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();
    const chunk_len = chunkBytesForSlot(64);

    var slots: [1500][]u8 = undefined;
    for (&slots) |*slot| slot.* = try alloc.alloc(u8, 64);

    var index: usize = 0;
    while (index < slots.len) : (index += 2) alloc.free(slots[index]);
    index = 1;
    while (index < slots.len) : (index += 2) alloc.free(slots[index]);

    try testing.expectEqual(@as(u64, chunk_len), pool.mapped_bytes.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), pool.poolChunks());
}

test "freed slots are reused before a new chunk is mapped" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();
    const chunk_len = chunkBytesForSlot(64);

    var slots: [900][]u8 = undefined;
    for (&slots) |*slot| slot.* = try alloc.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 1), pool.poolChunks());

    for (slots, 0..) |slot, index| {
        if (index % 2 == 0) alloc.free(slot);
    }

    var again: [450][]u8 = undefined;
    for (&again) |*slot| slot.* = try alloc.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 1), pool.poolChunks());

    for (again) |slot| alloc.free(slot);
    for (slots, 0..) |slot, index| {
        if (index % 2 != 0) alloc.free(slot);
    }

    try testing.expectEqual(@as(u64, chunk_len), pool.mapped_bytes.load(.monotonic));
}

test "a slot freed from another thread retires its owner chunk" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();
    const chunk_len = chunkBytesForSlot(64);

    const total = 2500;
    var slots: [total][]u8 = undefined;
    for (&slots) |*slot| {
        slot.* = try alloc.alloc(u8, 64);
        @memset(slot.*, 0x5C);
    }
    try testing.expect(pool.poolChunks() >= 3);

    const Releaser = struct {
        fn run(a: std.mem.Allocator, batch: []const []u8) void {
            for (batch) |slot| {
                for (slot) |byte| std.debug.assert(byte == 0x5C);
                a.free(slot);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Releaser.run, .{ alloc, slots[0..] });
    thread.join();

    try testing.expectEqual(@as(u64, chunk_len), pool.mapped_bytes.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), pool.poolChunks());
}

test "concurrent allocations keep their contents and release their chunks" {
    var pool = testPool();
    defer pool.deinit();
    const alloc = pool.allocator();

    const Worker = struct {
        fn run(a: std.mem.Allocator, seed: u64) void {
            churn(a, seed) catch @panic("pool worker failed");
        }

        fn churn(a: std.mem.Allocator, seed: u64) !void {
            var rng = std.Random.DefaultPrng.init(seed);
            var live: [64][]u8 = undefined;
            var live_len: usize = 0;

            for (0..4000) |_| {
                const take = live_len < live.len and rng.random().uintLessThan(u64, 2) == 1;
                if (take) {
                    const len = rng.random().intRangeAtMost(usize, 1, 4096);
                    const memory = try a.alloc(u8, len);
                    @memset(memory, @as(u8, @truncate(len)));
                    live[live_len] = memory;
                    live_len += 1;
                } else if (live_len > 0) {
                    const index = rng.random().uintLessThan(usize, live_len);
                    const memory = live[index];
                    const expected: u8 = @truncate(memory.len);
                    for (memory) |byte| try testing.expectEqual(expected, byte);
                    a.free(memory);
                    live[index] = live[live_len - 1];
                    live_len -= 1;
                }
            }

            for (live[0..live_len]) |memory| a.free(memory);
        }
    };

    var threads: [PoolAllocator.shard_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ alloc, 0x1000 + index });
    }
    for (&threads) |*thread| thread.join();

    var retained: u64 = 0;
    var class_index: usize = 0;
    while (class_index < PoolAllocator.class_count) : (class_index += 1) {
        retained += chunkBytesForSlot(PoolAllocator.slot_min << @intCast(class_index));
    }
    try testing.expect(pool.mapped_bytes.load(.monotonic) <= retained * PoolAllocator.shard_count);
}

test "every mapped chunk is accounted for and deinit releases all of them" {
    var pool = testPool();
    const alloc = pool.allocator();

    const sizes = [_]usize{ 24, 100, 900, 5000, 70 * 1024, PoolAllocator.max_slot };
    var handed: [sizes.len * 8][]u8 = undefined;
    var count: usize = 0;

    for (0..8) |round| {
        for (sizes, 0..) |size, index| {
            const memory = try alloc.alloc(u8, size);
            @memset(memory, @as(u8, @truncate(round + index)));
            handed[count] = memory;
            count += 1;
        }
    }

    var accounted: u64 = 0;
    var class_index: usize = 0;
    while (class_index < PoolAllocator.class_count) : (class_index += 1) {
        accounted += pool.classStats(class_index).mapped_bytes;
    }
    try testing.expectEqual(pool.mapped_bytes.load(.monotonic), accounted);

    for (handed[0..count]) |memory| alloc.free(memory);
    pool.deinit();

    try testing.expectEqual(@as(u64, 0), pool.mapped_bytes.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), pool.poolChunks());
}

test "chunk sizes stay between one slot and the retention ceiling" {
    var index: usize = 0;
    while (index < PoolAllocator.class_count) : (index += 1) {
        const slot = PoolAllocator.slot_min << @intCast(index);
        const chunk = chunkBytesForSlot(slot);
        try testing.expect(chunk >= slot);
        try testing.expect(chunk <= PoolAllocator.chunk_size);
        try testing.expect(chunk % slot == 0);
    }
}
