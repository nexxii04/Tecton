const std = @import("std");

const Phase = enum {
    raknet_tick,
    player_tick,
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
};

const PHASE_COUNT = @typeInfo(Phase).@"enum".fields.len;

const Stats = struct {
    total_ns: u64 = 0,
    count: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
};

pub const TickProfiler = struct {
    phases: [PHASE_COUNT]Stats = [_]Stats{.{}} ** PHASE_COUNT,
    slow_ticks: u64 = 0,
    total_ticks: u64 = 0,
    tick_budget_ns: u64 = 50_000_000,

    pub fn record(self: *TickProfiler, phase: Phase, ns: u64) void {
        const idx = @intFromEnum(phase);
        self.phases[idx].total_ns += ns;
        self.phases[idx].count += 1;
        if (ns < self.phases[idx].min_ns) self.phases[idx].min_ns = ns;
        if (ns > self.phases[idx].max_ns) self.phases[idx].max_ns = ns;
    }

    pub fn recordTick(self: *TickProfiler, total_ns: u64) void {
        self.total_ticks += 1;
        if (total_ns > self.tick_budget_ns) self.slow_ticks += 1;
        self.record(.total, total_ns);
    }

    pub fn avgTickMs(self: *const TickProfiler) f64 {
        const s = self.phases[@intFromEnum(Phase.total)];
        if (s.count == 0) return 0.0;
        return @as(f64, @floatFromInt(s.total_ns / s.count)) / 1_000_000.0;
    }

    pub fn slowTickPct(self: *const TickProfiler) f64 {
        if (self.total_ticks == 0) return 0.0;
        return @as(f64, @floatFromInt(self.slow_ticks)) / @as(f64, @floatFromInt(self.total_ticks)) * 100.0;
    }
    pub fn writeReport(self: *const TickProfiler, io: std.Io, path: []const u8) void {
        std.Io.Dir.cwd().createDir(io, "dump", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // ok
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

        const pct = if (self.total_ticks > 0)
            @as(f64, @floatFromInt(self.slow_ticks)) / @as(f64, @floatFromInt(self.total_ticks)) * 100.0
        else
            0.0;

        var line = std.fmt.bufPrint(&buf, "Total ticks: {d}\n", .{self.total_ticks}) catch return;
        writer.interface.writeAll(line) catch return;

        line = std.fmt.bufPrint(&buf, "Slow ticks (>{d}ms): {d} ({d:.1}%)\n", .{
            self.tick_budget_ns / 1_000_000,
            self.slow_ticks,
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

        const names = [_][]const u8{
            "raknet_tick",           "player_tick",       "world_tick",
            "drain_completed_1",     "main_tasks",        "drain_completed_2",
            "packet_drain",          "packet_dispatch",   "handler_player_auth",
            "handler_chunk_request", "handler_inventory", "handler_other",
            "total",                 "batch_chunks",      "batch_send",
            "batch_block_data",
        };

        for (0..PHASE_COUNT) |i| {
            const s = self.phases[i];
            if (s.count == 0) continue;
            const avg_ms = @as(f64, @floatFromInt(s.total_ns / s.count)) / 1_000_000.0;
            const min_ms = @as(f64, @floatFromInt(s.min_ns)) / 1_000_000.0;
            const max_ms = @as(f64, @floatFromInt(s.max_ns)) / 1_000_000.0;
            line = std.fmt.bufPrint(&buf, "{s:<25} {d:>10.3} {d:>10.3} {d:>10.3} {d:>10}\n", .{
                names[i], avg_ms, min_ms, max_ms, s.count,
            }) catch continue;
            writer.interface.writeAll(line) catch continue;
        }

        writer.interface.flush() catch |err| {
            std.log.err("failed to flush writer: {}", .{err});
            return;
        };
    }
};
