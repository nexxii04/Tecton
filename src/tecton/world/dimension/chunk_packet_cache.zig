const std = @import("std");

pub const Hash = i64;

pub const default_budget_bytes: usize = 32 * 1024 * 1024;

pub const ChunkPacketCache = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Hash, *Entry),
    head: ?*Entry = null,
    tail: ?*Entry = null,
    bytes: usize = 0,
    budget: usize = default_budget_bytes,
    evictions: u64 = 0,

    const Entry = struct {
        hash: Hash,
        data: []const u8,
        generation: u64,
        prev: ?*Entry = null,
        next: ?*Entry = null,
    };

    pub fn init(allocator: std.mem.Allocator) ChunkPacketCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(Hash, *Entry).init(allocator),
        };
    }

    pub fn deinit(self: *ChunkPacketCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            const node = entry.*;
            self.allocator.free(node.data);
            self.allocator.destroy(node);
        }
        self.map.deinit();
        self.head = null;
        self.tail = null;
        self.bytes = 0;
    }

    pub fn count(self: *const ChunkPacketCache) usize {
        return self.map.count();
    }

    pub fn bytesHeld(self: *const ChunkPacketCache) usize {
        return self.bytes;
    }

    pub fn get(self: *ChunkPacketCache, hash: Hash, current_generation: u64) ?[]const u8 {
        const entry = self.map.get(hash) orelse return null;
        if (entry.generation != current_generation) {
            self.remove(hash);
            return null;
        }
        self.moveToTail(entry);
        return entry.data;
    }

    pub fn put(self: *ChunkPacketCache, hash: Hash, generation: u64, data: []const u8) void {
        if (self.map.get(hash)) |existing| {
            // A caller may hand back the same slice (a no-op refresh); freeing it
            // first would leave the entry pointing at released memory.
            const same_bytes = existing.data.ptr == data.ptr and existing.data.len == data.len;
            if (!same_bytes) {
                self.bytes -= existing.data.len;
                self.allocator.free(existing.data);
                self.bytes += data.len;
            }
            existing.data = data;
            existing.generation = generation;
            self.moveToTail(existing);
        } else {
            const entry = self.allocator.create(Entry) catch {
                self.allocator.free(data);
                return;
            };
            entry.* = .{ .hash = hash, .data = data, .generation = generation };
            self.append(entry);
            self.map.put(hash, entry) catch {
                self.unlink(entry);
                self.allocator.free(entry.data);
                self.allocator.destroy(entry);
                return;
            };
            self.bytes += data.len;
        }

        self.enforceBudget();
    }

    pub fn remove(self: *ChunkPacketCache, hash: Hash) void {
        const removed = self.map.fetchRemove(hash) orelse return;
        const node = removed.value;
        self.unlink(node);
        self.bytes -= node.data.len;
        self.allocator.free(node.data);
        self.allocator.destroy(node);
    }

    fn enforceBudget(self: *ChunkPacketCache) void {
        // The most recent entry is never evicted: the caller just handed us its
        // bytes and may still hold the slice it passed to `put`.
        while (self.bytes > self.budget and self.map.count() > 1) {
            const oldest = self.head orelse return;
            self.evictions += 1;
            self.remove(oldest.hash);
        }
    }

    fn append(self: *ChunkPacketCache, entry: *Entry) void {
        entry.prev = self.tail;
        entry.next = null;
        if (self.tail) |tail| {
            tail.next = entry;
        } else {
            self.head = entry;
        }
        self.tail = entry;
    }

    fn unlink(self: *ChunkPacketCache, entry: *Entry) void {
        if (entry.prev) |prev| prev.next = entry.next else self.head = entry.next;
        if (entry.next) |next| next.prev = entry.prev else self.tail = entry.prev;
        entry.prev = null;
        entry.next = null;
    }

    fn moveToTail(self: *ChunkPacketCache, entry: *Entry) void {
        if (self.tail == entry) return;
        self.unlink(entry);
        self.append(entry);
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Hash = test_owner.Hash;
    pub const ChunkPacketCache = test_owner.ChunkPacketCache;
    pub const default_budget_bytes = test_owner.default_budget_bytes;
};

test "cached packets are returned and accounted for" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_000();
}

test "a packet from another generation is dropped instead of served" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_001();
}

test "replacing a hash frees the previous packet" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_002();
}

test "the budget evicts the least recently used packet first" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_003();
}

test "a single packet larger than the budget stays until another arrives" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_004();
}

test "remove is idempotent and frees exactly one packet" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_005();
}

test "re-putting the same buffer keeps it alive" {
    try @import("chunk_packet_cache_test.zig").Suite(test_scope).case_006();
}
