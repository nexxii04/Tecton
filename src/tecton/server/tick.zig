const std = @import("std");
const Timestamp = std.Io.Timestamp;

const Tecton = @import("../tecton.zig").Tecton;
const entities = @import("../world/dimension/entities.zig");
const Events = @import("../events/root.zig");
const Raknet = @import("Raknet");

const packet_drain_budget_pct: u64 = 5;
const drain_completed_budget_pct: u64 = 15;
const main_tasks_budget_pct: u64 = 50;
const save_pass_interval_ticks: u64 = 6000;

pub fn onTick(context: ?*anyopaque) void {
    const tecton = @as(*Tecton, @ptrCast(@alignCast(context)));
    if (tecton.tick_thread_id.load(.monotonic) == 0) {
        tecton.tick_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
    }
    const work_start = Timestamp.now(tecton.io, .awake);
    const target_tps_u64 = @max(@as(u64, 1), @as(u64, tecton.config.max_tps));
    const tick_budget_ns: u64 = std.time.ns_per_s / target_tps_u64;
    const metrics_window_ticks = target_tps_u64;
    tecton.profiler.tick_budget_ns = tick_budget_ns;

    if (tecton.last_tick_started_at) |last_tick_started_at| {
        // last -> now; the reverse is negative and clamps TPS to the target.
        const elapsed = last_tick_started_at.durationTo(work_start).nanoseconds;
        const interval_ns: u64 = @intCast(@max(0, elapsed));
        tecton.tick_interval_accumulator += interval_ns;
        tecton.tick_interval_samples += 1;
    }
    tecton.last_tick_started_at = work_start;

    tecton.tick_count += 1;
    var tick_event = Events.types.ServerTickEvent{ .tick = tecton.tick_count };
    _ = tecton.events.emit(.ServerTick, &tick_event);
    tecton.ecs.tick();

    const raknet_ns: u64 = @intCast(@max(0, tecton.raknet.last_connection_tick_ns.nanoseconds));
    tecton.raknet_time_accumulator += raknet_ns;
    tecton.profiler.record(.raknet_tick, raknet_ns);

    const packet_drain_budget = tick_budget_ns * packet_drain_budget_pct / 100;
    const packet_drain_cap: usize = @max(256, tecton.getPlayerCount() * 8);
    const pd_start = Timestamp.now(tecton.io, .awake);
    const drain_result = tecton.network.drainPackets(packet_drain_budget, packet_drain_cap);
    const pd_end = pd_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.packet_drain, @intCast(@max(0, pd_end.nanoseconds)));

    const decompress_pending = tecton.network.decompress_pending.load(.monotonic);
    const dropped_packets = tecton.network.dropped_packets.load(.monotonic);
    if ((decompress_pending > 256 or dropped_packets > 0) and tecton.tick_count % target_tps_u64 == 0) {
        Raknet.Logger.WARN("Network packet backlog: pending={d} queued={d} dropped={d}", .{
            decompress_pending,
            drain_result.remaining,
            dropped_packets,
        });
    }

    tecton.drainPendingPlayerRemovals();
    tecton.rebuildPlayerSnapshot();

    var phase_start = Timestamp.now(tecton.io, .awake);
    const snapshots = tecton.getPlayerSnapshots();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        player.entity.fireEvent(.Tick, .{&player.entity});
    }
    var phase_end = phase_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.player_tick, @intCast(@max(0, phase_end.nanoseconds)));

    phase_start = Timestamp.now(tecton.io, .awake);
    var worlds_it = tecton.worlds.valueIterator();
    while (worlds_it.next()) |world| {
        var dims_it = world.*.dimensions.valueIterator();
        while (dims_it.next()) |dim| {
            var ent_it = dim.*.entities.valueIterator();
            while (ent_it.next()) |entity| {
                entity.*.fireEvent(.Tick, .{entity.*});
                dim.*.reindexEntity(entity.*);
            }
            entities.flushPendingRemovals(dim.*);
        }
    }
    phase_end = phase_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.world_tick, @intCast(@max(0, phase_end.nanoseconds)));

    const drain_budget = tick_budget_ns * drain_completed_budget_pct / 100;

    phase_start = Timestamp.now(tecton.io, .awake);
    tecton.threaded_tasks.drainCompleted(drain_budget);
    phase_end = phase_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.drain_completed_1, @intCast(@max(0, phase_end.nanoseconds)));

    phase_start = Timestamp.now(tecton.io, .awake);
    _ = tecton.tasks.runUntil(tecton.io, work_start, tick_budget_ns * main_tasks_budget_pct / 100);
    phase_end = phase_start.durationTo(.now(tecton.io, .awake));
    const tasks_ns: u64 = @intCast(@max(0, phase_end.nanoseconds));
    tecton.tasks_time_accumulator += tasks_ns;
    tecton.profiler.record(.main_tasks, tasks_ns);

    phase_start = Timestamp.now(tecton.io, .awake);
    tecton.threaded_tasks.drainCompleted(drain_budget);
    phase_end = phase_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.drain_completed_2, @intCast(@max(0, phase_end.nanoseconds)));

    if (tecton.console_started) tecton.console.drainCommands();
    if (tecton.tick_callback) |callback| callback(tecton.tick_userdata);

    tecton.flushMovementBroadcasts();

    const work_end = work_start.durationTo(.now(tecton.io, .awake));
    const work_ns: u64 = @intCast(@max(0, work_end.nanoseconds));
    const total_tick_ns = raknet_ns + work_ns;
    tecton.work_time_accumulator += work_ns;
    tecton.profiler.recordTick(total_tick_ns);

    if (tecton.tick_count % metrics_window_ticks == 0) {
        tecton.rollMetricsWindow(metrics_window_ticks);
    }

    if (tecton.tick_count % save_pass_interval_ticks == 0) tecton.beginSavePass();
    tecton.tickIncrementalSave();
}
