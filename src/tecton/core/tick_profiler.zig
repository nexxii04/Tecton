const std = @import("std");

pub const Phase = enum {
    raknet_tick,
    player_tick,

    visibility_pass,
    visibility_tracked,
    world_tick,
    drain_completed_1,
    main_tasks,
    drain_completed_2,
    packet_drain,
    packet_dispatch,
    handler_player_auth,
    handler_chunk_request,
    handler_inventory,
    handler_other,
    total,
    batch_chunks,
    batch_send,
    batch_block_data,
    movement_broadcast,
};

const PHASE_COUNT = @typeInfo(Phase).@"enum".fields.len;

pub const Counter = enum {
    movement_emitters,
    movement_skipped,
    movement_updates,
    movement_batches,
};

const COUNTER_COUNT = @typeInfo(Counter).@"enum".fields.len;

const Stats = struct {
    total_ns: u64 = 0,
    count: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
};

pub const TickProfiler = struct {
    phases: [PHASE_COUNT]Stats = [_]Stats{.{}} ** PHASE_COUNT,
    counters: [COUNTER_COUNT]u64 = [_]u64{0} ** COUNTER_COUNT,
    slow_ticks: u64 = 0,
    total_ticks: u64 = 0,
    tick_budget_ns: u64 = 50_000_000,

    pub fn record(self: *TickProfiler, phase: Phase, ns: u64) void {
        const stats = &self.phases[@intFromEnum(phase)];
        _ = @atomicRmw(u64, &stats.total_ns, .Add, ns, .monotonic);
        _ = @atomicRmw(u64, &stats.count, .Add, 1, .monotonic);
        _ = @atomicRmw(u64, &stats.min_ns, .Min, ns, .monotonic);
        _ = @atomicRmw(u64, &stats.max_ns, .Max, ns, .monotonic);
    }

    pub fn count(self: *TickProfiler, counter: Counter, total: usize) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(counter)], .Add, @intCast(total), .monotonic);
    }

    pub fn recordTick(self: *TickProfiler, total_ns: u64) void {
        _ = @atomicRmw(u64, &self.total_ticks, .Add, 1, .monotonic);
        if (total_ns > self.tick_budget_ns) {
            _ = @atomicRmw(u64, &self.slow_ticks, .Add, 1, .monotonic);
        }
        self.record(.total, total_ns);
    }

    pub fn avgTickMs(self: *const TickProfiler) f64 {
        const stats = &self.phases[@intFromEnum(Phase.total)];
        const sample_count = @atomicLoad(u64, &stats.count, .monotonic);
        if (sample_count == 0) return 0.0;
        const total_ns = @atomicLoad(u64, &stats.total_ns, .monotonic);
        return @as(f64, @floatFromInt(total_ns / sample_count)) / 1_000_000.0;
    }

    pub fn slowTickPct(self: *const TickProfiler) f64 {
        const total_ticks = @atomicLoad(u64, &self.total_ticks, .monotonic);
        if (total_ticks == 0) return 0.0;
        const slow_ticks = @atomicLoad(u64, &self.slow_ticks, .monotonic);
        return @as(f64, @floatFromInt(slow_ticks)) / @as(f64, @floatFromInt(total_ticks)) * 100.0;
    }

    pub fn writeReport(self: *const TickProfiler, io: std.Io, path: []const u8) void {
        std.Io.Dir.cwd().createDir(io, "dump", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                return;
            },
        };

        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            std.debug.print("failed to create file: {}\n", .{err});
            return;
        };

        defer file.close(io);

        var buf: [512]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);

        writer.interface.writeAll("=== Tick Profiler Report ===\n") catch return;

        const total_ticks = @atomicLoad(u64, &self.total_ticks, .monotonic);
        const slow_ticks = @atomicLoad(u64, &self.slow_ticks, .monotonic);
        const pct = if (total_ticks > 0)
            @as(f64, @floatFromInt(slow_ticks)) / @as(f64, @floatFromInt(total_ticks)) * 100.0
        else
            0.0;

        var line = std.fmt.bufPrint(&buf, "Total ticks: {d}\n", .{total_ticks}) catch return;
        writer.interface.writeAll(line) catch return;

        line = std.fmt.bufPrint(&buf, "Slow ticks (>{d}ms): {d} ({d:.1}%)\n", .{
            self.tick_budget_ns / 1_000_000,
            slow_ticks,
            pct,
        }) catch return;
        writer.interface.writeAll(line) catch return;
        writer.interface.writeAll("\n") catch return;

        line = std.fmt.bufPrint(&buf, "{s:<25} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
            "Phase", "Avg(ms)", "Min(ms)", "Max(ms)", "Count",
        }) catch return;
        writer.interface.writeAll(line) catch return;

        line = std.fmt.bufPrint(&buf, "{s:-<25} {s:->10} {s:->10} {s:->10} {s:->10}\n", .{
            "", "", "", "", "",
        }) catch return;
        writer.interface.writeAll(line) catch return;

        for (0..PHASE_COUNT) |i| {
            const stats = &self.phases[i];
            const sample_count = @atomicLoad(u64, &stats.count, .monotonic);
            if (sample_count == 0) continue;
            const total_ns = @atomicLoad(u64, &stats.total_ns, .monotonic);
            const min_ns = @atomicLoad(u64, &stats.min_ns, .monotonic);
            const max_ns = @atomicLoad(u64, &stats.max_ns, .monotonic);
            const avg_ms = @as(f64, @floatFromInt(total_ns / sample_count)) / 1_000_000.0;
            const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
            const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;
            line = std.fmt.bufPrint(&buf, "{s:<25} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10}\n", .{
                @tagName(@as(Phase, @enumFromInt(i))), avg_ms, min_ms, max_ms, sample_count,
            }) catch continue;
            writer.interface.writeAll(line) catch continue;
        }

        if (total_ticks > 0) {
            writer.interface.writeAll("\n") catch return;
            writer.interface.writeAll("Counter                   Total    Per tick\n") catch return;
            writer.interface.writeAll("------------------------------- ------------\n") catch return;
            for (0..COUNTER_COUNT) |i| {
                const total = @atomicLoad(u64, &self.counters[i], .monotonic);
                const per_tick = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(total_ticks));
                line = std.fmt.bufPrint(&buf, "{s:<25} {d:>12} {d:>11.2}\n", .{
                    @tagName(@as(Counter, @enumFromInt(i))), total, per_tick,
                }) catch continue;
                writer.interface.writeAll(line) catch continue;
            }
        }

        writer.interface.flush() catch |err| {
            std.log.err("failed to flush writer: {}", .{err});
            return;
        };
    }
};

test "phases and counters accumulate atomically" {
    var profiler: TickProfiler = .{};

    profiler.record(.raknet_tick, 1_000_000);
    profiler.record(.raknet_tick, 3_000_000);
    const stats = &profiler.phases[@intFromEnum(Phase.raknet_tick)];
    try std.testing.expectEqual(@as(u64, 2), @atomicLoad(u64, &stats.count, .monotonic));
    try std.testing.expectEqual(@as(u64, 4_000_000), @atomicLoad(u64, &stats.total_ns, .monotonic));
    try std.testing.expectEqual(@as(u64, 1_000_000), @atomicLoad(u64, &stats.min_ns, .monotonic));
    try std.testing.expectEqual(@as(u64, 3_000_000), @atomicLoad(u64, &stats.max_ns, .monotonic));

    profiler.count(.movement_updates, 3);
    profiler.count(.movement_updates, 2);
    const updates = @atomicLoad(u64, &profiler.counters[@intFromEnum(Counter.movement_updates)], .monotonic);
    try std.testing.expectEqual(@as(u64, 5), updates);
}
