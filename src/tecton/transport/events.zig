const std = @import("std");

/// Transport callbacks carry ids only: the connection can be freed before the tick drains them.
pub const Event = union(enum) {
    opened: u64,
    closed: u64,
};

/// Bound of the hand-off. A full queue counts the drop and leaves reconciliation to the tick.
pub const max_events: usize = 4096;

/// Cross-thread hand-off from transport callbacks to the game tick.
///
/// The slots live in the queue, so a callback never allocates: backpressure shows up as a
/// counted drop instead of an allocation failure on a transport thread. A dropped `closed`
/// event is recoverable because the tick also reconciles the transport state.
pub const Queue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    slots: [max_events]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: std.atomic.Value(usize) = .init(0),

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Queue {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Queue) void {
        _ = self;
    }

    pub fn depth(self: *Queue) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.len;
    }

    pub fn droppedCount(self: *const Queue) usize {
        return self.dropped.load(.monotonic);
    }

    /// Never fails a transport callback: a full queue counts the drop and returns.
    pub fn push(self: *Queue, event: Event) void {
        self.mutex.lock(self.io) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };
        defer self.mutex.unlock(self.io);
        if (self.len == max_events) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        const tail = (self.head + self.len) % max_events;
        self.slots[tail] = event;
        self.len += 1;
    }

    /// Copies what is pending into `buffer` and frees those slots. Both sides keep their
    /// capacity, so a queue drained every tick stops allocating after the first batch.
    pub fn drain(self: *Queue, buffer: *std.ArrayList(Event)) void {
        buffer.clearRetainingCapacity();
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        var taken: usize = 0;
        // An append that cannot grow the buffer leaves the rest queued for the next drain.
        while (taken < self.len) {
            buffer.append(self.allocator, self.slots[(self.head + taken) % max_events]) catch break;
            taken += 1;
        }
        self.head = (self.head + taken) % max_events;
        self.len -= taken;
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
    try testing.expectEqual(@as(usize, 0), queue.depth());

    queue.drain(&batch);
    try testing.expectEqual(@as(usize, 0), batch.items.len);
}

test "the ring keeps its order across a wrap" {
    var queue = Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    var batch: std.ArrayList(Event) = .empty;
    defer batch.deinit(testing.allocator);

    for (0..max_events - 1) |index| queue.push(.{ .opened = @intCast(index + 1) });
    queue.drain(&batch);
    try testing.expectEqual(max_events - 1, batch.items.len);

    queue.push(.{ .closed = 11 });
    queue.push(.{ .closed = 12 });
    queue.drain(&batch);
    try testing.expectEqual(@as(usize, 2), batch.items.len);
    try testing.expectEqual(@as(u64, 11), batch.items[0].closed);
    try testing.expectEqual(@as(u64, 12), batch.items[1].closed);
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
    try testing.expectEqual(max_events, queue.depth());
    try testing.expectEqual(@as(usize, 8), queue.droppedCount());
}

test "the oldest events are the ones that survive a full queue" {
    var queue = Queue.init(testing.io, testing.allocator);
    defer queue.deinit();

    for (0..max_events + 1) |index| queue.push(.{ .opened = @intCast(index) });

    var batch: std.ArrayList(Event) = .empty;
    defer batch.deinit(testing.allocator);
    queue.drain(&batch);

    try testing.expectEqual(@as(usize, max_events), batch.items.len);
    try testing.expectEqual(@as(u64, 0), batch.items[0].opened);
    try testing.expectEqual(@as(u64, max_events - 1), batch.items[max_events - 1].opened);
}
