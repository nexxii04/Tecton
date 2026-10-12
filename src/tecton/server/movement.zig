const std = @import("std");
const Timestamp = std.Io.Timestamp;

const Tecton = @import("../tecton.zig").Tecton;
const MoveDelta = @import("../player/move_delta.zig");
const Player = @import("../player/player.zig").Player;
const MovementBroadcast = @import("../network/movement_broadcast.zig");

pub fn flush(tecton: *Tecton) void {
    const started = Timestamp.now(tecton.io, .awake);
    defer {
        const elapsed = started.durationTo(.now(tecton.io, .awake));
        tecton.profiler.record(.movement_broadcast, @intCast(@max(0, elapsed.nanoseconds)));
    }

    const snapshots = tecton.getPlayerSnapshots();
    const bands = tecton.movement_distance_bands and fillViewerPoints(tecton, snapshots);
    const refresh_bands = bands and tecton.tick_count % MovementBroadcast.BAND_REFRESH_TICKS == 0;

    const scratch = tecton.network.scratch.begin();
    defer scratch.deinit();
    const stream = scratch.stream();

    const index = &tecton.players.movement_index;
    const candidates = &tecton.players.movement_candidates;
    const batch = &tecton.players.movement_batch;
    var skipped: usize = 0;
    index.reset();
    for (snapshots) |emitter| {
        if (emitter.pending_removal.load(.acquire)) {
            emitter.pending_move = null;
            continue;
        }

        const state = emitter.pending_move orelse continue;
        const dimension = emitter.entity.dimension orelse {
            emitter.pending_move = null;
            continue;
        };

        const previous = emitter.broadcast_band;
        if (bands and (refresh_bands or previous == null)) {
            const nearest = MovementBroadcast.nearestViewerBand(
                emitter.entity.runtime_id,
                @intFromPtr(dimension),
                emitter.entity.position.x,
                emitter.entity.position.z,
                tecton.players.movement_viewers.items,
            );
            const band = if (nearest) |viewer| viewer.band else null;
            emitter.broadcast_band = band;
        }

        if (bands and emitter.broadcast_band == null) {
            skipped += 1;
            continue;
        }

        const band: u8 = if (bands) emitter.broadcast_band.? else 1;
        const teleport = MoveDelta.isTeleport(&emitter.last_broadcast, state);
        const decision = MovementBroadcast.emission(
            if (bands) previous else 1,
            band,
            tecton.tick_count,
            teleport,
        );
        if (decision.reset and !teleport) emitter.last_broadcast.reset();
        if (!decision.send) {
            skipped += 1;
            continue;
        }

        emitter.pending_move = null;

        const delta = MoveDelta.nextDelta(
            &emitter.last_broadcast,
            @intCast(emitter.entity.runtime_id),
            state,
            tecton.tick_count,
        ) orelse continue;

        const before = stream.getBuffer().len;
        _ = delta.serialize(stream) catch continue;

        const region = MovementBroadcast.regionOf(
            @intFromPtr(dimension),
            emitter.entity.position.x,
            emitter.entity.position.z,
        );
        index.add(
            tecton.allocator,
            region,
            MovementBroadcast.markRef(stream, emitter.entity.runtime_id, before),
        ) catch continue;
    }

    tecton.profiler.count(.movement_skipped, skipped);
    if (index.slots.items.len == 0) return;
    tecton.profiler.count(.movement_emitters, index.slots.items.len);
    index.finish(tecton.allocator) catch return;

    const payload = stream.getBuffer();

    var updates: usize = 0;
    var batches: usize = 0;
    for (snapshots) |viewer| {
        if (!viewer.spawned) continue;
        if (viewer.pending_removal.load(.acquire)) continue;

        const dimension = viewer.entity.dimension orelse continue;

        candidates.clearRetainingCapacity();
        index.collect(
            tecton.allocator,
            candidates,
            @intFromPtr(dimension),
            viewer.entity.position.x,
            viewer.entity.position.z,
            MovementBroadcast.regionRadius(viewer.view_distance),
        ) catch continue;
        if (candidates.items.len == 0) continue;

        var cursor: MovementBroadcast.Cursor = .{};
        while (cursor.bucket < candidates.items.len) {
            batch.clearRetainingCapacity();
            cursor = MovementBroadcast.fillBatch(
                batch,
                tecton.allocator,
                payload,
                index.slots.items,
                index.buckets.items,
                candidates.items,
                cursor,
                viewer.entity.runtime_id,
                viewer.visible_players,
                MovementBroadcast.MAX_BATCH_BYTES,
            );
            if (batch.items.len == 0) break;
            tecton.network.sendPacketsUncompressedWith(viewer.connection, batch.items, tecton.movement_priority) catch {};
            updates += batch.items.len;
            batches += 1;
        }
    }

    tecton.profiler.count(.movement_updates, updates);
    tecton.profiler.count(.movement_batches, batches);
}

fn fillViewerPoints(tecton: *Tecton, snapshots: []const *Player) bool {
    const viewers = &tecton.players.movement_viewers;
    viewers.clearRetainingCapacity();
    for (snapshots) |player| {
        if (!player.spawned) continue;
        if (player.pending_removal.load(.acquire)) continue;
        const dimension = player.entity.dimension orelse continue;
        viewers.append(tecton.allocator, .{
            .runtime_id = player.entity.runtime_id,
            .dimension = @intFromPtr(dimension),
            .x = player.entity.position.x,
            .z = player.entity.position.z,
        }) catch return false;
    }
    return true;
}
