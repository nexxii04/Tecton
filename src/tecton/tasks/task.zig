const std = @import("std");

pub const WorkFn = *const fn (ctx: *anyopaque) void;
pub const CallbackFn = *const fn (ctx: *anyopaque) void;
pub const CleanupFn = *const fn (ctx: *anyopaque) void;

pub const Kind = enum { input, world };

pub const input_queue_capacity: usize = 128;
pub const world_queue_capacity: usize = 512;
pub const completed_queue_capacity: usize = 2048;

pub const ThreadedTask = struct {
    work: WorkFn,
    callback: ?CallbackFn = null,
    cleanup: ?CleanupFn = null,
    ctx: *anyopaque,
    shard_key: u64 = 0,
    kind: Kind = .world,
};

pub const ParallelJob = struct {
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    item_count: usize = 0,

    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    body: *const fn (index: usize, ctx: *anyopaque) void = undefined,
    ctx: *anyopaque = undefined,

    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    pub fn trampoline(raw: *anyopaque) void {
        const self: *ParallelJob = @ptrCast(@alignCast(raw));
        while (true) {
            const index = self.next_index.fetchAdd(1, .monotonic);
            if (index >= self.item_count) break;
            self.body(index, self.ctx);
        }
        if (self.remaining.fetchSub(1, .release) == 1) {
            self.mutex.lock(self.io) catch return;
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }
};
