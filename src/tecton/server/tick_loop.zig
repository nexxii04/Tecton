const std = @import("std");

const max_catch_up_periods: u32 = 5;

pub const Clock = struct {
    io: std.Io,
    period_ns: u64,
    tick_fn: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
    running: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    thread_id: std.atomic.Value(usize) = .init(0),

    pub fn init(io: std.Io, period_ns: u64, tick_fn: *const fn (?*anyopaque) void, ctx: ?*anyopaque) Clock {
        return .{
            .io = io,
            .period_ns = @max(1, period_ns),
            .tick_fn = tick_fn,
            .ctx = ctx,
        };
    }

    pub fn start(self: *Clock) std.Io.ConcurrentError!void {
        if (self.future != null) return;
        self.running.store(true, .release);
        self.thread_id.store(0, .release);
        self.future = try self.io.concurrent(run, .{self});
    }

    pub fn requestStop(self: *Clock) void {
        self.running.store(false, .release);
    }

    pub fn stop(self: *Clock) void {
        self.requestStop();
        if (self.isTickThread()) return;
        if (self.future) |*future| {
            _ = future.cancel(self.io);
            self.future = null;
        }
    }

    pub fn isRunning(self: *const Clock) bool {
        return self.running.load(.acquire);
    }

    pub fn isTickThread(self: *const Clock) bool {
        const id = self.thread_id.load(.acquire);
        return id != 0 and id == @as(usize, @intCast(std.Thread.getCurrentId()));
    }

    fn run(self: *Clock) void {
        self.thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
        defer self.thread_id.store(0, .release);

        const period = std.Io.Duration.fromNanoseconds(@intCast(self.period_ns));
        var deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(period);

        while (self.running.load(.acquire)) {
            const wait_ns = std.Io.Timestamp.now(self.io, .awake).durationTo(deadline).nanoseconds;
            if (wait_ns > 0) {
                self.io.sleep(.fromNanoseconds(wait_ns), .awake) catch return;
            }

            self.tick_fn(self.ctx);

            const after = std.Io.Timestamp.now(self.io, .awake);
            deadline = reanchor(deadline, after, self.period_ns).addDuration(period);
        }
    }
};

fn reanchor(deadline: std.Io.Timestamp, now: std.Io.Timestamp, period_ns: u64) std.Io.Timestamp {
    const behind_ns = now.durationTo(deadline).nanoseconds;
    const cap_ns: i96 = @as(i96, @intCast(period_ns)) * max_catch_up_periods;
    if (behind_ns < -cap_ns) return now;
    return deadline;
}

const TestClock = struct {
    var ticks: std.atomic.Value(usize) = .init(0);

    fn tick(_: ?*anyopaque) void {
        _ = ticks.fetchAdd(1, .monotonic);
    }
};

test "the clock runs its tick on its own thread and stops without leaking it" {
    TestClock.ticks.store(0, .monotonic);
    var clock = Clock.init(std.testing.io, 2 * std.time.ns_per_ms, TestClock.tick, null);
    try clock.start();
    try std.testing.io.sleep(.fromMilliseconds(40), .awake);
    clock.stop();

    const settled = TestClock.ticks.load(.acquire);
    try std.testing.expect(settled >= 3);

    try std.testing.io.sleep(.fromMilliseconds(10), .awake);
    try std.testing.expectEqual(settled, TestClock.ticks.load(.acquire));
    clock.stop();
}

test "a tick that falls behind reanchors once it exceeds the catch-up cap" {
    const period: u64 = 5_000_000;
    const now = std.Io.Timestamp{ .nanoseconds = 100 * period };

    const slightly_late = reanchor(.{ .nanoseconds = 98 * period }, now, period);
    try std.testing.expectEqual(@as(i96, 98 * period), slightly_late.nanoseconds);

    const late = reanchor(.{ .nanoseconds = 10 * period }, now, period);
    try std.testing.expectEqual(now.nanoseconds, late.nanoseconds);
}

test "stopping from another thread joins the tick thread" {
    TestClock.ticks.store(0, .monotonic);
    var clock = Clock.init(std.testing.io, std.time.ns_per_ms, TestClock.tick, null);
    try clock.start();
    try std.testing.expect(clock.isRunning());
    clock.stop();
    try std.testing.expect(!clock.isRunning());
    try std.testing.expect(!clock.isTickThread());
}
