const std = @import("std");

pub const WorkerBuffers = struct {
    pub const HARD_CAPACITY: usize = 4 * 1024 * 1024;
    const MAX_STALL_YIELDS: usize = 1_000_000;

    arenas: [2]std.heap.ArenaAllocator,
    outstanding: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    current: u8 = 0,
    stall_fallbacks: usize = 0,
    hard_capacity: usize = HARD_CAPACITY,
    parent: std.mem.Allocator,

    pub fn init(parent: std.mem.Allocator) WorkerBuffers {
        return .{
            .arenas = .{
                std.heap.ArenaAllocator.init(parent),
                std.heap.ArenaAllocator.init(parent),
            },
            .parent = parent,
        };
    }

    pub fn deinit(self: *WorkerBuffers) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }

    pub fn claim(self: *WorkerBuffers, stop_requested: *const std.atomic.Value(bool)) ?u8 {
        var index = self.current;
        const current_outstanding = self.outstanding[index].load(.acquire);
        if (current_outstanding != 0) {
            const other: u8 = 1 - index;
            if (self.outstanding[other].load(.acquire) == 0) {
                index = other;
            } else if (self.arenas[index].queryCapacity() < self.hard_capacity) {
                self.current = index;
                return index;
            } else {
                var yields: usize = 0;
                while (self.outstanding[0].load(.acquire) != 0 and
                    self.outstanding[1].load(.acquire) != 0)
                {
                    if (stop_requested.load(.acquire) or yields >= MAX_STALL_YIELDS) {
                        self.stall_fallbacks += 1;
                        return null;
                    }
                    std.Thread.yield() catch {};
                    yields += 1;
                }
                index = if (self.outstanding[0].load(.acquire) == 0) 0 else 1;
            }
        }

        _ = self.arenas[index].reset(.retain_capacity);
        self.current = index;
        return index;
    }

    pub fn outstandingCounter(self: *WorkerBuffers, index: u8) *std.atomic.Value(u32) {
        return &self.outstanding[index];
    }
};

const testing = std.testing;

test "claim resets a drained arena and keeps its capacity" {
    var buffers = WorkerBuffers.init(testing.allocator);
    defer buffers.deinit();
    var stop = std.atomic.Value(bool).init(false);

    const first = buffers.claim(&stop).?;
    _ = try buffers.arenas[first].allocator().alloc(u8, 1024);
    const capacity_after_first = buffers.arenas[first].queryCapacity();
    try testing.expect(capacity_after_first >= 1024);

    const second = buffers.claim(&stop).?;
    try testing.expectEqual(first, second);
    try testing.expect(buffers.arenas[first].queryCapacity() >= capacity_after_first);
}

test "claim switches arenas when the active one has outstanding results" {
    var buffers = WorkerBuffers.init(testing.allocator);
    defer buffers.deinit();
    var stop = std.atomic.Value(bool).init(false);

    const first = buffers.claim(&stop).?;
    _ = buffers.outstandingCounter(first).fetchAdd(1, .release);

    const second = buffers.claim(&stop).?;
    try testing.expect(second != first);
    try testing.expectEqual(second, buffers.current);
    _ = buffers.outstandingCounter(second).fetchAdd(1, .release);

    _ = buffers.outstandingCounter(first).fetchSub(1, .acq_rel);
    const third = buffers.claim(&stop).?;
    try testing.expectEqual(first, third);
}

test "claim keeps appending to a pinned arena below the hard cap" {
    var buffers = WorkerBuffers.init(testing.allocator);
    defer buffers.deinit();
    var stop = std.atomic.Value(bool).init(false);

    const first = buffers.claim(&stop).?;
    _ = buffers.outstandingCounter(first).fetchAdd(1, .release);
    const second = buffers.claim(&stop).?;
    _ = buffers.outstandingCounter(second).fetchAdd(1, .release);

    const third = buffers.claim(&stop).?;
    try testing.expectEqual(second, third);
    try testing.expectEqual(@as(usize, 0), buffers.stall_fallbacks);
}

test "claim falls back instead of waiting while stopping" {
    var buffers = WorkerBuffers.init(testing.allocator);
    defer buffers.deinit();
    var stop = std.atomic.Value(bool).init(false);
    buffers.hard_capacity = 0;

    const first = buffers.claim(&stop).?;
    _ = buffers.outstandingCounter(first).fetchAdd(1, .release);
    const second = buffers.claim(&stop).?;
    _ = buffers.outstandingCounter(second).fetchAdd(1, .release);
    try testing.expect(second != first);

    stop.store(true, .release);
    try testing.expectEqual(@as(?u8, null), buffers.claim(&stop));
    try testing.expectEqual(@as(usize, 1), buffers.stall_fallbacks);
}
