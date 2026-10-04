const std = @import("std");

const Protocol = @import("protocol");

const Entity = @import("../../entity/entity.zig").Entity;
const FloatingTextManager = @import("../../entity/floating-text.zig").FloatingTextManager;
const BlockPermutation = @import("../block/block-permutation.zig").BlockPermutation;
const Block = @import("../block/block.zig").Block;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const TerrainGenerator = @import("../generator/terrain-generator.zig").TerrainGenerator;
const ThreadedGenerator = @import("../generator/threaded-generator.zig").ThreadedGenerator;
const World = @import("../world.zig").World;
const ChunkEntityIndex = @import("./entity-index.zig").ChunkEntityIndex;
const block_pos = @import("./block-pos.zig");
const broadcast = @import("./broadcast.zig");
const random_tick = @import("./random-tick.zig");
const tick_scheduler = @import("./tick-scheduler.zig");

pub const ChunkHash = i64;

pub fn chunkHash(x: i32, z: i32) ChunkHash {
    return (@as(i64, x) << 32) | @as(i64, @as(u32, @bitCast(z)));
}

pub const CachedPacket = struct {
    data: []const u8,
    generation: u64,
};

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
    chunk_packet_cache: std.AutoHashMap(ChunkHash, CachedPacket),
    chunk_generations: std.AutoHashMap(ChunkHash, u64),
    pending_removals: std.ArrayList(i64),
    spawn_position: Protocol.BlockPosition,
    simulation_distance: i32,
    generator: ?*ThreadedGenerator,
    instance_id: u32 = 0,
    inflight_batches: usize = 0,
    floating_texts: ?*FloatingTextManager = null,

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
            .chunk_packet_cache = std.AutoHashMap(ChunkHash, CachedPacket).init(allocator),
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

        var cache_iter = self.chunk_packet_cache.valueIterator();
        while (cache_iter.next()) |cached| {
            self.allocator.free(cached.data);
        }
        self.chunk_packet_cache.deinit();
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
        const hash = chunkHash(x, z);
        if (self.chunk_packet_cache.fetchRemove(hash)) |entry| {
            self.allocator.free(entry.value.data);
        }
    }

    pub fn getCachedChunkPacket(self: *Dimension, hash: ChunkHash) ?[]const u8 {
        const cached = self.chunk_packet_cache.get(hash) orelse return null;
        const current_gen = self.chunk_generations.get(hash) orelse 0;
        if (cached.generation != current_gen) return null;
        return cached.data;
    }

    pub fn putCachedChunkPacket(self: *Dimension, hash: ChunkHash, data: []const u8) void {
        const gen = self.chunk_generations.get(hash) orelse 0;
        if (self.chunk_packet_cache.fetchPut(hash, .{ .data = data, .generation = gen }) catch null) |old| {
            self.allocator.free(old.value.data);
        }
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
        return chunk;
    }

    pub fn removeChunk(self: *Dimension, x: i32, z: i32) void {
        const hash = chunkHash(x, z);
        if (self.chunk_packet_cache.fetchRemove(hash)) |cached| {
            self.allocator.free(cached.value.data);
        }
        if (self.chunks.fetchRemove(hash)) |entry| {
            var chunk = entry.value;
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
            }
            if (!still_needed) {
                if (self.chunks.fetchRemove(h)) |entry| {
                    const coords2 = Protocol.ChunkCoords.unhash(h);
                    var chunk = entry.value;
                    if (self.getBlocksInChunk(coords2.x, coords2.z).len > 0) {
                        self.world.provider.writeBlockEntities(chunk, self) catch {};
                    }
                    if (chunk.dirty) {
                        self.world.provider.writeChunk(chunk, self) catch {};
                    }
                    self.removeBlocksInChunk(coords2.x, coords2.z);
                    self.world.provider.uncacheChunk(coords2.x, coords2.z, self);
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

test "view distance range predicate compares squared horizontal distance" {
    try std.testing.expect(Dimension.withinViewDistance(0, 0, 8));
    try std.testing.expect(Dimension.withinViewDistance(128, 0, 8));
    try std.testing.expect(!Dimension.withinViewDistance(129, 0, 8));
    try std.testing.expect(Dimension.withinViewDistance(90, 90, 8));
    try std.testing.expect(!Dimension.withinViewDistance(100, 100, 8));
    try std.testing.expect(Dimension.withinViewDistance(16, 0, 1));
    try std.testing.expect(!Dimension.withinViewDistance(17, 0, 1));
}

test "entity index chunk hash matches dimension chunk hash" {
    const entity_index = @import("./entity-index.zig");
    try std.testing.expectEqual(chunkHash(0, 0), entity_index.chunkHash(0, 0));
    try std.testing.expectEqual(chunkHash(-33, 17), entity_index.chunkHash(-33, 17));
    try std.testing.expectEqual(chunkHash(1000, -1000), entity_index.chunkHash(1000, -1000));
    try std.testing.expectEqual(chunkHash(-1, -1), entity_index.chunkHash(-1, -1));
}

test "blocks_by_chunk index stays consistent with blocks map" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0x12345678);
    const random = rng.random();

    var blocks = std.AutoHashMap(i64, Protocol.BlockPosition).init(allocator);
    defer blocks.deinit();
    var blocks_by_chunk = std.AutoHashMap(ChunkHash, std.ArrayList(i64)).init(allocator);
    defer {
        var it = blocks_by_chunk.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        blocks_by_chunk.deinit();
    }

    for (0..100) |_| {
        const pos = Protocol.BlockPosition{
            .x = random.intRangeAtMost(i32, -64, 64),
            .y = random.intRangeAtMost(i32, 0, 255),
            .z = random.intRangeAtMost(i32, -64, 64),
        };
        const hash = Dimension.blockPosHash(pos);
        const ch = chunkHash(pos.x >> 4, pos.z >> 4);

        if (random.boolean()) {
            blocks.put(hash, pos) catch continue;
            const gop = blocks_by_chunk.getOrPut(ch) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
            }
            var already = false;
            for (gop.value_ptr.items) |h| {
                if (h == hash) {
                    already = true;
                    break;
                }
            }
            if (!already) gop.value_ptr.append(allocator, hash) catch continue;
        } else {
            if (blocks.fetchRemove(hash)) |_| {
                if (blocks_by_chunk.getPtr(ch)) |list| {
                    for (list.items, 0..) |h, i| {
                        if (h == hash) {
                            _ = list.swapRemove(i);
                            break;
                        }
                    }
                }
            }
        }

        var block_it = blocks.iterator();
        while (block_it.next()) |entry| {
            const p = entry.value_ptr.*;
            const c = chunkHash(p.x >> 4, p.z >> 4);
            const list = blocks_by_chunk.getPtr(c);
            try std.testing.expect(list != null);
            var found = false;
            for (list.?.items) |h| {
                if (h == entry.key_ptr.*) {
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }
    }
}

test "removeBlocksInChunk removes only target chunk blocks" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0x87654321);
    const random = rng.random();

    for (0..100) |_| {
        var blocks = std.AutoHashMap(i64, Protocol.BlockPosition).init(allocator);
        defer blocks.deinit();
        var blocks_by_chunk = std.AutoHashMap(ChunkHash, std.ArrayList(i64)).init(allocator);
        defer {
            var it = blocks_by_chunk.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            blocks_by_chunk.deinit();
        }

        const target_cx = random.intRangeAtMost(i32, -4, 4);
        const target_cz = random.intRangeAtMost(i32, -4, 4);

        for (0..20) |_| {
            const cx = random.intRangeAtMost(i32, -4, 4);
            const cz = random.intRangeAtMost(i32, -4, 4);
            const pos = Protocol.BlockPosition{
                .x = cx * 16 + random.intRangeAtMost(i32, 0, 15),
                .y = random.intRangeAtMost(i32, 0, 255),
                .z = cz * 16 + random.intRangeAtMost(i32, 0, 15),
            };
            const hash = Dimension.blockPosHash(pos);
            const ch = chunkHash(pos.x >> 4, pos.z >> 4);
            blocks.put(hash, pos) catch continue;
            const gop = blocks_by_chunk.getOrPut(ch) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
            }
            var already = false;
            for (gop.value_ptr.items) |h| {
                if (h == hash) {
                    already = true;
                    break;
                }
            }
            if (!already) gop.value_ptr.append(allocator, hash) catch continue;
        }

        const total_before = blocks.count();
        const target_ch = chunkHash(target_cx, target_cz);
        const target_count = if (blocks_by_chunk.getPtr(target_ch)) |list| list.items.len else 0;

        if (blocks_by_chunk.fetchRemove(target_ch)) |entry| {
            var list = entry.value;
            for (list.items) |h| {
                _ = blocks.remove(h);
            }
            list.deinit(allocator);
        }

        try std.testing.expectEqual(total_before - target_count, blocks.count());

        var remaining_it = blocks.iterator();
        while (remaining_it.next()) |entry| {
            const p = entry.value_ptr.*;
            try std.testing.expect((p.x >> 4) != target_cx or (p.z >> 4) != target_cz);
        }
    }
}

test "generation counter strictly increases" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xface1234);
    const random = rng.random();

    var generations = std.AutoHashMap(ChunkHash, u64).init(allocator);
    defer generations.deinit();

    for (0..100) |_| {
        const cx = random.intRangeAtMost(i32, -10, 10);
        const cz = random.intRangeAtMost(i32, -10, 10);
        const hash = chunkHash(cx, cz);

        const old_gen = generations.get(hash) orelse 0;
        const new_gen = old_gen + 1;
        try generations.put(hash, new_gen);

        try std.testing.expect(new_gen > old_gen);
        try std.testing.expectEqual(new_gen, generations.get(hash).?);
    }
}

test "stale cache detected after generation change" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xbabe5678);
    const random = rng.random();

    var cache = std.AutoHashMap(ChunkHash, CachedPacket).init(allocator);
    defer cache.deinit();
    var generations = std.AutoHashMap(ChunkHash, u64).init(allocator);
    defer generations.deinit();

    for (0..100) |_| {
        const cx = random.intRangeAtMost(i32, -5, 5);
        const cz = random.intRangeAtMost(i32, -5, 5);
        const hash = chunkHash(cx, cz);

        const gen = generations.get(hash) orelse 0;
        try cache.put(hash, .{ .data = &.{}, .generation = gen });

        try generations.put(hash, gen + 1);

        const cached = cache.get(hash).?;
        const current_gen = generations.get(hash).?;
        try std.testing.expect(cached.generation != current_gen);
    }
}

test "extracted dimension helpers stay in the test graph" {
    _ = block_pos;
    _ = broadcast;
    _ = random_tick;
    _ = tick_scheduler;
}

test "deinit retires a block before detaching its traits" {
    const source = @embedFile("dimension.zig");
    const deinit_start = std.mem.indexOf(u8, source, "pub fn deinit(self: *Dimension) void {") orelse
        return error.TestUnexpectedResult;
    const remove = std.mem.indexOfPos(u8, source, deinit_start, "self.blocks.remove(blockPosHash(block.position));") orelse {
        std.debug.print("dimension.zig: deinit detaches blocks whose neighbours still resolve them\n", .{});
        return error.TestUnexpectedResult;
    };
    const detach = std.mem.indexOfPos(u8, source, deinit_start, "block.deinit();") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(remove < detach);
}
