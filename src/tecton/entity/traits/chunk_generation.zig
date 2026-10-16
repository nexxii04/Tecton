const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");

const Host = @import("../../player/player.zig").Host;
const Compression = @import("../../transport/compression/compression.zig").Compression;
const CompressionOptions = @import("../../transport/compression/options.zig").CompressionOptions;
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;
const BlockState = @import("../../world/block/block_permutation.zig").BlockState;
const BlockType = @import("../../world/block/block_type.zig").BlockType;
const Block = @import("../../world/block/block.zig").Block;
const ChestTrait = @import("../../world/block/traits/chest.zig");
const trait_mod = @import("../../world/block/traits/trait.zig");
const Chunk = @import("../../world/chunk/chunk.zig").Chunk;
const chunk_mod = @import("../../world/chunk/chunk.zig");
const SubChunk = @import("../../world/chunk/subchunk.zig").SubChunk;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const ChunkColumnData = @import("../../world/provider/world_provider.zig").ChunkColumnData;
const WorldProvider = @import("../../world/provider/world_provider.zig").WorldProvider;

pub const BATCH_SIZE: usize = 2;

pub const ChunkCoord = struct { x: i32, z: i32 };

pub const ParsedBlockEntity = struct {
    x: i32,
    y: i32,
    z: i32,
    trait_ids: [][]const u8,
    nbt_data: ?[]const u8,
};

pub const TraitBlockPos = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const ChunkBlockData = struct {
    parsed_entities: []ParsedBlockEntity,
    trait_positions: []TraitBlockPos,
};

fn shouldReadTraitPositions(in_simulation: bool) bool {
    return in_simulation;
}

fn shouldCacheChunkPacket(in_simulation: bool, data: *const ChunkBlockData) bool {
    return !in_simulation and data.parsed_entities.len == 0;
}

pub const ChunkBatchWork = struct {
    coords: []ChunkCoord,
    hashes: []i64,
    in_simulation: []bool,
    send_chunk_packets: bool,
    packets: [][]const u8,
    cached_packets: [][]const u8,
    chunks: []?*Chunk,
    block_data: []ChunkBlockData,
    count: usize,
    runtime_id: i64,
    tecton: Host,
    dimension: *Dimension,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    options: CompressionOptions,
    provider: WorldProvider,
    dim_type: Protocol.DimensionType,
    generator: ?@import("../../world/generator/terrain_generator.zig").TerrainGenerator,
    sim_distance: i32,
    center_x: i32,
    center_z: i32,

    delivery_mask: u32 = 0,
    owner_state: ?*anyopaque = null,
};

pub fn workerLoadAndCompress(ctx: *anyopaque) void {
    const work: *ChunkBatchWork = @ptrCast(@alignCast(ctx));
    const allocator = work.allocator;
    const arena_alloc = work.arena.allocator();

    var raw_packets: [BATCH_SIZE][]const u8 = undefined;
    var raw_count: usize = 0;

    for (0..work.count) |i| {
        work.block_data[i] = .{ .parsed_entities = &.{}, .trait_positions = &.{} };

        const coord = work.coords[i];
        if (!work.in_simulation[i] and work.send_chunk_packets) {
            const column = work.provider.readChunkColumn(allocator, coord.x, coord.z, work.dim_type, true) catch null;
            if (column) |loaded_column| {
                var chunk_column = loaded_column;
                defer chunk_column.deinit(allocator);

                work.block_data[i] = .{
                    .parsed_entities = if (chunk_column.block_entity_data) |data|
                        parseBlockEntitiesFromBytes(arena_alloc, data)
                    else
                        &.{},
                    .trait_positions = &.{},
                };

                const pkt = serializeChunkPacketFromColumnWithAllocator(
                    allocator,
                    arena_alloc,
                    &chunk_column,
                    coord.x,
                    coord.z,
                    work.dim_type,
                ) orelse {
                    work.packets[i] = &.{};
                    continue;
                };

                if (shouldCacheChunkPacket(false, &work.block_data[i])) {
                    const single = [_][]const u8{pkt};
                    work.cached_packets[i] = Compression.compress(&single, work.options, allocator) catch &.{};
                }

                work.packets[i] = pkt;
                raw_packets[raw_count] = pkt;
                raw_count += 1;
                work.delivery_mask |= @as(u32, 1) << @intCast(i);
                work.chunks[i] = null;
                continue;
            }
        }

        const chunk = work.provider.readChunkDirect(coord.x, coord.z, work.dim_type) catch blk: {
            if (work.generator) |gen| {
                break :blk gen.generate(allocator, coord.x, coord.z) catch {
                    work.packets[i] = &.{};
                    work.chunks[i] = null;
                    continue;
                };
            } else {
                work.packets[i] = &.{};
                work.chunks[i] = null;
                continue;
            }
        };

        work.chunks[i] = chunk;

        work.block_data[i] = workerReadBlockData(
            arena_alloc,
            work.provider,
            chunk,
            work.dim_type,
            shouldReadTraitPositions(work.in_simulation[i]),
        );

        if (work.send_chunk_packets) {
            const pkt = serializeChunkPacket(allocator, chunk, coord.x, coord.z, work.dim_type) orelse {
                work.packets[i] = &.{};
                continue;
            };

            if (shouldCacheChunkPacket(work.in_simulation[i], &work.block_data[i])) {
                const single = [_][]const u8{pkt};
                work.cached_packets[i] = Compression.compress(&single, work.options, allocator) catch &.{};
            }

            work.packets[i] = pkt;
            raw_packets[raw_count] = pkt;
            raw_count += 1;
            work.delivery_mask |= @as(u32, 1) << @intCast(i);
        }
    }

    if (!work.send_chunk_packets) return;

    if (raw_count > 1) {
        const compressed = Compression.compress(raw_packets[0..raw_count], work.options, allocator) catch {
            for (0..work.count) |i| {
                if (work.packets[i].len > 0) {
                    const pkts = [_][]const u8{work.packets[i]};
                    work.packets[i] = Compression.compress(&pkts, work.options, allocator) catch {
                        allocator.free(work.packets[i]);
                        work.packets[i] = &.{};
                        work.delivery_mask &= ~(@as(u32, 1) << @intCast(i));
                        continue;
                    };
                }
            }
            return;
        };
        for (0..work.count) |i| {
            if (work.packets[i].len > 0) allocator.free(work.packets[i]);
            work.packets[i] = &.{};
        }
        work.packets[0] = compressed;
    } else {
        for (0..work.count) |i| {
            if (work.packets[i].len > 0) {
                const pkt = work.packets[i];
                const pkts = [_][]const u8{pkt};
                work.packets[i] = Compression.compress(&pkts, work.options, allocator) catch {
                    allocator.free(pkt);
                    work.packets[i] = &.{};
                    work.delivery_mask &= ~(@as(u32, 1) << @intCast(i));
                    continue;
                };
                allocator.free(pkt);
            }
        }
    }
}

fn workerReadBlockData(
    allocator: std.mem.Allocator,
    provider: WorldProvider,
    chunk: *Chunk,
    dim_type: Protocol.DimensionType,
    include_trait_positions: bool,
) ChunkBlockData {
    var result = ChunkBlockData{ .parsed_entities = &.{}, .trait_positions = &.{} };

    var positions = std.ArrayList(TraitBlockPos).empty;

    if (provider.readChunkBlockEntityData(allocator, chunk.x, chunk.z, dim_type) catch null) |data| {
        defer allocator.free(data);
        result.parsed_entities = parseBlockEntitiesFromBytes(allocator, data);
    }

    if (include_trait_positions and trait_mod.hasAnyStaticTraits()) {
        const offset = chunk_mod.yOffset(dim_type);
        for (0..chunk_mod.MAX_SUBCHUNKS) |si| {
            const sc = chunk.subchunks[si] orelse continue;
            if (sc.layers.items.len == 0) continue;
            const layer = &sc.layers.items[0];

            var has_traits = false;
            for (layer.paletteSlice()) |network_id| {
                const perm = BlockPermutation.getByNetworkId(network_id) orelse continue;
                if (std.mem.eql(u8, perm.identifier, "minecraft:air")) continue;
                if (trait_mod.hasRegisteredTraits(perm.identifier)) {
                    has_traits = true;
                    break;
                }
            }
            if (!has_traits) continue;

            var trait_palette = std.AutoHashMap(u32, bool).init(allocator);
            defer trait_palette.deinit();
            for (layer.paletteSlice(), 0..) |network_id, pi| {
                const perm = BlockPermutation.getByNetworkId(network_id) orelse continue;
                if (std.mem.eql(u8, perm.identifier, "minecraft:air")) continue;
                if (trait_mod.hasRegisteredTraits(perm.identifier)) {
                    trait_palette.put(@intCast(pi), true) catch continue;
                }
            }

            const sc_y: i32 = @as(i32, @intCast(si)) - @as(i32, @intCast(offset));
            for (0..4096) |pos_idx| {
                const palette_idx = layer.blocks[pos_idx];
                if (!trait_palette.contains(palette_idx)) continue;

                const bx: i32 = @intCast((pos_idx >> 8) & 0xf);
                const by: i32 = @intCast(pos_idx & 0xf);
                const bz: i32 = @intCast((pos_idx >> 4) & 0xf);

                positions.append(allocator, .{
                    .x = chunk.x * 16 + bx,
                    .y = sc_y * 16 + by,
                    .z = chunk.z * 16 + bz,
                }) catch continue;
            }
        }
    }

    result.trait_positions = positions.toOwnedSlice(allocator) catch &.{};
    return result;
}

fn parseBlockEntitiesFromBytes(allocator: std.mem.Allocator, data: []const u8) []ParsedBlockEntity {
    var entities = std.ArrayList(ParsedBlockEntity){ .items = &.{}, .capacity = 0 };
    var stream = BinaryStream.init(allocator, data, null);
    while (stream.offset < data.len) {
        var tag = NBT.CompoundTag.read(&stream, allocator, NBT.ReadWriteOptions.default) catch break;

        const x = switch (tag.get("x") orelse {
            tag.deinit(allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(allocator);
                continue;
            },
        };
        const y = switch (tag.get("y") orelse {
            tag.deinit(allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(allocator);
                continue;
            },
        };
        const z = switch (tag.get("z") orelse {
            tag.deinit(allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(allocator);
                continue;
            },
        };

        var trait_ids = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        const traits_tag = tag.get("traits") orelse tag.get("Traits");
        if (traits_tag) |tt| {
            switch (tt) {
                .List => |list| {
                    for (list.value) |item| {
                        switch (item) {
                            .String => |s| {
                                const duped = allocator.dupe(u8, s.value) catch continue;
                                trait_ids.append(allocator, duped) catch {
                                    allocator.free(duped);
                                    continue;
                                };
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        var nbt_data: ?[]const u8 = null;
        var nbt_stream = BinaryStream.init(allocator, null, null);
        NBT.CompoundTag.write(&nbt_stream, &tag, NBT.ReadWriteOptions.default) catch {
            nbt_stream.deinit();
            tag.deinit(allocator);
            for (trait_ids.items) |id| allocator.free(id);
            if (trait_ids.capacity > 0) trait_ids.deinit(allocator);
            continue;
        };
        nbt_data = allocator.dupe(u8, nbt_stream.getBuffer()) catch null;
        nbt_stream.deinit();
        tag.deinit(allocator);

        entities.append(allocator, .{
            .x = x,
            .y = y,
            .z = z,
            .trait_ids = trait_ids.toOwnedSlice(allocator) catch &.{},
            .nbt_data = nbt_data,
        }) catch continue;
    }

    return entities.toOwnedSlice(allocator) catch &.{};
}

fn buildChunkFromColumn(allocator: std.mem.Allocator, column: *const ChunkColumnData, x: i32, z: i32, dim_type: Protocol.DimensionType) !Chunk {
    var chunk = Chunk.init(allocator, x, z, dim_type);
    for (column.subchunks, 0..) |maybe_data, i| {
        const data = maybe_data orelse continue;
        var stream = BinaryStream.init(allocator, data, null);
        const sc = try allocator.create(SubChunk);
        errdefer allocator.destroy(sc);
        sc.* = try SubChunk.deserialize(&stream, allocator);
        chunk.subchunks[i] = sc;
    }
    return chunk;
}

fn serializeChunkPacketFromColumnWithAllocator(
    packet_allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    column: *const ChunkColumnData,
    cx: i32,
    cz: i32,
    dim_type: Protocol.DimensionType,
) ?[]const u8 {
    var chunk = buildChunkFromColumn(temp_allocator, column, cx, cz, dim_type) catch return null;
    return serializeChunkPacket(packet_allocator, &chunk, cx, cz, dim_type);
}

fn serializeChunkPacketFromColumn(
    allocator: std.mem.Allocator,
    column: *const ChunkColumnData,
    cx: i32,
    cz: i32,
    dim_type: Protocol.DimensionType,
) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return serializeChunkPacketFromColumnWithAllocator(allocator, arena.allocator(), column, cx, cz, dim_type);
}

pub fn applyParsedBlockData(allocator: std.mem.Allocator, dim: *Dimension, data: *ChunkBlockData) void {
    for (data.parsed_entities) |entity| {
        const pos = Protocol.BlockPosition{ .x = entity.x, .y = entity.y, .z = entity.z };
        if (dim.getBlockPtr(pos) != null) continue;

        const block = allocator.create(Block) catch continue;
        block.* = Block.init(allocator, dim, pos);

        for (entity.trait_ids) |tid| {
            if (trait_mod.getTraitFactory(tid)) |f| {
                const instance = f(allocator) catch continue;
                block.addTrait(instance) catch continue;
            }
        }

        if (block.traits.items.len == 0) {
            block.deinit();
            allocator.destroy(block);
            continue;
        }

        dim.storeBlock(block) catch {
            block.deinit();
            allocator.destroy(block);
            continue;
        };
    }

    for (data.parsed_entities) |entity| {
        const pos = Protocol.BlockPosition{ .x = entity.x, .y = entity.y, .z = entity.z };
        const block = dim.getBlockPtr(pos) orelse continue;
        if (block.hasTrait(ChestTrait.ChestTrait.identifier)) {
            ChestTrait.restoreAdjacentPairing(block);
        }
    }

    for (data.parsed_entities) |entity| {
        const nbt_bytes = entity.nbt_data orelse continue;
        const pos = Protocol.BlockPosition{ .x = entity.x, .y = entity.y, .z = entity.z };
        const block = dim.getBlockPtr(pos) orelse continue;

        var stream = @import("BinaryStream").BinaryStream.init(allocator, nbt_bytes, null);
        var tag = NBT.CompoundTag.read(&stream, allocator, NBT.ReadWriteOptions.default) catch continue;
        defer tag.deinit(allocator);
        block.fireEvent(.Deserialize, .{&tag});
    }

    for (data.trait_positions) |tp| {
        const pos = Protocol.BlockPosition{ .x = tp.x, .y = tp.y, .z = tp.z };
        if (dim.getBlockPtr(pos) != null) continue;
        trait_mod.applyTraitsForBlock(allocator, dim, pos) catch continue;
    }
}

pub fn freeBlockDataSlice(allocator: std.mem.Allocator, block_data: []ChunkBlockData, _: usize) void {
    allocator.free(block_data);
}

fn serializeChunkPacket(allocator: std.mem.Allocator, chunk: *Chunk, cx: i32, cz: i32, dim_type: Protocol.DimensionType) ?[]const u8 {
    var chunk_stream = BinaryStream.init(allocator, null, null);
    defer chunk_stream.deinit();
    chunk.serialize(&chunk_stream) catch return null;

    var pkt_stream = BinaryStream.init(allocator, null, null);
    defer pkt_stream.deinit();

    var level_chunk = Protocol.LevelChunkPacket{
        .x = cx,
        .z = cz,
        .dimension = dim_type,
        .sub_chunk_count = @intCast(chunk.getSubChunkSendCount()),
        .cache_enabled = false,
        .blobs = &[_]u64{},
        .data = chunk_stream.getBuffer(),
    };

    const serialized = level_chunk.serialize(&pkt_stream) catch return null;
    return allocator.dupe(u8, serialized) catch null;
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const BinaryStream = test_owner.BinaryStream;
    pub const NBT = test_owner.NBT;
    pub const BlockPermutation = test_owner.BlockPermutation;
    pub const BlockState = test_owner.BlockState;
    pub const BlockType = test_owner.BlockType;
    pub const Chunk = test_owner.Chunk;
    pub const ChunkColumnData = test_owner.ChunkColumnData;
    pub const ParsedBlockEntity = test_owner.ParsedBlockEntity;
    pub const ChunkBlockData = test_owner.ChunkBlockData;
    pub const shouldReadTraitPositions = test_owner.shouldReadTraitPositions;
    pub const shouldCacheChunkPacket = test_owner.shouldCacheChunkPacket;
    pub const parseBlockEntitiesFromBytes = test_owner.parseBlockEntitiesFromBytes;
    pub const serializeChunkPacketFromColumn = test_owner.serializeChunkPacketFromColumn;
    pub const serializeChunkPacket = test_owner.serializeChunkPacket;
};

test "render-only pure terrain chunks stay cacheable" {
    try @import("chunk_generation_test.zig").Suite(test_scope).case_000();
}

test "render-only chunks with block actors bypass packet cache" {
    try @import("chunk_generation_test.zig").Suite(test_scope).case_001();
}

test "render-only chunks skip trait-position scan" {
    try @import("chunk_generation_test.zig").Suite(test_scope).case_002();
}

test "chunk column packet serialization matches full chunk path" {
    try @import("chunk_generation_test.zig").Suite(test_scope).case_003();
}

test "parse block entity blob decodes positions and traits" {
    try @import("chunk_generation_test.zig").Suite(test_scope).case_004();
}
