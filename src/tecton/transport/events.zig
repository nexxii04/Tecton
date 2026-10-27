const std = @import("std");

/// Transport callbacks carry ids only: the connection can be freed before the tick drains them.
pub const Event = union(enum) {
    opened: u64,
    closed: u64,
};

pub const max_events: usize = 4096;

/// Cross-thread hand-off from transport callbacks to the game tick.
pub const Queue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Event) = .empty,
    dropped: std.atomic.Value(usize) = .init(0),

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Queue {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Queue) void {
        self.mutex.lock(self.io) catch return;
        const pending = self.items;
        self.items = .empty;
        self.mutex.unlock(self.io);

        var released = pending;
        released.deinit(self.allocator);
    }

    /// Never fails a transport callback: a full queue counts the drop and returns.
    pub fn push(self: *Queue, event: Event) void {
        self.mutex.lock(self.io) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };
        defer self.mutex.unlock(self.io);
        if (self.items.items.len >= max_events) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.items.append(self.allocator, event) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
        };
    }

    /// Copies what is pending into `buffer` and empties the queue. Both sides keep their
    /// capacity, so a queue drained every tick stops allocating after the first batch.
    pub fn drain(self: *Queue, buffer: *std.ArrayList(Event)) void {
        buffer.clearRetainingCapacity();
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        buffer.appendSlice(self.allocator, self.items.items) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };
        self.items.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "events drain in publish order and leave the queue empty" {
    var queue = Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    queue.push(.{ .opened = 1 });
    queue.push(.{ .closed = 1 });
    queue.push(.{ .opened = 2 });

    var batch: std.ArrayList(Event) = .empty;
    defer batch.deinit(testing.allocator);

    queue.drain(&batch);
    try testing.expectEqual(@as(usize, 3), batch.items.len);
    try testing.expectEqual(@as(u64, 1), batch.items[0].opened);
    try testing.expectEqual(@as(u64, 1), batch.items[1].closed);
    try testing.expectEqual(@as(u64, 2), batch.items[2].opened);
    try testing.expectEqual(@as(usize, 0), queue.items.items.len);

    queue.drain(&batch);
    try testing.expectEqual(@as(usize, 0), batch.items.len);
}

test "a drained batch is reused, so a steady stream never allocates" {
    var queue = Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var batch: std.ArrayList(Event) = .empty;
    defer batch.deinit(testing.allocator);

    queue.push(.{ .opened = 1 });
    queue.drain(&batch);
    batch.clearRetainingCapacity();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;

    queue.allocator = failing.allocator();
    for (0..4) |index| {
        queue.push(.{ .opened = @intCast(index + 2) });
        queue.drain(&batch);
        try testing.expectEqual(@as(usize, 1), batch.items.len);
        try testing.expectEqual(@as(u64, @intCast(index + 2)), batch.items[0].opened);
        batch.clearRetainingCapacity();
    }

    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}

test "the queue drops past its bound instead of growing" {
    var queue = Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    for (0..max_events + 8) |index| queue.push(.{ .opened = @intCast(index) });
    try testing.expectEqual(max_events, queue.items.items.len);
    try testing.expectEqual(@as(usize, 8), queue.dropped.load(.monotonic));
}
