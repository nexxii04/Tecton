const std = @import("std");

const LevelDB = @import("leveldb");
const Protocol = @import("protocol");

const Player = @import("../../player/player.zig").Player;
const BlockPermutation = @import("../block/block_permutation.zig").BlockPermutation;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const SubChunk = @import("../chunk/subchunk.zig").SubChunk;
const chunk_mod = @import("../chunk/chunk.zig");
const Dimension = @import("../dimension/dimension.zig").Dimension;
const ChunkHash = @import("../dimension/dimension.zig").ChunkHash;
const block_entities = @import("./block_entities.zig");
const chunk_entities = @import("./chunk_entities.zig");
const chunk_store = @import("./chunk_store.zig");
const key_mod = @import("./leveldb_keys.zig");
const persistence = @import("./persistence.zig");
const player_store = @import("./player_store.zig");
const WorldProvider = @import("./world_provider.zig").WorldProvider;
const ChunkColumnData = @import("./world_provider.zig").ChunkColumnData;

pub const LevelDBProvider = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    path: []const u8,
    db: LevelDB.DB,
    chunks: std.AutoHashMap(*Dimension, std.AutoHashMap(ChunkHash, *Chunk)),
    writer: persistence.Writer,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: [*:0]const u8) !*LevelDBProvider {
        const self = try allocator.create(LevelDBProvider);
        errdefer allocator.destroy(self);
        var db = try LevelDB.DB.open(path, true);
        errdefer db.close();
        const owned_path = try allocator.dupe(u8, std.mem.span(path));
        errdefer allocator.free(owned_path);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .path = owned_path,
            .db = db,
            .chunks = std.AutoHashMap(*Dimension, std.AutoHashMap(ChunkHash, *Chunk)).init(allocator),
            .writer = persistence.Writer.init(io, allocator, .{ .ctx = self, .write = sinkWrite }),
        };
        try self.writer.start();
        return self;
    }

    pub fn deinit(self: *LevelDBProvider) void {
        self.writer.flush();
        self.writer.logStats(self.path);
        self.writer.deinit();
        var chunk_iter = self.chunks.iterator();
        while (chunk_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.chunks.deinit();
        self.db.close();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn dispatch(self: *LevelDBProvider, kind: persistence.Kind, dim_index: i32, x: i32, z: i32, record: persistence.Record) void {
        var pending = record;
        self.writer.enqueueKeyed(persistence.chunkKey(kind, dim_index, x, z), pending) catch {
            self.writeRecordSync(&pending);
            pending.deinit(self.allocator);
        };
    }

    pub fn dispatchOrdered(self: *LevelDBProvider, record: persistence.Record) void {
        var pending = record;
        self.writer.enqueueOrdered(pending) catch {
            self.writeRecordSync(&pending);
            pending.deinit(self.allocator);
        };
    }

    fn writeRecordSync(self: *LevelDBProvider, record: *persistence.Record) void {
        var batch = LevelDB.WriteBatch.init() catch |err| {
            std.log.err("Failed to open a LevelDB write batch: {}", .{err});
            return;
        };
        defer batch.deinit();
        for (record.deletes.items) |key| batch.delete(key);
        for (record.puts.items) |put| batch.put(put.key, put.value);
        batch.write(&self.db) catch |err| std.log.err("Failed to flush a storage record: {}", .{err});
    }

    pub fn awaitChunkRecords(self: *LevelDBProvider, x: i32, z: i32, dim_type: Protocol.DimensionType, kinds: []const persistence.Kind) void {
        const dim_index: i32 = switch (dim_type) {
            .Overworld => 0,
            .Nether => 1,
            .End => 2,
        };
        var keys: [3]persistence.Key = undefined;
        const count = @min(kinds.len, keys.len);
        for (kinds[0..count], keys[0..count]) |kind, *key| {
            key.* = persistence.chunkKey(kind, dim_index, x, z);
        }
        self.writer.awaitKeys(keys[0..count]);
    }

    pub fn saveAll(self: *LevelDBProvider) void {
        var dim_iter = self.chunks.iterator();
        while (dim_iter.next()) |dim_entry| {
            const dimension = dim_entry.key_ptr.*;
            var chunk_iter = dim_entry.value_ptr.valueIterator();
            while (chunk_iter.next()) |chunk_ptr| {
                const chunk = chunk_ptr.*;
                if (!chunk.dirty) continue;
                const record = chunk_store.encodeChunk(self, chunk, dimension) catch continue;
                chunk.dirty = false;
                self.dispatch(.subchunks, key_mod.dimensionIndex(dimension), chunk.x, chunk.z, record);
            }
        }
        self.writer.flush();
    }

    pub fn readBuffer(self: *LevelDBProvider, key: []const u8) !?[]const u8 {
        const val = self.db.get(key) orelse return null;
        const owned = try self.allocator.dupe(u8, val);
        LevelDB.DB.freeValue(val);
        return owned;
    }

    pub fn writeBuffer(self: *LevelDBProvider, key: []const u8, buffer: []const u8) !void {
        try self.db.put(key, buffer);
    }

    pub fn asProvider(self: *LevelDBProvider) WorldProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = WorldProvider.VTable{
        .read_chunk = vtableReadChunk,
        .read_chunk_direct = vtableReadChunkDirect,
        .read_chunk_column = vtableReadChunkColumn,
        .read_chunk_block_entity_data = vtableReadChunkBlockEntityData,
        .write_chunk = vtableWriteChunk,
        .uncache_chunk = vtableUncacheChunk,
        .read_buffer = vtableReadBuffer,
        .write_buffer = vtableWriteBuffer,
        .write_player = vtableWritePlayer,
        .read_player = vtableReadPlayer,
        .write_chunk_entities = vtableWriteChunkEntities,
        .read_chunk_entities = vtableReadChunkEntities,
        .write_block_entities = vtableWriteBlockEntities,
        .read_block_entities = vtableReadBlockEntities,
        .deinit_fn = vtableDeinit,
    };

    fn vtableReadChunk(ptr: *anyopaque, x: i32, z: i32, dimension: *Dimension) anyerror!*Chunk {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_store.readChunk(self, x, z, dimension);
    }

    fn vtableReadChunkDirect(ptr: *anyopaque, x: i32, z: i32, dim_type: @import("protocol").DimensionType) anyerror!*Chunk {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_store.readChunkDirect(self, x, z, dim_type);
    }

    fn vtableReadChunkColumn(ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType, read_block_entities: bool) anyerror!ChunkColumnData {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_store.readChunkColumn(self, allocator, x, z, dim_type, read_block_entities);
    }

    fn vtableReadChunkBlockEntityData(ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType) anyerror!?[]const u8 {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_store.readBlockEntityBytes(self, allocator, x, z, dim_type);
    }

    fn vtableWriteChunk(ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_store.writeChunk(self, chunk, dimension);
    }

    fn vtableUncacheChunk(ptr: *anyopaque, x: i32, z: i32, dimension: *Dimension) void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        chunk_store.uncacheChunk(self, x, z, dimension);
    }

    fn vtableReadBuffer(ptr: *anyopaque, key: []const u8) anyerror!?[]const u8 {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return self.readBuffer(key);
    }

    fn vtableWriteBuffer(ptr: *anyopaque, key: []const u8, buffer: []const u8) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return self.writeBuffer(key, buffer);
    }

    fn vtableWritePlayer(ptr: *anyopaque, uuid: []const u8, player: *Player) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return player_store.writePlayer(self, uuid, player);
    }

    fn vtableReadPlayer(ptr: *anyopaque, uuid: []const u8, player: *Player) anyerror!bool {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return player_store.readPlayer(self, uuid, player);
    }

    fn vtableWriteChunkEntities(ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_entities.writeChunkEntities(self, chunk, dimension);
    }

    fn vtableReadChunkEntities(ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return chunk_entities.loadChunkEntities(self, chunk, dimension);
    }

    fn vtableWriteBlockEntities(ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return block_entities.writeBlockEntities(self, chunk, dimension);
    }

    fn vtableReadBlockEntities(ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        return block_entities.readBlockEntities(self, chunk, dimension);
    }

    fn vtableDeinit(ptr: *anyopaque) void {
        const self: *LevelDBProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

fn sinkWrite(ctx: *anyopaque, puts: []const persistence.Put, deletes: []const []u8) anyerror!void {
    const self: *LevelDBProvider = @ptrCast(@alignCast(ctx));
    var batch = try LevelDB.WriteBatch.init();
    defer batch.deinit();
    for (deletes) |key| batch.delete(key);
    for (puts) |put| batch.put(put.key, put.value);
    try batch.write(&self.db);
}

test "WriteBatch chunk column round-trip" {
    var db = try LevelDB.DB.open("test_prop4_db\x00", true);
    defer {
        db.close();
        std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop4_db") catch {};
    }

    var rng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = rng.random();

    for (0..100) |iter| {
        const x: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) - 50);
        const z: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) + 10);
        const dim_index: i32 = 0;

        var batch = try LevelDB.WriteBatch.init();
        defer batch.deinit();

        const ver_key = key_mod.versionKey(x, z, dim_index);
        batch.put(ver_key.slice(), &[_]u8{40});

        var expected_data: [chunk_mod.MAX_SUBCHUNKS]?[]u8 = .{null} ** chunk_mod.MAX_SUBCHUNKS;
        defer {
            for (&expected_data) |*d| {
                if (d.*) |data| std.testing.allocator.free(data);
            }
        }

        const num_subchunks = random.intRangeAtMost(usize, 1, 8);
        for (0..num_subchunks) |i| {
            const len = random.intRangeAtMost(usize, 4, 64);
            const data = try std.testing.allocator.alloc(u8, len);
            random.bytes(data);
            expected_data[i] = data;

            const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
            const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
            batch.put(key.slice(), data);
        }

        try batch.write(&db);

        const ver_read = db.get(ver_key.slice());
        try std.testing.expect(ver_read != null);
        LevelDB.DB.freeValue(ver_read.?);

        for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
            const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
            const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
            const read_val = db.get(key.slice());
            if (expected_data[i]) |expected| {
                try std.testing.expect(read_val != null);
                try std.testing.expectEqualSlices(u8, expected, read_val.?);
                LevelDB.DB.freeValue(read_val.?);
            } else {
                try std.testing.expect(read_val == null);
            }
        }

        var del_batch = try LevelDB.WriteBatch.init();
        defer del_batch.deinit();
        del_batch.delete(ver_key.slice());
        for (0..num_subchunks) |i| {
            const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
            const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
            del_batch.delete(key.slice());
        }
        try del_batch.write(&db);
    }
}

test "a queued chunk write is visible to the next read" {
    const allocator = std.testing.allocator;
    const BlockType = @import("../block/block_type.zig").BlockType;
    const BlockState = @import("../block/block_permutation.zig").BlockState;

    try BlockPermutation.initRegistry(allocator);
    defer BlockPermutation.deinitRegistry();
    try BlockType.initRegistry(allocator);
    defer BlockType.deinitRegistry();

    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air_state = BlockState.init(allocator);
    const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", air_state);
    try air_perm.register();
    try air_type.addPermutation(air_perm);

    const stone_type = try BlockType.init(allocator, "minecraft:stone");
    try stone_type.register();
    const stone_state = BlockState.init(allocator);
    const stone_perm = try BlockPermutation.init(allocator, 1, "minecraft:stone", stone_state);
    try stone_perm.register();
    try stone_type.addPermutation(stone_perm);

    var provider = try LevelDBProvider.init(std.testing.io, allocator, "test_persist2_db\x00");
    defer {
        provider.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, "test_persist2_db") catch {};
    }

    var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
    defer dimension.deinit();

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    var payload: [2048]u8 = undefined;
    @memset(&payload, 0x5a);
    for (0..256) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "flood-{d}", .{i});
        var record = persistence.Record{};
        try record.addPut(allocator, key, &payload);
        try provider.writer.enqueueKeyed(persistence.chunkKey(.subchunks, 9, @intCast(i), 0), record);
    }

    try chunk.setPermutation(1, 64, 1, stone_perm, 0);
    try chunk_store.writeChunk(provider, &chunk, &dimension);

    const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
    defer {
        persisted.deinit();
        allocator.destroy(persisted);
    }
    const permutation = try persisted.getPermutation(1, 64, 1, 0);
    try std.testing.expectEqualStrings("minecraft:stone", permutation.identifier);
}

test "cleared subchunks are deleted from persisted chunk data" {
    const allocator = std.testing.allocator;
    const BlockType = @import("../block/block_type.zig").BlockType;
    const BlockState = @import("../block/block_permutation.zig").BlockState;

    try BlockPermutation.initRegistry(allocator);
    defer BlockPermutation.deinitRegistry();
    try BlockType.initRegistry(allocator);
    defer BlockType.deinitRegistry();

    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air_state = BlockState.init(allocator);
    const air_perm = try BlockPermutation.init(allocator, 0, "minecraft:air", air_state);
    try air_perm.register();
    try air_type.addPermutation(air_perm);

    const stone_type = try BlockType.init(allocator, "minecraft:stone");
    try stone_type.register();
    const stone_state = BlockState.init(allocator);
    const stone_perm = try BlockPermutation.init(allocator, 1, "minecraft:stone", stone_state);
    try stone_perm.register();
    try stone_type.addPermutation(stone_perm);

    var provider = try LevelDBProvider.init(std.testing.io, allocator, "test_prop7_db\x00");
    defer {
        provider.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop7_db") catch {};
    }

    var dimension = Dimension.init(undefined, allocator, "overworld", .Overworld, null);
    defer dimension.deinit();

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    const sc_slot: usize = 8;
    const sc_index: i8 = @intCast(sc_slot - chunk_mod.yOffset(.Overworld));

    const replaceWithEmptySubChunk = struct {
        fn f(c: *Chunk, alloc: std.mem.Allocator, slot: usize, index: i8) !void {
            if (c.subchunks[slot]) |old_sc| {
                old_sc.deinit();
                alloc.destroy(old_sc);
            }
            const sc = try alloc.create(SubChunk);
            sc.* = try SubChunk.init(alloc, index);
            c.subchunks[slot] = sc;
            c.invalidateHeightmap();
            c.dirty = true;
        }
    }.f;

    try chunk.setPermutation(1, 64, 1, stone_perm, 0);
    try chunk_store.writeChunk(provider, &chunk, &dimension);

    {
        const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
        defer {
            persisted.deinit();
            allocator.destroy(persisted);
        }
        try std.testing.expect(persisted.subchunks[sc_slot] != null);
        try std.testing.expect(!persisted.subchunks[sc_slot].?.isEmpty());
        const perm = try persisted.getPermutation(1, 64, 1, 0);
        try std.testing.expectEqualStrings("minecraft:stone", perm.identifier);
    }

    try replaceWithEmptySubChunk(&chunk, allocator, sc_slot, sc_index);
    try std.testing.expect(chunk.subchunks[sc_slot].?.isEmpty());
    try chunk_store.writeChunk(provider, &chunk, &dimension);

    {
        const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
        defer {
            persisted.deinit();
            allocator.destroy(persisted);
        }
        try std.testing.expect(persisted.subchunks[sc_slot] == null);
    }

    try chunk.setPermutation(1, 64, 1, stone_perm, 0);
    provider.saveAll();

    {
        const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
        defer {
            persisted.deinit();
            allocator.destroy(persisted);
        }
        try std.testing.expect(persisted.subchunks[sc_slot] != null);
        const perm = try persisted.getPermutation(1, 64, 1, 0);
        try std.testing.expectEqualStrings("minecraft:stone", perm.identifier);
    }

    try replaceWithEmptySubChunk(&chunk, allocator, sc_slot, sc_index);
    provider.saveAll();

    {
        const persisted = try chunk_store.readChunkDirect(provider, 0, 0, .Overworld);
        defer {
            persisted.deinit();
            allocator.destroy(persisted);
        }
        try std.testing.expect(persisted.subchunks[sc_slot] == null);
    }
}

test "WriteBatch saveAll multi-chunk persistence" {
    var db = try LevelDB.DB.open("test_prop6_db\x00", true);
    defer {
        db.close();
        std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop6_db") catch {};
    }

    var rng = std.Random.DefaultPrng.init(0xcafebabe);
    const random = rng.random();

    const N = 100;
    var keys: [N]key_mod.KeyBuf = undefined;
    var values: [N][8]u8 = undefined;

    var batch = try LevelDB.WriteBatch.init();
    defer batch.deinit();

    for (0..N) |i| {
        const x: i32 = random.intRangeAtMost(i32, -1000, 1000);
        const z: i32 = random.intRangeAtMost(i32, -1000, 1000);
        keys[i] = key_mod.versionKey(x, z, 0);
        random.bytes(&values[i]);
        batch.put(keys[i].slice(), &values[i]);
    }

    try batch.write(&db);

    for (0..N) |i| {
        const read_val = db.get(keys[i].slice());
        try std.testing.expect(read_val != null);
        try std.testing.expectEqualSlices(u8, &values[i], read_val.?);
        LevelDB.DB.freeValue(read_val.?);
    }
}

test "readChunkColumn skips block entities when flag is false" {
    var provider = try LevelDBProvider.init(std.testing.io, std.testing.allocator, "test_prop5_db\x00");
    defer {
        provider.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, "test_prop5_db") catch {};
    }

    var rng = std.Random.DefaultPrng.init(0xfeed1234);
    const random = rng.random();

    for (0..100) |iter| {
        const x: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) - 50);
        const z: i32 = @intCast(@as(i32, @truncate(@as(i64, @intCast(iter)))) + 20);
        const dim_index: i32 = 0;

        var batch = try LevelDB.WriteBatch.init();
        defer batch.deinit();

        const ver_key = key_mod.versionKey(x, z, dim_index);
        batch.put(ver_key.slice(), &[_]u8{40});

        const slot_offset: usize = chunk_mod.yOffset(.Overworld);
        const num_sc = random.intRangeAtMost(usize, 1, 4);
        var expected_sc: [chunk_mod.MAX_SUBCHUNKS]?[]u8 = .{null} ** chunk_mod.MAX_SUBCHUNKS;
        defer {
            for (&expected_sc) |*d| {
                if (d.*) |data| std.testing.allocator.free(data);
            }
        }

        for (0..num_sc) |i| {
            const len = random.intRangeAtMost(usize, 4, 32);
            const data = try std.testing.allocator.alloc(u8, len);
            random.bytes(data);
            expected_sc[slot_offset + i] = data;
            const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
            const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
            batch.put(key.slice(), data);
        }

        var be_data: [16]u8 = undefined;
        random.bytes(&be_data);
        const be_key = key_mod.blockEntityKey(x, z, dim_index);
        batch.put(be_key.slice(), &be_data);

        try batch.write(&provider.db);

        var col_skip = try chunk_store.readChunkColumn(provider, std.testing.allocator, x, z, .Overworld, false);
        defer col_skip.deinit(std.testing.allocator);
        try std.testing.expect(col_skip.has_version);
        try std.testing.expect(col_skip.block_entity_data == null);
        for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
            if (expected_sc[i]) |expected| {
                try std.testing.expect(col_skip.subchunks[i] != null);
                try std.testing.expectEqualSlices(u8, expected, col_skip.subchunks[i].?);
            } else {
                try std.testing.expect(col_skip.subchunks[i] == null);
            }
        }

        var col_full = try chunk_store.readChunkColumn(provider, std.testing.allocator, x, z, .Overworld, true);
        defer col_full.deinit(std.testing.allocator);
        try std.testing.expect(col_full.block_entity_data != null);
        try std.testing.expectEqualSlices(u8, &be_data, col_full.block_entity_data.?);

        const bytes_opt = try chunk_store.readBlockEntityBytes(provider, std.testing.allocator, x, z, .Overworld);
        try std.testing.expect(bytes_opt != null);
        const bytes = bytes_opt.?;
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &be_data, bytes);
        try std.testing.expect((try chunk_store.readBlockEntityBytes(provider, std.testing.allocator, x + 100000, z, .Overworld)) == null);

        var del_batch = try LevelDB.WriteBatch.init();
        defer del_batch.deinit();
        del_batch.delete(ver_key.slice());
        del_batch.delete(be_key.slice());
        for (0..num_sc) |i| {
            const sc_index: i8 = @intCast(@as(i32, @intCast(i)));
            const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
            del_batch.delete(key.slice());
        }
        try del_batch.write(&provider.db);
    }
}

test "the in-memory provider stays in the test graph" {
    _ = @import("./internal_provider.zig");
}
