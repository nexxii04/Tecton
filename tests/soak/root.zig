const std = @import("std");
const builtin = @import("builtin");
const tecton = @import("tecton");

const NetworkHandler = tecton.transport.NetworkHandler;
const TransportFake = tecton.transport.TransportFake;
const Connection = tecton.transport.Connection;
const Compression = tecton.transport.compression.Compression;
const CompressionOptions = tecton.transport.compression.CompressionOptions;
const ThreadedTaskQueue = tecton.tasks.ThreadedTaskQueue;
const alloc_counter = tecton.alloc_counter;

const tick_hz: u64 = 20;
const tick_period_ns: u64 = std.time.ns_per_s / tick_hz;
const drain_budget_ns: u64 = 5 * std.time.ns_per_ms;
const max_sessions: usize = 256;
const max_ticks: usize = 4096;

const Options = struct {
    ticks: usize = 120,
    warmup_ticks: usize = 40,
    join_sessions: usize = 120,
    reconnect_cycles: usize = 100,
    restart_cycles: usize = 100,
    soak_seconds: u64 = 0,
};

const Dispatch = struct {
    packets: usize = 0,

    fn deliver(ctx: *anyopaque, _: *Connection, packets: []const []const u8) void {
        const self: *Dispatch = @ptrCast(@alignCast(ctx));
        self.packets += packets.len;
    }
};

const Harness = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    tasks: ThreadedTaskQueue,
    handler: *NetworkHandler,
    fake: TransportFake,
    dispatch: Dispatch = .{},

    fn create(io: std.Io, allocator: std.mem.Allocator, workers: usize) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);

        self.* = .{
            .io = io,
            .allocator = allocator,
            .tasks = ThreadedTaskQueue.init(io, allocator, workers),
            .handler = undefined,
            .fake = TransportFake.init(allocator),
        };
        try self.tasks.start();
        var handler_ready = false;
        errdefer {
            self.tasks.deinit();
            if (handler_ready) self.handler.deinit();
        }

        self.handler = try NetworkHandler.init(io, allocator, &self.tasks, .{
            .ctx = &self.dispatch,
            .dispatch = Dispatch.deliver,
        });
        handler_ready = true;

        try self.handler.enableInboundRing(512, 1536);
        self.handler.attachPort(self.fake.port());
        return self;
    }

    fn destroy(self: *Harness) void {
        const allocator = self.allocator;
        self.handler.stopInputPump();
        self.tasks.deinit();
        self.handler.deinit();
        self.fake.deinit();
        allocator.destroy(self);
    }

    fn drainAll(self: *Harness) !usize {
        var transferred: usize = 0;
        while (true) {
            const result = self.handler.drainPackets(drain_budget_ns, max_sessions * 8);
            transferred += result.processed;
            self.tasks.drainCompleted(std.math.maxInt(u64));
            if (result.processed == 0 and result.remaining == 0) break;
        }

        var attempts: usize = 0;
        while (self.handler.decompress_pending.load(.monotonic) != 0 and attempts < 5000) : (attempts += 1) {
            self.tasks.drainCompleted(std.math.maxInt(u64));
            try self.io.sleep(.fromNanoseconds(1_000_000), .awake);
        }
        if (self.handler.decompress_pending.load(.monotonic) != 0) return error.DecompressWorkPending;
        return transferred;
    }
};

const TickStats = struct {
    max_pending: usize = 0,
    max_depth: usize = 0,
};

const Checks = struct {
    failures: usize = 0,

    fn expect(self: *Checks, condition: bool, comptime message: []const u8, args: anytype) void {
        if (condition) return;
        self.failures += 1;
        std.debug.print("FAIL: " ++ message ++ "\n", args);
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const base = gpa.allocator();

    const io = init.io;
    const options = parseOptions(init, base) catch |err| {
        std.debug.print("invalid arguments: {s}\n", .{@errorName(err)});
        _ = gpa.deinit();
        return err;
    };

    if (!alloc_counter.install(base)) {
        std.debug.print("the allocation counter is already bound in this process\n", .{});
        _ = gpa.deinit();
        return error.CounterAlreadyInstalled;
    }
    const allocator = alloc_counter.allocator();

    std.debug.print("Tecton transport soak | zig {s} | {s} | ticks={d} warmup={d} soak={d}s\n", .{
        builtin.zig_version_string,
        @tagName(builtin.mode),
        options.ticks,
        options.warmup_ticks,
        options.soak_seconds,
    });
    if (builtin.os.tag == .linux) std.debug.print("pid {d}\n", .{std.os.linux.getpid()});

    var checks: Checks = .{};
    try runScenarios(io, allocator, options, &checks);

    const leaked = gpa.deinit();
    if (leaked == .leak) {
        std.debug.print("FAIL: the debug allocator found leaked memory\n", .{});
        std.process.exit(1);
    }

    if (checks.failures != 0) {
        std.debug.print("{d} check(s) failed\n", .{checks.failures});
        std.process.exit(1);
    }
    std.debug.print("all checks passed, no leaks\n", .{});
}

fn runScenarios(io: std.Io, allocator: std.mem.Allocator, options: Options, checks: *Checks) !void {
    const frame = try makeFrame(allocator, 512);
    defer allocator.free(frame);

    try idleScenario(io, allocator, checks);
    try loadScenario(io, allocator, "10 sessions", 10, options.ticks, options.warmup_ticks, 2, frame, checks);
    try loadScenario(io, allocator, "20 sessions", 20, options.ticks, options.warmup_ticks, 2, frame, checks);
    try loadScenario(io, allocator, "50 sessions", 50, options.ticks, options.warmup_ticks, 2, frame, checks);
    try channelScenario(io, allocator, checks);
    try joinStorm(io, allocator, options.join_sessions, frame, checks);
    try reconnectStorm(io, allocator, options.reconnect_cycles, frame, checks);
    try restartStorm(io, allocator, options.restart_cycles, frame, checks);
    if (options.soak_seconds > 0) try soak(io, allocator, options.soak_seconds, frame, checks);
}

fn idleScenario(io: std.Io, allocator: std.mem.Allocator, checks: *Checks) !void {
    const harness = try Harness.create(io, allocator, 2);
    defer harness.destroy();

    var samples: [max_ticks]u64 = undefined;
    const ticks = 40;
    const mark = alloc_counter.mark();
    for (samples[0..ticks]) |*sample| {
        const started = std.Io.Timestamp.now(io, .awake);
        _ = harness.handler.drainPackets(drain_budget_ns, 4096);
        harness.tasks.drainCompleted(std.math.maxInt(u64));
        sample.* = elapsedNs(started, io);
        io.sleep(.fromNanoseconds(tick_period_ns / 4), .awake) catch {};
    }
    const allocations = alloc_counter.since(mark).allocations;

    reportRow("idle (0 sessions)", samples[0..ticks], 0, allocations, "no traffic");
    checks.expect(allocations == 0, "idle drains allocated {d} times", .{allocations});
}

fn loadScenario(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    sessions: usize,
    ticks: usize,
    warmup_ticks: usize,
    packets_per_tick: usize,
    frame: []const u8,
    checks: *Checks,
) !void {
    const harness = try Harness.create(io, allocator, 2);
    defer harness.destroy();

    var connections: [max_sessions]*Connection = undefined;
    for (connections[0..sessions]) |*slot| slot.* = try harness.handler.connections.create(@ptrCast(&harness.fake));
    defer for (connections[0..sessions]) |conn| harness.handler.connections.closeAndRelease(conn);

    runTicks(io, harness, connections[0..sessions], warmup_ticks, packets_per_tick, frame, null, null);
    // Warm-up callbacks can land after the reset; flush them so the measured window is clean.
    _ = try harness.drainAll();
    harness.dispatch.packets = 0;

    const mark = alloc_counter.mark();
    var samples: [max_ticks]u64 = undefined;
    var stats: TickStats = .{};
    const clamped_ticks = @min(ticks, max_ticks);
    runTicks(io, harness, connections[0..sessions], clamped_ticks, packets_per_tick, frame, samples[0..clamped_ticks], &stats);
    const allocations = alloc_counter.since(mark).allocations;
    const flush_started = std.Io.Timestamp.now(io, .awake);
    _ = try harness.drainAll();
    const flush_ms = @as(f64, @floatFromInt(elapsedNs(flush_started, io))) / 1_000_000.0;

    const packets = sessions * clamped_ticks * packets_per_tick;
    const dispatched = harness.dispatch.packets;
    const elapsed_s = @as(f64, @floatFromInt(clamped_ticks * tick_period_ns)) / @as(f64, std.time.ns_per_s);
    const throughput = @as(f64, @floatFromInt(packets)) / elapsed_s;

    reportRow(name, samples[0..clamped_ticks], throughput, allocations, "2 packets per session tick");
    std.debug.print("  {s}: backlog pending<={d} ring<={d}, full drain after load {d:.2} ms\n", .{ name, stats.max_pending, stats.max_depth, flush_ms });
    checks.expect(dispatched == packets, "{s}: dispatched {d} of {d} packets", .{ name, dispatched, packets });
    checks.expect(allocations == 0, "{s}: steady state allocated {d} times", .{ name, allocations });
    checks.expect(harness.handler.inboundDroppedCount() == 0, "{s}: {d} inbound drops", .{ name, harness.handler.inboundDroppedCount() });
    checks.expect(harness.handler.backpressureSendCount() == 0, "{s}: {d} backpressured sends", .{ name, harness.handler.backpressureSendCount() });
}

fn runTicks(
    io: std.Io,
    harness: *Harness,
    connections: []const *Connection,
    ticks: usize,
    packets_per_tick: usize,
    frame: []const u8,
    samples: ?[]u64,
    stats: ?*TickStats,
) void {
    var deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromNanoseconds(tick_period_ns));
    for (0..ticks) |index| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (connections) |conn| {
            for (0..packets_per_tick) |_| NetworkHandler.onPacket(harness.handler, conn, frame);
        }
        _ = harness.handler.drainPackets(drain_budget_ns, max_sessions * 8);
        harness.tasks.drainCompleted(std.math.maxInt(u64));

        if (samples) |entries| entries[index] = elapsedNs(started, io);
        if (stats) |entries| {
            entries.max_pending = @max(entries.max_pending, harness.handler.decompress_pending.load(.monotonic));
            if (harness.handler.inbound_ring) |ring| entries.max_depth = @max(entries.max_depth, ring.depth());
        }

        const wait_ns = std.Io.Timestamp.now(io, .awake).durationTo(deadline).nanoseconds;
        if (wait_ns > 0) io.sleep(.fromNanoseconds(wait_ns), .awake) catch return;
        deadline = deadline.addDuration(.fromNanoseconds(tick_period_ns));
    }
}

fn channelScenario(io: std.Io, allocator: std.mem.Allocator, checks: *Checks) !void {
    const harness = try Harness.create(io, allocator, 1);
    defer harness.destroy();
    harness.fake.payload_limit = 1200;

    const conn = try harness.handler.connections.create(@ptrCast(&harness.fake));
    defer harness.handler.connections.closeAndRelease(conn);

    // A movement batch tops out at 936 bytes, well inside one negotiated message.
    var wire: [10][93]u8 = undefined;
    var packets: [10][]const u8 = undefined;
    for (&wire, 0..) |*packet, index| {
        @memset(packet, @truncate(index));
        packets[index] = packet;
    }
    try harness.handler.sendPacketsUncompressedOn(conn, &packets, .unreliable, .immediate);

    checks.expect(harness.fake.sent.items.len == 1, "unreliable batch used {d} frames instead of 1", .{harness.fake.sent.items.len});
    checks.expect(harness.fake.sent.items[0].channel == .unreliable, "the movement frame left on the reliable channel", .{});
    checks.expect(harness.fake.sent.items[0].bytes.len <= harness.fake.payload_limit, "the movement frame exceeds the negotiated message", .{});
    checks.expect(harness.handler.outboundDroppedCount() == 0, "a successful send dropped {d} frames", .{harness.handler.outboundDroppedCount()});

    harness.fake.clear();
    var split_wire: [2][700]u8 = undefined;
    for (&split_wire) |*packet| @memset(packet, 0xA5);
    const split = [_][]const u8{ &split_wire[0], &split_wire[1] };
    try harness.handler.sendPacketsUncompressedOn(conn, &split, .unreliable, .immediate);
    checks.expect(harness.fake.sent.items.len == 2, "a split batch used {d} frames instead of 2", .{harness.fake.sent.items.len});
    for (harness.fake.sent.items) |entry| {
        checks.expect(entry.channel == .unreliable, "a split frame changed channel", .{});
        checks.expect(entry.bytes.len <= harness.fake.payload_limit, "a split frame exceeds the negotiated message", .{});
    }

    harness.fake.clear();
    const oversize = [_]u8{0x11} ** 1400;
    const one = [_][]const u8{&oversize};
    if (harness.handler.sendPacketsUncompressedOn(conn, &one, .unreliable, .immediate)) |_| {
        checks.expect(false, "an oversize unreliable frame was sent instead of refused", .{});
    } else |err| {
        checks.expect(err == error.PayloadTooLarge, "an oversize unreliable frame failed with {s}", .{@errorName(err)});
    }
    checks.expect(harness.fake.sent.items.len == 0, "an oversize unreliable frame still reached the port", .{});
    checks.expect(harness.handler.oversizeSendCount() == 1, "oversize count is {d} instead of 1", .{harness.handler.oversizeSendCount()});
    checks.expect(harness.handler.outboundDroppedCount() == 1, "outbound drop count is {d} instead of 1", .{harness.handler.outboundDroppedCount()});

    std.debug.print("movement channel: 930 B in 1 frame, 1400 B batch in 2 frames, oversize refused\n", .{});
}

fn joinStorm(io: std.Io, allocator: std.mem.Allocator, sessions: usize, frame: []const u8, checks: *Checks) !void {
    const harness = try Harness.create(io, allocator, 2);
    defer harness.destroy();

    const clamped = @min(sessions, max_sessions);
    var connections: [max_sessions]*Connection = undefined;

    const started = std.Io.Timestamp.now(io, .awake);
    for (connections[0..clamped]) |*slot| slot.* = try harness.handler.connections.create(@ptrCast(&harness.fake));
    const elapsed = elapsedNs(started, io);

    for (connections[0..clamped]) |conn| NetworkHandler.onPacket(harness.handler, conn, frame);
    _ = try harness.drainAll();

    const counts = harness.handler.sessionCounts();
    const per_session_us = @as(f64, @floatFromInt(elapsed)) / 1000.0 / @as(f64, @floatFromInt(clamped));
    std.debug.print("join storm: {d} sessions in {d:.2} ms ({d:.1} us/session), active={d}\n", .{
        clamped,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        per_session_us,
        counts.active,
    });

    checks.expect(counts.active == clamped, "join storm: {d} of {d} sessions registered", .{ counts.active, clamped });
    checks.expect(harness.dispatch.packets == clamped, "join storm: {d} of {d} packets dispatched", .{ harness.dispatch.packets, clamped });

    for (connections[0..clamped]) |conn| harness.handler.connections.closeAndRelease(conn);
}

fn reconnectStorm(io: std.Io, allocator: std.mem.Allocator, cycles: usize, frame: []const u8, checks: *Checks) !void {
    const harness = try Harness.create(io, allocator, 2);
    defer harness.destroy();

    const started = std.Io.Timestamp.now(io, .awake);
    for (0..cycles) |_| {
        const conn = try harness.handler.connections.createWithId(7, @ptrCast(&harness.fake));
        NetworkHandler.onPacket(harness.handler, conn, frame);
        _ = try harness.drainAll();
        harness.handler.connections.closeAndRelease(conn);
    }
    const elapsed = elapsedNs(started, io);

    const counts = harness.handler.sessionCounts();
    std.debug.print("reconnect storm: {d} cycles in {d:.2} ms, active={d} total={d} reconnects={d}\n", .{
        cycles,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        counts.active,
        counts.total,
        counts.reconnects,
    });

    checks.expect(counts.active == 0, "reconnect storm: {d} sessions still active", .{counts.active});
    checks.expect(counts.total == cycles, "reconnect storm: total {d}, expected {d}", .{ counts.total, cycles });
    checks.expect(counts.reconnects + 1 == cycles, "reconnect storm: {d} reconnects, expected {d}", .{ counts.reconnects, cycles - 1 });
}

fn restartStorm(io: std.Io, allocator: std.mem.Allocator, cycles: usize, frame: []const u8, checks: *Checks) !void {
    const started = std.Io.Timestamp.now(io, .awake);
    for (0..cycles) |_| {
        const harness = try Harness.create(io, allocator, 2);
        var connections: [10]*Connection = undefined;
        for (&connections) |*slot| slot.* = try harness.handler.connections.create(@ptrCast(&harness.fake));
        for (connections) |conn| NetworkHandler.onPacket(harness.handler, conn, frame);
        _ = try harness.drainAll();
        for (connections) |conn| harness.handler.connections.closeAndRelease(conn);
        harness.destroy();
    }
    const elapsed = elapsedNs(started, io);
    std.debug.print("start/stop: {d} cycles with 10 sessions in {d:.2} ms ({d:.2} ms/cycle)\n", .{
        cycles,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0 / @as(f64, @floatFromInt(cycles)),
    });
    checks.expect(elapsed > 0, "start/stop did not run", .{});
}

fn soak(io: std.Io, allocator: std.mem.Allocator, seconds: u64, frame: []const u8, checks: *Checks) !void {
    const harness = try Harness.create(io, allocator, 2);
    defer harness.destroy();

    var connections: [20]*Connection = undefined;
    for (&connections) |*slot| slot.* = try harness.handler.connections.create(@ptrCast(&harness.fake));
    defer for (connections) |conn| harness.handler.connections.closeAndRelease(conn);

    const total_ticks: usize = @intCast(seconds * tick_hz);
    var deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromNanoseconds(tick_period_ns));
    const started = std.Io.Timestamp.now(io, .awake);

    for (0..total_ticks) |index| {
        for (connections) |conn| {
            for (0..2) |_| NetworkHandler.onPacket(harness.handler, conn, frame);
        }
        _ = harness.handler.drainPackets(drain_budget_ns, max_sessions * 8);
        harness.tasks.drainCompleted(std.math.maxInt(u64));

        if (index % (tick_hz * 30) == 0 and index != 0) {
            std.debug.print("soak: t={d}s dispatched={d} inbound_dropped={d} backpressure={d} out_dropped={d}\n", .{
                index / tick_hz,
                harness.dispatch.packets,
                harness.handler.inboundDroppedCount(),
                harness.handler.backpressureSendCount(),
                harness.handler.outboundDroppedCount(),
            });
        }

        const wait_ns = std.Io.Timestamp.now(io, .awake).durationTo(deadline).nanoseconds;
        if (wait_ns > 0) io.sleep(.fromNanoseconds(wait_ns), .awake) catch break;
        deadline = deadline.addDuration(.fromNanoseconds(tick_period_ns));
    }

    _ = try harness.drainAll();
    const elapsed = elapsedNs(started, io);
    std.debug.print("soak: {d}s, {d} packets dispatched, {d} inbound dropped, {d} outbound backpressure\n", .{
        @as(u64, @intCast(elapsed / std.time.ns_per_s)),
        harness.dispatch.packets,
        harness.handler.inboundDroppedCount(),
        harness.handler.backpressureSendCount(),
    });
    checks.expect(harness.handler.inboundDroppedCount() == 0, "soak: {d} inbound drops", .{harness.handler.inboundDroppedCount()});
    checks.expect(harness.handler.backpressureSendCount() == 0, "soak: {d} backpressured sends", .{harness.handler.backpressureSendCount()});
}

fn makeFrame(allocator: std.mem.Allocator, payload_len: usize) ![]u8 {
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);

    var state: u32 = 0x1234_5678;
    for (payload) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }

    const options = CompressionOptions{ .compression_method = .Zlib, .compression_threshold = 255 };
    const packets = [_][]const u8{payload};
    const capacity = Compression.frameCapacity(&packets, options);
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    const framed = try Compression.compressInto(&packets, options, buffer);
    return allocator.dupe(u8, framed);
}

fn reportRow(name: []const u8, samples: []u64, throughput: f64, allocations: usize, note: []const u8) void {
    const p50 = percentile(samples, 50);
    const p95 = percentile(samples, 95);
    const p99 = percentile(samples, 99);
    std.debug.print("| {s} | {d:.1} | {d:.1} | {d:.1} | {d:.0} | {d} | {s} |\n", .{
        name,
        @as(f64, @floatFromInt(p50)) / 1000.0,
        @as(f64, @floatFromInt(p95)) / 1000.0,
        @as(f64, @floatFromInt(p99)) / 1000.0,
        throughput,
        allocations,
        note,
    });
}

fn percentile(samples: []u64, p: usize) u64 {
    if (samples.len == 0) return 0;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const index = @min(samples.len - 1, (samples.len - 1) * p / 100);
    return samples[index];
}

fn elapsedNs(started: std.Io.Timestamp, io: std.Io) u64 {
    const delta = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(0, delta));
}

fn parseOptions(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var result: Options = .{};

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();

    while (args.next()) |arg| {
        const next = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, arg, "--ticks")) {
            result.ticks = try std.fmt.parseInt(usize, next, 10);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            result.warmup_ticks = try std.fmt.parseInt(usize, next, 10);
        } else if (std.mem.eql(u8, arg, "--join-sessions")) {
            result.join_sessions = try std.fmt.parseInt(usize, next, 10);
        } else if (std.mem.eql(u8, arg, "--reconnects")) {
            result.reconnect_cycles = try std.fmt.parseInt(usize, next, 10);
        } else if (std.mem.eql(u8, arg, "--restarts")) {
            result.restart_cycles = try std.fmt.parseInt(usize, next, 10);
        } else if (std.mem.eql(u8, arg, "--soak-seconds")) {
            result.soak_seconds = try std.fmt.parseInt(u64, next, 10);
        } else {
            return error.UnknownArgument;
        }
    }

    result.ticks = @min(result.ticks, max_ticks);
    result.join_sessions = @min(result.join_sessions, max_sessions);
    return result;
}
