const std = @import("std");

pub fn NodePool(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            value: T,
            next: ?*Slot,
        };
        const Slab = struct {
            slots: []Slot,
            next: ?*Slab,
        };

        slabs: ?*Slab = null,
        free: ?*Slot = null,
        capacity: usize = 0,
        mutex: std.Io.Mutex = .init,
        io: std.Io,

        pub fn init(io: std.Io, allocator: std.mem.Allocator, capacity: usize) !Self {
            var self: Self = .{ .io = io };
            try self.reserve(allocator, capacity);
            return self;
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (capacity <= self.capacity) return;
            const slab = try allocator.create(Slab);
            errdefer allocator.destroy(slab);
            const slots = try allocator.alloc(Slot, capacity - self.capacity);
            slab.* = .{ .slots = slots, .next = self.slabs };
            for (slots) |*slot| {
                slot.next = self.free;
                self.free = slot;
            }
            self.slabs = slab;
            self.capacity = capacity;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var cursor = self.slabs;
            while (cursor) |slab| {
                const next = slab.next;
                allocator.free(slab.slots);
                allocator.destroy(slab);
                cursor = next;
            }
            self.slabs = null;
            self.free = null;
            self.capacity = 0;
        }

        pub fn acquire(self: *Self) ?*T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const slot = self.free orelse return null;
            self.free = slot.next;
            return &slot.value;
        }

        pub fn release(self: *Self, node: *T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const slot: *Slot = @fieldParentPtr("value", node);
            slot.next = self.free;
            self.free = slot;
        }
    };
}

const TestNode = struct { generation: u64 = 0 };

test "the node pool never hands one node to two threads" {
    const allocator = std.testing.allocator;
    const thread_count = 2;
    const iterations = 20_000;

    var pool = try NodePool(TestNode).init(std.testing.io, allocator, 4);
    defer pool.deinit(allocator);

    const Registry = struct {
        mutex: std.Io.Mutex = .init,
        held: [thread_count]*TestNode = undefined,
        len: usize = 0,

        fn claim(self: *@This(), node: *TestNode) void {
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            for (self.held[0..self.len]) |existing| {
                if (existing == node) @panic("duplicate pool lease");
            }
            self.held[self.len] = node;
            self.len += 1;
        }

        fn drop(self: *@This(), node: *TestNode) void {
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            for (self.held[0..self.len], 0..) |held, i| {
                if (held == node) {
                    self.held[i] = self.held[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
            @panic("unknown pool lease");
        }
    };
    var registry = Registry{};

    const Worker = struct {
        fn run(p: *NodePool(TestNode), reg: *Registry, count: usize) void {
            for (0..count) |i| {
                const node = p.acquire() orelse continue;
                reg.claim(node);
                node.generation = i;
                reg.drop(node);
                p.release(node);
            }
        }
    };

    {
        var threads: [thread_count]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &registry, iterations });
            started += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), registry.len);
}

test "pool exhaustion and recycling never call the allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var pool = try NodePool(TestNode).init(std.testing.io, allocator, 2);
    defer pool.deinit(allocator);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    const first = pool.acquire().?;
    const second = pool.acquire().?;
    try std.testing.expect(pool.acquire() == null);
    for (0..1000) |_| {
        pool.release(first);
        try std.testing.expectEqual(first, pool.acquire().?);
    }
    pool.release(first);
    pool.release(second);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}

fn exercisePoolReserve(allocator: std.mem.Allocator) !void {
    var pool = try NodePool(TestNode).init(std.testing.io, allocator, 2);
    defer pool.deinit(allocator);
    const held = pool.acquire().?;
    held.generation = 77;
    try pool.reserve(allocator, 8);
    try std.testing.expectEqual(@as(u64, 77), held.generation);
    var nodes: [7]*TestNode = undefined;
    for (&nodes) |*node| {
        node.* = pool.acquire().?;
        try std.testing.expect(node.* != held);
    }
    try std.testing.expect(pool.acquire() == null);
    for (nodes) |node| pool.release(node);
    pool.release(held);
}

test "slab reservation preserves leases and unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exercisePoolReserve, .{});
}
