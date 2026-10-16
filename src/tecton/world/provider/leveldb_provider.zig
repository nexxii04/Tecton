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

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("../block/block_permutation.zig");
    pub const test_dependency_1 = @import("../block/block_type.zig");
    pub const test_dependency_2 = @import("./internal_provider.zig");
    pub const std = test_owner.std;
    pub const LevelDB = test_owner.LevelDB;
    pub const BlockPermutation = test_owner.BlockPermutation;
    pub const Chunk = test_owner.Chunk;
    pub const SubChunk = test_owner.SubChunk;
    pub const chunk_mod = test_owner.chunk_mod;
    pub const Dimension = test_owner.Dimension;
    pub const chunk_store = test_owner.chunk_store;
    pub const key_mod = test_owner.key_mod;
    pub const persistence = test_owner.persistence;
    pub const LevelDBProvider = test_owner.LevelDBProvider;
};

test "WriteBatch chunk column round-trip" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_000();
}

test "a queued chunk write is visible to the next read" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_001();
}

test "cleared subchunks are deleted from persisted chunk data" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_002();
}

test "WriteBatch saveAll multi-chunk persistence" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_003();
}

test "readChunkColumn skips block entities when flag is false" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_004();
}

test "the in-memory provider stays in the test graph" {
    try @import("leveldb_provider_test.zig").Suite(test_scope).case_005();
}
