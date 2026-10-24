const std = @import("std");

const Protocol = @import("protocol");

const Entity = @import("../../entity/entity.zig").Entity;
const FloatingTextManager = @import("../../entity/floating_text.zig").FloatingTextManager;
const ecs_resources = @import("../../ecs/resources.zig");
const ecs_entity_id = @import("../../ecs/entity_id.zig");
const BlockPermutation = @import("../block/block_permutation.zig").BlockPermutation;
const Block = @import("../block/block.zig").Block;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const TerrainGenerator = @import("../generator/terrain_generator.zig").TerrainGenerator;
const ThreadedGenerator = @import("../generator/threaded_generator.zig").ThreadedGenerator;
const World = @import("../world.zig").World;
const ChunkEntityIndex = @import("./entity_index.zig").ChunkEntityIndex;
const ChunkPacketCache = @import("./chunk_packet_cache.zig").ChunkPacketCache;
const block_pos = @import("./block_pos.zig");
const broadcast = @import("./broadcast.zig");
const random_tick = @import("./random_tick.zig");
const tick_scheduler = @import("./tick_scheduler.zig");

pub const ChunkHash = i64;

pub fn chunkHash(x: i32, z: i32) ChunkHash {
    return (@as(i64, x) << 32) | @as(i64, @as(u32, @bitCast(z)));
}

pub const Dimension = struct {
    world: *World,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    dimension_type: Protocol.DimensionType,
    chunks: std.AutoHashMap(ChunkHash, *Chunk),
    entities: std.AutoHashMap(i64, *Entity),
    entity_index: ChunkEntityIndex,
    blocks: std.AutoHashMap(i64, *Block),
    blocks_by_chunk: std.AutoHashMap(ChunkHash, std.ArrayList(*Block)),
    chunk_packet_cache: ChunkPacketCache,
    inflight_packets: std.AutoHashMap(ChunkHash, void),
    chunk_generations: std.AutoHashMap(ChunkHash, u64),
    pending_removals: std.ArrayList(i64),
    spawn_position: Protocol.BlockPosition,
    simulation_distance: i32,
    generator: ?*ThreadedGenerator,
    instance_id: u32 = 0,
    inflight_batches: usize = 0,
    floating_texts: ?*FloatingTextManager = null,
    ecs: ?*ecs_resources.DimensionEcs = null,

    pub fn init(
        world: *World,
        allocator: std.mem.Allocator,
        identifier: []const u8,
        dimension_type: Protocol.DimensionType,
        generator: ?*ThreadedGenerator,
    ) Dimension {
        const spawn: Protocol.BlockPosition = if (generator) |gen|
            gen.generator.spawnPoint()
        else
            Protocol.BlockPosition{ .x = 0, .y = 32767, .z = 0 };

        return Dimension{
            .world = world,
            .allocator = allocator,
            .identifier = identifier,
            .dimension_type = dimension_type,
            .chunks = std.AutoHashMap(ChunkHash, *Chunk).init(allocator),
            .entities = std.AutoHashMap(i64, *Entity).init(allocator),
            .entity_index = ChunkEntityIndex.init(allocator),
            .blocks = std.AutoHashMap(i64, *Block).init(allocator),
            .blocks_by_chunk = std.AutoHashMap(ChunkHash, std.ArrayList(*Block)).init(allocator),
            .chunk_packet_cache = ChunkPacketCache.init(allocator),
            .inflight_packets = std.AutoHashMap(ChunkHash, void).init(allocator),
            .chunk_generations = std.AutoHashMap(ChunkHash, u64).init(allocator),
            .pending_removals = std.ArrayList(i64){ .items = &.{}, .capacity = 0 },
            .spawn_position = spawn,
            .simulation_distance = 4,
            .generator = generator,
            .instance_id = 0,
            .inflight_batches = 0,
        };
    }

    pub fn deinit(self: *Dimension) void {

        if (self.floating_texts) |manager| manager.destroy();
        if (self.ecs) |state| state.destroy(self.allocator);

        var bbc_iter = self.blocks_by_chunk.valueIterator();
        while (bbc_iter.next()) |list| {
            for (list.items) |block| {
                _ = self.blocks.remove(blockPosHash(block.position));
                block.deinit();
                self.allocator.destroy(block);
            }
            list.deinit(self.allocator);
        }
        self.blocks_by_chunk.deinit();
        self.blocks.deinit();

        var entity_iter = self.entities.valueIterator();
        while (entity_iter.next()) |entity| {
            entity.*.deinit();
            self.allocator.destroy(entity.*);
        }
        self.entities.deinit();
        self.entity_index.deinit();

        self.pending_removals.deinit(self.allocator);

        self.chunk_packet_cache.deinit();
        self.inflight_packets.deinit();
        self.chunk_generations.deinit();

        var iter = self.chunks.valueIterator();
        while (iter.next()) |chunk| {
            chunk.*.deinit();
            self.allocator.destroy(chunk.*);
        }
        self.chunks.deinit();
        if (self.generator) |gen| gen.deinit();
    }

    pub fn getChunk(self: *Dimension, x: i32, z: i32) ?*Chunk {
        return self.chunks.get(chunkHash(x, z));
    }

    pub fn invalidateChunkPacketCache(self: *Dimension, x: i32, z: i32) void {
        self.chunk_packet_cache.remove(chunkHash(x, z));
    }

    pub fn markPacketInflight(self: *Dimension, hash: ChunkHash) void {
        self.inflight_packets.put(hash, {}) catch {};
    }

    pub fn clearPacketInflight(self: *Dimension, hash: ChunkHash) void {
        _ = self.inflight_packets.remove(hash);
    }

    pub fn isPacketInflight(self: *const Dimension, hash: ChunkHash) bool {
        return self.inflight_packets.contains(hash);
    }

    pub fn inflightPacketCount(self: *const Dimension) usize {
        return self.inflight_packets.count();
    }

    pub fn getCachedChunkPacket(self: *Dimension, hash: ChunkHash) ?[]const u8 {
        return self.chunk_packet_cache.get(hash, self.chunk_generations.get(hash) orelse 0);
    }

    pub fn putCachedChunkPacket(self: *Dimension, hash: ChunkHash, data: []const u8) void {
        self.chunk_packet_cache.put(hash, self.chunk_generations.get(hash) orelse 0, data);
    }

    pub fn cachedPacketCount(self: *const Dimension) usize {
        return self.chunk_packet_cache.count();
    }

    pub fn cachedPacketBytes(self: *const Dimension) usize {
        return self.chunk_packet_cache.bytesHeld();
    }

    pub fn chunkGenerationCount(self: *const Dimension) usize {
        return self.chunk_generations.count();
    }

    pub fn forgetChunkResources(self: *Dimension, hash: ChunkHash) void {
        self.chunk_packet_cache.remove(hash);
        _ = self.chunk_generations.remove(hash);
    }

    pub fn getOrCreateChunk(self: *Dimension, x: i32, z: i32) !*Chunk {
        const hash = chunkHash(x, z);
        if (self.chunks.get(hash)) |chunk| return chunk;

        const chunk = self.world.provider.readChunk(x, z, self) catch blk: {
            if (self.generator) |gen|
                break :blk try gen.generate(x, z)
            else {
                const c = try self.allocator.create(Chunk);
                c.* = Chunk.init(self.allocator, x, z, self.dimension_type);
                break :blk c;
            }
        };

        try self.chunks.put(hash, chunk);
        self.world.provider.readBlockEntities(chunk, self) catch {};
        self.world.provider.readChunkEntities(chunk, self) catch {};
        return chunk;
    }

    pub fn removeChunk(self: *Dimension, x: i32, z: i32) void {
        const hash = chunkHash(x, z);
        self.forgetChunkResources(hash);
        if (self.chunks.fetchRemove(hash)) |entry| {
            var chunk = entry.value;

            self.world.provider.writeChunkEntities(chunk, self) catch {};
            if (self.getBlocksInChunk(x, z).len > 0) {
                self.world.provider.writeBlockEntities(chunk, self) catch {};
            }
            if (chunk.dirty) {
                self.world.provider.writeChunk(chunk, self) catch {};
            }
            self.removeBlocksInChunk(x, z);
            self.world.provider.uncacheChunk(x, z, self);
            chunk.deinit();
            self.allocator.destroy(chunk);
        }
    }

    pub fn releaseUnrenderedChunks(self: *Dimension, hashes: []const i64) void {
        const tecton = self.world.tecton;
        const snapshots = tecton.getPlayerSnapshots();
        const spawn_cx = self.spawn_position.x >> 4;
        const spawn_cz = self.spawn_position.z >> 4;
        const sim = self.simulation_distance;
        for (hashes) |h| {
            const coords = Protocol.ChunkCoords.unhash(h);
            const dx = coords.x - spawn_cx;
            const dz = coords.z - spawn_cz;
            if (dx * dx + dz * dz <= sim * sim) continue;

            var still_needed = false;
            for (snapshots) |player| {
                if (player.entity.dimension != self or player.entity.instance_id != self.instance_id) continue;
                if (player.sent_chunks.contains(h)) {
                    still_needed = true;
                    break;
                }
                const px = @as(i32, @intFromFloat(@floor(player.entity.position.x))) >> 4;
                const pz = @as(i32, @intFromFloat(@floor(player.entity.position.z))) >> 4;
                const pdx = coords.x - px;
                const pdz = coords.z - pz;
                if (pdx * pdx + pdz * pdz <= sim * sim) {
                    still_needed = true;
                    break;
                }
            }
            if (!still_needed) {
                if (self.chunks.fetchRemove(h)) |entry| {
                    const coords2 = Protocol.ChunkCoords.unhash(h);
                    var chunk = entry.value;

                    self.world.provider.writeChunkEntities(chunk, self) catch {};
                    if (self.getBlocksInChunk(coords2.x, coords2.z).len > 0) {
                        self.world.provider.writeBlockEntities(chunk, self) catch {};
                    }
                    if (chunk.dirty) {
                        self.world.provider.writeChunk(chunk, self) catch {};
                    }
                    self.removeBlocksInChunk(coords2.x, coords2.z);
                    self.world.provider.uncacheChunk(coords2.x, coords2.z, self);
                    self.forgetChunkResources(h);
                    chunk.deinit();
                    self.allocator.destroy(chunk);
                }
            }
        }
    }

    pub fn getPermutation(self: *Dimension, pos: Protocol.BlockPosition, layer: usize) !*BlockPermutation {
        const cx = pos.x >> 4;
        const cz = pos.z >> 4;
        const chunk = try self.getOrCreateChunk(cx, cz);
        return chunk.getPermutation(pos.x, pos.y, pos.z, layer);
    }

    pub fn setPermutation(self: *Dimension, pos: Protocol.BlockPosition, permutation: *BlockPermutation, layer: usize) !void {
        const cx = pos.x >> 4;
        const cz = pos.z >> 4;
        const chunk = try self.getOrCreateChunk(cx, cz);
        try chunk.setPermutation(pos.x, pos.y, pos.z, permutation, layer);
        const hash = chunkHash(cx, cz);
        const gen = self.chunk_generations.get(hash) orelse 0;
        self.chunk_generations.put(hash, gen + 1) catch {};
        self.invalidateChunkPacketCache(cx, cz);
    }

    pub fn getBlock(self: *Dimension, pos: Protocol.BlockPosition) Block {
        if (self.blocks.get(blockPosHash(pos))) |block| return block.*;
        return Block.init(self.allocator, self, pos);
    }

    pub fn getBlockPtr(self: *Dimension, pos: Protocol.BlockPosition) ?*Block {
        return self.blocks.get(blockPosHash(pos));
    }

    pub fn storeBlock(self: *Dimension, block: *Block) !void {
        const hash = blockPosHash(block.position);
        if (self.blocks.fetchRemove(hash)) |entry| {
            var old = entry.value;
            self.removeFromChunkIndex(old);
            old.deinit();
            self.allocator.destroy(old);
        }
        try self.blocks.put(hash, block);
        const ch = chunkHash(block.position.x >> 4, block.position.z >> 4);
        const gop = try self.blocks_by_chunk.getOrPut(ch);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(*Block){ .items = &.{}, .capacity = 0 };
        }
        try gop.value_ptr.append(self.allocator, block);
    }

    pub fn removeBlock(self: *Dimension, pos: Protocol.BlockPosition) void {
        const hash = blockPosHash(pos);
        if (self.blocks.fetchRemove(hash)) |entry| {
            var block = entry.value;
            self.removeFromChunkIndex(block);
            block.deinit();
            self.allocator.destroy(block);
        }
    }

    fn removeFromChunkIndex(self: *Dimension, block: *Block) void {
        const ch = chunkHash(block.position.x >> 4, block.position.z >> 4);
        if (self.blocks_by_chunk.getPtr(ch)) |list| {
            for (list.items, 0..) |b, i| {
                if (b == block) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
    }

    pub const blockPosHash = block_pos.blockPosHash;

    pub fn removeBlocksInChunk(self: *Dimension, cx: i32, cz: i32) void {
        const ch = chunkHash(cx, cz);
        if (self.blocks_by_chunk.fetchRemove(ch)) |entry| {
            var list = entry.value;
            for (list.items) |block| {
                const hash = blockPosHash(block.position);
                _ = self.blocks.remove(hash);
                var b = block;
                b.deinit();
                self.allocator.destroy(b);
            }
            list.deinit(self.allocator);
        }
    }

    pub fn getBlocksInChunk(self: *Dimension, cx: i32, cz: i32) []const *Block {
        const ch = chunkHash(cx, cz);
        if (self.blocks_by_chunk.getPtr(ch)) |list| return list.items;
        return &.{};
    }

    pub fn loadSpawnChunks(self: *Dimension) !void {
        const spawn_cx = self.spawn_position.x >> 4;
        const spawn_cz = self.spawn_position.z >> 4;
        const radius: i32 = 2;
        var cx: i32 = spawn_cx - radius;
        while (cx <= spawn_cx + radius) : (cx += 1) {
            var cz: i32 = spawn_cz - radius;
            while (cz <= spawn_cz + radius) : (cz += 1) {
                _ = try self.getOrCreateChunk(cx, cz);
            }
        }
    }

    pub fn ensureEcs(self: *Dimension, capacity: usize) !*ecs_resources.DimensionEcs {
        if (self.ecs) |state| return state;
        const state = try ecs_resources.DimensionEcs.create(self.allocator, capacity);
        self.ecs = state;
        return state;
    }

    pub fn runtimeToEcs(self: *Dimension, runtime: i64) ?ecs_entity_id.EntityId {
        const state = self.ecs orelse return null;
        return state.runtime_index.resolve(runtime);
    }

    pub fn getEntity(self: *Dimension, runtime_id: i64) ?*Entity {
        return self.entities.get(runtime_id);
    }

    pub fn reindexEntity(self: *Dimension, entity: *Entity) void {
        self.entity_index.reindex(entity);
    }

    pub fn entitiesInChunk(self: *Dimension, x: i32, z: i32) []const *Entity {
        return self.entity_index.bucket(x, z) orelse &.{};
    }

    pub fn withinViewDistance(dx: f32, dz: f32, view_distance: i32) bool {
        const range = view_distance * 16;
        const range_sq: f32 = @floatFromInt(range * range);
        return dx * dx + dz * dz <= range_sq;
    }
};

pub const TickScheduler = tick_scheduler.TickScheduler;

pub const RandomTickEligibility = random_tick.RandomTickEligibility;
pub const isChunkInSimRange = random_tick.isChunkInSimRange;

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("./entity_index.zig");
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const block_pos = test_owner.block_pos;
    pub const broadcast = test_owner.broadcast;
    pub const random_tick = test_owner.random_tick;
    pub const tick_scheduler = test_owner.tick_scheduler;
    pub const ChunkHash = test_owner.ChunkHash;
    pub const chunkHash = test_owner.chunkHash;
    pub const ChunkPacketCache = test_owner.ChunkPacketCache;
    pub const World = test_owner.World;
    pub const Dimension = test_owner.Dimension;
};

test "view distance range predicate compares squared horizontal distance" {
    try @import("dimension_test.zig").Suite(test_scope).case_000();
}

test "entity index chunk hash matches dimension chunk hash" {
    try @import("dimension_test.zig").Suite(test_scope).case_001();
}

test "blocks_by_chunk index stays consistent with blocks map" {
    try @import("dimension_test.zig").Suite(test_scope).case_002();
}

test "removeBlocksInChunk removes only target chunk blocks" {
    try @import("dimension_test.zig").Suite(test_scope).case_003();
}

test "generation counter strictly increases" {
    try @import("dimension_test.zig").Suite(test_scope).case_004();
}

test "stale cache detected after generation change" {
    try @import("dimension_test.zig").Suite(test_scope).case_005();
}

test "extracted dimension helpers stay in the test graph" {
    try @import("dimension_test.zig").Suite(test_scope).case_006();
}

test "deinit retires a block before detaching its traits" {
    try @import("dimension_test.zig").Suite(test_scope).case_007();
}

test "forgetting a chunk drops its cached packet and generation" {
    try @import("dimension_test.zig").Suite(test_scope).case_008();
}

test "every chunk unload path forgets the per-chunk resources" {
    try @import("dimension_test.zig").Suite(test_scope).case_009();
}

test "in-flight packet marks are reference counted per chunk" {
    try @import("dimension_test.zig").Suite(test_scope).case_010();
}
