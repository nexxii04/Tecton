const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");

const Raknet = @import("Raknet");

const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const Chunk = @import("../../world/chunk/chunk.zig").Chunk;
const DimensionModule = @import("../../world/dimension/dimension.zig");
const Dimension = DimensionModule.Dimension;
const generation = @import("./chunk_generation.zig");

const ChunkStreamState = struct {
    tecton: *Tecton,
    dimension: *Dimension,
    runtime_id: i64,
    allocator: std.mem.Allocator,
    center_x: i32,
    center_z: i32,
    radius: i32,
    ring: i32,
    ring_idx: i32,
    inflight: u32,
    destroy_pending: bool = false,
    upgrade_coords: []generation.ChunkCoord,
    upgrade_hashes: []i64,
    upgrade_idx: usize,
};

const MAX_INFLIGHT_BATCHES: u32 = 4;

pub fn queueChunkStreaming(player: *Player) !void {
    const tecton = player.tecton;
    const dimension = player.entity.dimension orelse return;
    const allocator = player.entity.allocator;

    tecton.tasks.cancelByOwner("chunk_streaming", player.entity.runtime_id, destroyStreamState);

    const center_x = @as(i32, @intFromFloat(@floor(player.entity.position.x))) >> 4;
    const center_z = @as(i32, @intFromFloat(@floor(player.entity.position.z))) >> 4;
    const radius = player.view_distance;
    const sim_dist = dimension.simulation_distance;

    var stale_hashes = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
    defer stale_hashes.deinit(allocator);
    var upgrade_hashes = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
    defer upgrade_hashes.deinit(allocator);

    var it = player.sent_chunks.keyIterator();
    while (it.next()) |key| {
        const coords = Protocol.ChunkCoords.unhash(key.*);
        const dx = coords.x - center_x;
        const dz = coords.z - center_z;
        if (dx * dx + dz * dz > radius * radius) {
            stale_hashes.append(allocator, key.*) catch {};
            continue;
        }

        if (dx * dx + dz * dz <= sim_dist * sim_dist and dimension.getChunk(coords.x, coords.z) == null) {
            upgrade_hashes.append(allocator, key.*) catch {};
        }
    }

    for (stale_hashes.items) |h| {
        _ = player.sent_chunks.remove(h);
    }
    dimension.releaseUnrenderedChunks(stale_hashes.items);

    const state_upgrade_coords = allocator.alloc(generation.ChunkCoord, upgrade_hashes.items.len) catch return error.OutOfMemory;
    errdefer allocator.free(state_upgrade_coords);
    const state_upgrade_hashes = allocator.alloc(i64, upgrade_hashes.items.len) catch return error.OutOfMemory;
    errdefer allocator.free(state_upgrade_hashes);

    for (upgrade_hashes.items, 0..) |h, i| {
        const coords = Protocol.ChunkCoords.unhash(h);
        state_upgrade_coords[i] = .{ .x = coords.x, .z = coords.z };
        state_upgrade_hashes[i] = h;
    }

    const state = try allocator.create(ChunkStreamState);
    state.* = .{
        .tecton = tecton,
        .dimension = dimension,
        .runtime_id = player.entity.runtime_id,
        .allocator = allocator,
        .center_x = center_x,
        .center_z = center_z,
        .radius = radius,
        .ring = 0,
        .ring_idx = 0,
        .inflight = 0,
        .upgrade_coords = state_upgrade_coords,
        .upgrade_hashes = state_upgrade_hashes,
        .upgrade_idx = 0,
    };

    errdefer allocator.destroy(state);
    try tecton.tasks.enqueue(.{
        .func = chunkStreamStep,
        .ctx = @ptrCast(state),
        .name = "chunk_streaming",
        .owner_id = player.entity.runtime_id,
        .cleanup = destroyStreamState,
    });
}

pub fn destroyStreamState(ctx: *anyopaque) void {
    const state: *ChunkStreamState = @ptrCast(@alignCast(ctx));
    if (state.inflight > 0) {
        state.destroy_pending = true;
        return;
    }
    freeStreamState(state);
}

fn freeStreamState(state: *ChunkStreamState) void {
    state.allocator.free(state.upgrade_coords);
    state.allocator.free(state.upgrade_hashes);
    state.allocator.destroy(state);
}

fn sendCachedChunkPacket(conn: *Raknet.Connection, cached: []const u8) void {
    conn.sendReliableMessage(cached, .Normal);
}

fn onBatchComplete(ctx: *anyopaque) void {
    const work: *generation.ChunkBatchWork = @ptrCast(@alignCast(ctx));
    std.debug.assert(work.dimension.inflight_batches > 0);
    work.dimension.inflight_batches -= 1;
    const allocator = work.allocator;
    defer {
        if (work.owner_state) |owner| onBatchOwnedComplete(@ptrCast(@alignCast(owner)));
        releaseCachedPackets(allocator, work.cached_packets);
        allocator.free(work.coords);
        allocator.free(work.hashes);
        allocator.free(work.in_simulation);
        allocator.free(work.packets);
        allocator.free(work.cached_packets);
        allocator.free(work.chunks);
        generation.freeBlockDataSlice(allocator, work.block_data, work.count);
        work.arena.deinit();
        allocator.destroy(work);
    }

    const player = work.tecton.players.byRuntimeId(work.runtime_id) orelse {
        for (0..work.count) |i| {
            if (work.packets[i].len > 0) allocator.free(work.packets[i]);
            if (work.chunks[i]) |chunk| {
                var c = chunk;
                c.deinit();
                allocator.destroy(c);
            }
        }
        return;
    };

    if (player.entity.dimension != work.dimension) {
        for (0..work.count) |i| {
            if (work.packets[i].len > 0) allocator.free(work.packets[i]);
            if (work.chunks[i]) |chunk| {
                var c = chunk;
                c.deinit();
                allocator.destroy(c);
            }
        }
        return;
    }

    const dimension: ?*Dimension = work.dimension;

    var t0 = std.Io.Timestamp.now(work.tecton.io, .awake);
    for (0..work.count) |i| {
        if (work.chunks[i]) |chunk| {
            if (dimension) |dim| {
                if (work.in_simulation[i]) {
                    const hash = @import("../../world/dimension/dimension.zig").chunkHash(chunk.x, chunk.z);
                    if (dim.chunks.get(hash) != null) {
                        var c = chunk;
                        c.deinit();
                        allocator.destroy(c);
                        work.chunks[i] = null;
                        continue;
                    }
                    dim.chunks.put(hash, chunk) catch {
                        var c = chunk;
                        c.deinit();
                        allocator.destroy(c);
                        work.chunks[i] = null;
                        continue;
                    };
                } else {
                    var c = chunk;
                    c.deinit();
                    allocator.destroy(c);
                    work.chunks[i] = null;
                }
            } else {
                var c = chunk;
                c.deinit();
                allocator.destroy(c);
            }
        }
    }
    var t1 = std.Io.Timestamp.now(work.tecton.io, .awake);
    work.tecton.profiler.record(.batch_chunks, @intCast(@max(0, t0.durationTo(t1).nanoseconds)));

    t0 = std.Io.Timestamp.now(work.tecton.io, .awake);
    if (work.send_chunk_packets) {
        if (dimension) |dim| {
            for (0..work.count) |i| {
                if (work.in_simulation[i]) continue;
                const cached = work.cached_packets[i];
                if (cached.len == 0) continue;
                dim.putCachedChunkPacket(work.hashes[i], cached);
                work.cached_packets[i] = &.{};
            }
        }

        for (0..work.count) |i| {
            const compressed = work.packets[i];
            if (compressed.len == 0) continue;
            player.connection.sendReliableMessage(compressed, .Normal);
            allocator.free(compressed);
            work.packets[i] = &.{};
        }

        for (0..work.count) |i| {
            _ = player.pending_chunks.remove(work.hashes[i]);
            if ((work.delivery_mask >> @intCast(i)) & 1 != 0) {
                player.sent_chunks.put(work.hashes[i], {}) catch {};
            }
        }
    }

    t1 = std.Io.Timestamp.now(work.tecton.io, .awake);
    work.tecton.profiler.record(.batch_send, @intCast(@max(0, t0.durationTo(t1).nanoseconds)));

    t0 = std.Io.Timestamp.now(work.tecton.io, .awake);
    if (dimension) |dim| {
        for (0..work.count) |i| {
            if (work.chunks[i] == null or !work.in_simulation[i]) continue;

            {
                generation.applyParsedBlockData(allocator, dim, &work.block_data[i]);
                dim.world.provider.readChunkEntities(work.chunks[i].?, dim) catch |err| {
                    Raknet.Logger.WARN("Failed to restore actors for chunk {d},{d}: {s}", .{
                        work.coords[i].x, work.coords[i].z, @errorName(err),
                    });
                };
            }
        }

        if (work.count > 0) {
            sendChunkBlockActorData(allocator, dim, player, work);
        }
    }
    t1 = std.Io.Timestamp.now(work.tecton.io, .awake);
    work.tecton.profiler.record(.batch_block_data, @intCast(@max(0, t0.durationTo(t1).nanoseconds)));
}

fn releaseCachedPackets(allocator: std.mem.Allocator, cached_packets: []const []const u8) void {
    for (cached_packets) |packet| {
        if (packet.len > 0) allocator.free(packet);
    }
}

fn blockEntityTypeId(block_identifier: []const u8) []const u8 {
    if (std.mem.eql(u8, block_identifier, "minecraft:barrel")) return "Barrel";
    if (std.mem.eql(u8, block_identifier, "minecraft:chest")) return "Chest";
    if (std.mem.eql(u8, block_identifier, "minecraft:trapped_chest")) return "TrappedChest";
    return block_identifier;
}

fn sendChunkBlockActorData(allocator: std.mem.Allocator, dim: *Dimension, player: *Player, work: *const generation.ChunkBatchWork) void {
    for (0..work.count) |i| {
        const coord = work.coords[i];
        if (work.in_simulation[i] and dim.getChunk(coord.x, coord.z) != null) {
            sendLiveBlockActorDataForChunk(allocator, player, dim, coord.x, coord.z);
            continue;
        }

        const data = work.block_data[i];
        for (data.parsed_entities) |entity| {
            const nbt_bytes = entity.nbt_data orelse continue;
            var stream = BinaryStream.init(allocator, nbt_bytes, null);
            var tag = NBT.CompoundTag.read(&stream, allocator, NBT.ReadWriteOptions.default) catch continue;
            defer tag.deinit(allocator);

            const position = Protocol.BlockPosition{
                .x = entity.x,
                .y = entity.y,
                .z = entity.z,
            };

            var s = BinaryStream.init(allocator, null, null);
            defer s.deinit();
            const pkt = Protocol.BlockActorDataPacket{
                .position = position,
                .nbt = tag,
            };
            const serialized = pkt.serialize(&s, allocator) catch continue;
            player.network.sendPacket(player.connection, serialized) catch {};
            sendTileFixAt(allocator, player, dim, position);
        }
    }
}

fn sendLiveBlockActorDataForChunk(allocator: std.mem.Allocator, player: *Player, dim: *Dimension, cx: i32, cz: i32) void {
    for (dim.getBlocksInChunk(cx, cz)) |block| {
        var has_serialize = false;
        for (block.traits.items) |inst| {
            if (inst.vtable.on_serialize != null) {
                has_serialize = true;
                break;
            }
        }
        if (!has_serialize) continue;

        var tag = NBT.CompoundTag.init(allocator, null);
        defer tag.deinit(allocator);
        const id_value = allocator.dupe(u8, blockEntityTypeId(block.getIdentifier())) catch continue;
        tag.set("id", .{ .String = NBT.StringTag.init(id_value, null) }) catch continue;
        tag.set("x", .{ .Int = NBT.IntTag.init(block.position.x, null) }) catch continue;
        tag.set("y", .{ .Int = NBT.IntTag.init(block.position.y, null) }) catch continue;
        tag.set("z", .{ .Int = NBT.IntTag.init(block.position.z, null) }) catch continue;
        block.fireEvent(.Serialize, .{&tag});

        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();
        const pkt = Protocol.BlockActorDataPacket{
            .position = block.position,
            .nbt = tag,
        };
        const serialized = pkt.serialize(&stream, allocator) catch continue;
        player.network.sendPacket(player.connection, serialized) catch {};
        sendTileFixAt(allocator, player, dim, block.position);
    }
}

fn sendTileFixAt(allocator: std.mem.Allocator, player: *Player, dim: *Dimension, position: Protocol.BlockPosition) void {
    const block = dim.getBlockPtr(position) orelse return;
    const perm = block.getPermutation(0) catch return;
    const block_ids = [_]u32{ 0, @bitCast(perm.network_id) };

    for (block_ids) |network_id| {
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();
        const packet = Protocol.UpdateBlockPacket{
            .position = position,
            .network_block_id = network_id,
        };
        const serialized = packet.serialize(&stream) catch continue;
        player.network.sendPacket(player.connection, serialized) catch {};
    }
}

fn cleanupBatchWork(ctx: *anyopaque) void {
    const work: *generation.ChunkBatchWork = @ptrCast(@alignCast(ctx));
    std.debug.assert(work.dimension.inflight_batches > 0);
    work.dimension.inflight_batches -= 1;
    const allocator = work.allocator;
    if (work.owner_state) |owner| onBatchOwnedComplete(@ptrCast(@alignCast(owner)));
    for (0..work.count) |i| {
        if (work.packets[i].len > 0) allocator.free(work.packets[i]);
        if (work.chunks[i]) |chunk| {
            var c = chunk;
            c.deinit();
            allocator.destroy(c);
        }
    }
    allocator.free(work.coords);
    allocator.free(work.hashes);
    allocator.free(work.in_simulation);
    allocator.free(work.packets);
    releaseCachedPackets(allocator, work.cached_packets);
    allocator.free(work.cached_packets);
    allocator.free(work.chunks);
    generation.freeBlockDataSlice(allocator, work.block_data, work.count);
    work.arena.deinit();
    allocator.destroy(work);
}

fn onBatchOwnedComplete(state: *ChunkStreamState) void {
    if (state.inflight > 0) state.inflight -= 1;
    if (state.destroy_pending and state.inflight == 0) {
        freeStreamState(state);
    }
}

fn flushChunkStateForStreaming(dimension: *Dimension, x: i32, z: i32) void {
    const chunk = dimension.getChunk(x, z) orelse return;
    if (dimension.getBlocksInChunk(x, z).len > 0) {
        dimension.world.provider.writeBlockEntities(chunk, dimension) catch {};
    }
    if (chunk.dirty) {
        dimension.world.provider.writeChunk(chunk, dimension) catch {};
    }
}

fn chunkStreamStep(ctx: *anyopaque) bool {
    const state: *ChunkStreamState = @ptrCast(@alignCast(ctx));
    const allocator = state.allocator;

    const player = state.tecton.players.byRuntimeId(state.runtime_id) orelse {
        return true;
    };

    const dimension = state.dimension;
    const sim_dist = dimension.simulation_distance;

    while (state.inflight < MAX_INFLIGHT_BATCHES and (state.upgrade_idx < state.upgrade_hashes.len or state.ring <= state.radius)) {
        if (state.upgrade_idx < state.upgrade_hashes.len) {
            const count = @min(generation.BATCH_SIZE, state.upgrade_hashes.len - state.upgrade_idx);

            const w_coords = allocator.alloc(generation.ChunkCoord, count) catch break;
            const w_hashes = allocator.alloc(i64, count) catch {
                allocator.free(w_coords);
                break;
            };
            const w_in_simulation = allocator.alloc(bool, count) catch {
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };
            const w_packets = allocator.alloc([]const u8, count) catch {
                allocator.free(w_in_simulation);
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };
            const w_cached_packets = allocator.alloc([]const u8, count) catch {
                allocator.free(w_packets);
                allocator.free(w_in_simulation);
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };
            const w_chunks = allocator.alloc(?*Chunk, count) catch {
                allocator.free(w_cached_packets);
                allocator.free(w_packets);
                allocator.free(w_in_simulation);
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };
            const w_block_data = allocator.alloc(generation.ChunkBlockData, count) catch {
                allocator.free(w_chunks);
                allocator.free(w_cached_packets);
                allocator.free(w_packets);
                allocator.free(w_in_simulation);
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };

            for (0..count) |i| {
                const idx = state.upgrade_idx + i;
                w_coords[i] = state.upgrade_coords[idx];
                w_hashes[i] = state.upgrade_hashes[idx];
                w_in_simulation[i] = true;
                w_packets[i] = &.{};
                w_cached_packets[i] = &.{};
                w_chunks[i] = null;
                w_block_data[i] = .{ .parsed_entities = &.{}, .trait_positions = &.{} };
            }

            const work = allocator.create(generation.ChunkBatchWork) catch {
                allocator.free(w_block_data);
                allocator.free(w_chunks);
                allocator.free(w_cached_packets);
                allocator.free(w_packets);
                allocator.free(w_in_simulation);
                allocator.free(w_hashes);
                allocator.free(w_coords);
                break;
            };

            work.* = .{
                .coords = w_coords,
                .hashes = w_hashes,
                .in_simulation = w_in_simulation,
                .send_chunk_packets = false,
                .packets = w_packets,
                .cached_packets = w_cached_packets,
                .chunks = w_chunks,
                .block_data = w_block_data,
                .count = count,
                .runtime_id = state.runtime_id,
                .tecton = state.tecton,
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .dimension = dimension,
                .options = player.network.options,
                .provider = dimension.world.provider,
                .dim_type = dimension.dimension_type,
                .generator = if (dimension.generator) |gen| gen.generator else null,
                .sim_distance = dimension.simulation_distance,
                .center_x = state.center_x,
                .center_z = state.center_z,
                .owner_state = @ptrCast(state),
            };

            state.upgrade_idx += count;
            state.inflight += 1;
            dimension.inflight_batches += 1;
            for (work.coords) |coord| flushChunkStateForStreaming(dimension, coord.x, coord.z);

            state.tecton.threaded_tasks.enqueue(.{
                .work = generation.workerLoadAndCompress,
                .callback = onBatchComplete,
                .cleanup = cleanupBatchWork,
                .ctx = @ptrCast(work),
                .kind = .world,
            }) catch {
                cleanupBatchWork(@ptrCast(work));
            };
            continue;
        }

        var coord_buf: [generation.BATCH_SIZE]generation.ChunkCoord = undefined;
        var hash_buf: [generation.BATCH_SIZE]i64 = undefined;
        var count: usize = 0;

        while (state.ring <= state.radius) {
            if (count >= generation.BATCH_SIZE) break;

            const ring = state.ring;
            if (ring == 0) {
                state.ring = 1;
                state.ring_idx = 0;
                const chunk_hash = Protocol.ChunkCoords.hash(.{ .x = state.center_x, .z = state.center_z });
                if (!player.sent_chunks.contains(chunk_hash) and !player.pending_chunks.contains(chunk_hash)) {
                    if (sim_dist <= 0) {
                        if (dimension.getCachedChunkPacket(chunk_hash)) |cached| {
                            sendCachedChunkPacket(player.connection, cached);
                            player.sent_chunks.put(chunk_hash, {}) catch {};
                            continue;
                        }
                    }
                    {
                        coord_buf[count] = .{ .x = state.center_x, .z = state.center_z };
                        hash_buf[count] = chunk_hash;
                        count += 1;
                    }
                }
                continue;
            }

            const perimeter = ring * 8;
            if (state.ring_idx >= perimeter) {
                state.ring += 1;
                state.ring_idx = 0;
                continue;
            }

            const coords = ringCoord(state.center_x, state.center_z, ring, state.ring_idx);
            state.ring_idx += 1;

            const dx = coords[0] - state.center_x;
            const dz = coords[1] - state.center_z;
            if (dx * dx + dz * dz > state.radius * state.radius) continue;

            const chunk_hash = Protocol.ChunkCoords.hash(.{ .x = coords[0], .z = coords[1] });
            if (player.sent_chunks.contains(chunk_hash) or player.pending_chunks.contains(chunk_hash)) continue;

            const in_simulation = dx * dx + dz * dz <= sim_dist * sim_dist;
            if (!in_simulation) {
                if (dimension.getCachedChunkPacket(chunk_hash)) |cached| {
                    sendCachedChunkPacket(player.connection, cached);
                    player.sent_chunks.put(chunk_hash, {}) catch {};
                    continue;
                }
            }

            coord_buf[count] = .{ .x = coords[0], .z = coords[1] };
            hash_buf[count] = chunk_hash;
            count += 1;
        }

        if (count == 0) break;

        const w_coords = allocator.alloc(generation.ChunkCoord, count) catch break;
        const w_hashes = allocator.alloc(i64, count) catch {
            allocator.free(w_coords);
            break;
        };
        const w_in_simulation = allocator.alloc(bool, count) catch {
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };
        const w_packets = allocator.alloc([]const u8, count) catch {
            allocator.free(w_in_simulation);
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };
        const w_cached_packets = allocator.alloc([]const u8, count) catch {
            allocator.free(w_packets);
            allocator.free(w_in_simulation);
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };
        const w_chunks = allocator.alloc(?*Chunk, count) catch {
            allocator.free(w_cached_packets);
            allocator.free(w_packets);
            allocator.free(w_in_simulation);
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };
        const w_block_data = allocator.alloc(generation.ChunkBlockData, count) catch {
            allocator.free(w_chunks);
            allocator.free(w_cached_packets);
            allocator.free(w_packets);
            allocator.free(w_in_simulation);
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };

        for (0..count) |i| {
            w_coords[i] = coord_buf[i];
            w_hashes[i] = hash_buf[i];
            const dx = w_coords[i].x - state.center_x;
            const dz = w_coords[i].z - state.center_z;
            w_in_simulation[i] = dx * dx + dz * dz <= sim_dist * sim_dist;
            w_chunks[i] = null;
            w_packets[i] = &.{};
            w_cached_packets[i] = &.{};
            w_block_data[i] = .{ .parsed_entities = &.{}, .trait_positions = &.{} };
        }

        const work = allocator.create(generation.ChunkBatchWork) catch {
            allocator.free(w_block_data);
            allocator.free(w_chunks);
            allocator.free(w_cached_packets);
            allocator.free(w_packets);
            allocator.free(w_in_simulation);
            allocator.free(w_hashes);
            allocator.free(w_coords);
            break;
        };

        work.* = .{
            .coords = w_coords,
            .hashes = w_hashes,
            .in_simulation = w_in_simulation,
            .send_chunk_packets = true,
            .packets = w_packets,
            .cached_packets = w_cached_packets,
            .chunks = w_chunks,
            .block_data = w_block_data,
            .count = count,
            .runtime_id = state.runtime_id,
            .tecton = state.tecton,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .dimension = dimension,
            .options = player.network.options,
            .provider = dimension.world.provider,
            .dim_type = dimension.dimension_type,
            .generator = if (dimension.generator) |gen| gen.generator else null,
            .sim_distance = dimension.simulation_distance,
            .center_x = state.center_x,
            .center_z = state.center_z,
            .owner_state = @ptrCast(state),
        };

        state.inflight += 1;
        dimension.inflight_batches += 1;
        for (work.coords) |coord| flushChunkStateForStreaming(dimension, coord.x, coord.z);

        state.tecton.threaded_tasks.enqueue(.{
            .work = generation.workerLoadAndCompress,
            .callback = onBatchComplete,
            .cleanup = cleanupBatchWork,
            .ctx = @ptrCast(work),
            .kind = .world,
        }) catch {
            cleanupBatchWork(@ptrCast(work));
            continue;
        };

        for (0..count) |i| {
            player.pending_chunks.put(w_hashes[i], {}) catch {};
        }
    }

    if (state.upgrade_idx >= state.upgrade_hashes.len and state.ring > state.radius) {
        return true;
    }
    return false;
}

fn ringCoord(cx: i32, cz: i32, ring: i32, idx: i32) [2]i32 {
    const side = ring * 2;
    if (idx < side) return .{ cx - ring + idx, cz - ring };
    const idx2 = idx - side;
    if (idx2 < side) return .{ cx + ring, cz - ring + idx2 };
    const idx3 = idx2 - side;
    if (idx3 < side) return .{ cx + ring - idx3, cz + ring };
    const idx4 = idx3 - side;
    return .{ cx - ring, cz + ring - idx4 };
}

test "two-tier chunk classification matches squared distance formula" {
    var rng = std.Random.DefaultPrng.init(0xabcd1234);
    const random = rng.random();

    for (0..100) |_| {
        const cx = random.intRangeAtMost(i32, -1000, 1000);
        const cz = random.intRangeAtMost(i32, -1000, 1000);
        const px = random.intRangeAtMost(i32, -1000, 1000);
        const pz = random.intRangeAtMost(i32, -1000, 1000);
        const sim_dist = random.intRangeAtMost(i32, 1, 16);

        const dx = cx - px;
        const dz = cz - pz;
        const in_simulation = dx * dx + dz * dz <= sim_dist * sim_dist;

        const dx_f: f64 = @floatFromInt(dx);
        const dz_f: f64 = @floatFromInt(dz);
        const sd_f: f64 = @floatFromInt(sim_dist);
        const expected = (dx_f * dx_f + dz_f * dz_f) <= (sd_f * sd_f);

        try std.testing.expectEqual(expected, in_simulation);
    }
}

test "releasing an abandoned batch's cached packets frees every allocation" {
    const allocator = std.testing.allocator;

    var cached = [_][]const u8{ &.{}, &.{}, &.{} };
    cached[0] = try allocator.dupe(u8, "cached-0");
    cached[2] = try allocator.dupe(u8, "cached-2");

    releaseCachedPackets(allocator, &cached);
}
