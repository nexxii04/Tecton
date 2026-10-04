const std = @import("std");

pub fn NodePool(comptime T: type) type {
    return struct {
        const Self = @This();

        pool: std.heap.MemoryPool(T),
        mutex: std.Io.Mutex = .init,
        io: std.Io,

        pub fn init(io: std.Io, allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .pool = try std.heap.MemoryPool(T).initCapacity(allocator, capacity),
                .io = io,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.pool.deinit(allocator);
        }

        pub fn acquire(self: *Self, allocator: std.mem.Allocator) ?*T {
            self.mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                return null;
            };
            defer self.mutex.unlock(self.io);
            return self.pool.create(allocator) catch null;
        }

        pub fn release(self: *Self, node: *T) void {
            self.mutex.lock(self.io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                return;
            };
            defer self.mutex.unlock(self.io);
            self.pool.destroy(node);
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
            self.mutex.lock(std.testing.io) catch return;
            defer self.mutex.unlock(std.testing.io);
            for (self.held[0..self.len]) |existing| {
                if (existing == node) @panic("el pool entrego el mismo nodo a dos llamantes");
            }
            self.held[self.len] = node;
            self.len += 1;
        }

        fn drop(self: *@This(), node: *TestNode) void {
            self.mutex.lock(std.testing.io) catch return;
            defer self.mutex.unlock(std.testing.io);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (self.held[i] == node) {
                    self.held[i] = self.held[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
        }
    };
    var registry = Registry{};

    const Worker = struct {
        fn run(p: *NodePool(TestNode), reg: *Registry, alloc: std.mem.Allocator, count: usize) void {
            for (0..count) |i| {
                const node = p.acquire(alloc) orelse continue;
                reg.claim(node);
                node.generation = i;
                reg.drop(node);
                p.release(node);
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &registry, allocator, iterations });
    }
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), registry.len);
}
