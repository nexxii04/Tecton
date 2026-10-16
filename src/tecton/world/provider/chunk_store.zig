const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const LevelDB = @import("leveldb");
const Protocol = @import("protocol");

const Chunk = @import("../chunk/chunk.zig").Chunk;
const chunk_mod = @import("../chunk/chunk.zig");
const SubChunk = @import("../chunk/subchunk.zig").SubChunk;
const Dimension = @import("../dimension/dimension.zig").Dimension;
const chunkHash = @import("../dimension/dimension.zig").chunkHash;
const ChunkHash = @import("../dimension/dimension.zig").ChunkHash;
const key_mod = @import("./leveldb_keys.zig");
const persistence = @import("./persistence.zig");
const LevelDBProvider = @import("./leveldb_provider.zig").LevelDBProvider;
const ChunkColumnData = @import("./world_provider.zig").ChunkColumnData;

pub fn readChunk(provider: *LevelDBProvider, x: i32, z: i32, dimension: *Dimension) !*Chunk {
    provider.awaitChunkRecords(x, z, dimension.dimension_type, &.{.subchunks});
    const gop = try provider.chunks.getOrPut(dimension);
    if (!gop.found_existing) {
        gop.value_ptr.* = std.AutoHashMap(ChunkHash, *Chunk).init(provider.allocator);
    }

    const hash = chunkHash(x, z);
    if (gop.value_ptr.get(hash)) |_| {
        _ = gop.value_ptr.remove(hash);
    }

    const dim_index = key_mod.dimensionIndex(dimension);
    const ver_key = key_mod.versionKey(x, z, dim_index);
    const ver_data = provider.db.get(ver_key.slice()) orelse blk: {
        const old_key = key_mod.versionKeyOld(x, z, dim_index);
        break :blk provider.db.get(old_key.slice()) orelse return error.ChunkNotFound;
    };
    LevelDB.DB.freeValue(ver_data);

    const chunk = try provider.allocator.create(Chunk);
    chunk.* = Chunk.init(provider.allocator, x, z, dimension.dimension_type);

    const offset = chunk_mod.yOffset(dimension.dimension_type);
    for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
        const sc_index: i8 = @intCast(@as(i32, @intCast(i)) - @as(i32, @intCast(offset)));
        const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
        if (provider.db.get(key.slice())) |data| {
            defer LevelDB.DB.freeValue(data);
            var stream = BinaryStream.init(provider.allocator, data, null);
            const sc = try provider.allocator.create(SubChunk);
            sc.* = SubChunk.deserialize(&stream, provider.allocator) catch {
                provider.allocator.destroy(sc);
                continue;
            };
            chunk.subchunks[i] = sc;
        }
    }

    try gop.value_ptr.put(hash, chunk);
    return chunk;
}

pub fn uncacheChunk(provider: *LevelDBProvider, x: i32, z: i32, dimension: *Dimension) void {
    if (provider.chunks.getPtr(dimension)) |dim_map| {
        _ = dim_map.remove(chunkHash(x, z));
    }
}

pub fn writeChunk(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    const gop = try provider.chunks.getOrPut(dimension);
    if (!gop.found_existing) {
        gop.value_ptr.* = std.AutoHashMap(ChunkHash, *Chunk).init(provider.allocator);
    }
    try gop.value_ptr.put(chunkHash(chunk.x, chunk.z), chunk);

    if (!chunk.dirty) return;

    const record = try encodeChunk(provider, chunk, dimension);
    chunk.dirty = false;
    provider.dispatch(.subchunks, key_mod.dimensionIndex(dimension), chunk.x, chunk.z, record);
}

pub fn encodeChunk(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !persistence.Record {
    const dim_index = key_mod.dimensionIndex(dimension);
    const offset = chunk_mod.yOffset(dimension.dimension_type);

    var record = persistence.Record{};
    errdefer record.deinit(provider.allocator);

    for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
        if (chunk.subchunks[i]) |sc| {
            const key = key_mod.subchunkKey(chunk.x, chunk.z, @intCast(@as(i32, @intCast(i)) - @as(i32, @intCast(offset))), dim_index);
            if (sc.isEmpty()) {
                try record.addDelete(provider.allocator, key.slice());
                continue;
            }
            var stream = BinaryStream.init(provider.allocator, null, null);
            defer stream.deinit();
            try sc.serializePersistence(&stream, provider.allocator);
            try record.addPut(provider.allocator, key.slice(), stream.getBuffer());
        }
    }

    const ver_key = key_mod.versionKey(chunk.x, chunk.z, dim_index);
    try record.addPut(provider.allocator, ver_key.slice(), &[_]u8{40});
    return record;
}

pub fn readChunkDirect(provider: *LevelDBProvider, x: i32, z: i32, dim_type: @import("protocol").DimensionType) !*Chunk {
    provider.awaitChunkRecords(x, z, dim_type, &.{.subchunks});
    const dim_index: i32 = switch (dim_type) {
        .Overworld => 0,
        .Nether => 1,
        .End => 2,
    };

    const ver_key = key_mod.versionKey(x, z, dim_index);
    const ver_data = provider.db.get(ver_key.slice()) orelse blk: {
        const old_key = key_mod.versionKeyOld(x, z, dim_index);
        break :blk provider.db.get(old_key.slice()) orelse return error.ChunkNotFound;
    };
    LevelDB.DB.freeValue(ver_data);

    const chunk = try provider.allocator.create(Chunk);
    chunk.* = Chunk.init(provider.allocator, x, z, dim_type);

    const offset = chunk_mod.yOffset(dim_type);
    for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
        const sc_index: i8 = @intCast(@as(i32, @intCast(i)) - @as(i32, @intCast(offset)));
        const key = key_mod.subchunkKey(x, z, sc_index, dim_index);
        if (provider.db.get(key.slice())) |data| {
            defer LevelDB.DB.freeValue(data);
            var stream = BinaryStream.init(provider.allocator, data, null);
            const sc = provider.allocator.create(SubChunk) catch continue;
            sc.* = SubChunk.deserialize(&stream, provider.allocator) catch {
                provider.allocator.destroy(sc);
                continue;
            };
            chunk.subchunks[i] = sc;
        }
    }

    return chunk;
}

pub fn readChunkColumn(provider: *LevelDBProvider, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: Protocol.DimensionType, read_block_entities: bool) !ChunkColumnData {
    var kinds: [2]persistence.Kind = undefined;
    kinds[0] = .subchunks;
    var kind_count: usize = 1;
    if (read_block_entities) {
        kinds[1] = .block_entities;
        kind_count = 2;
    }
    provider.awaitChunkRecords(x, z, dim_type, kinds[0..kind_count]);
    const dim_index: i32 = switch (dim_type) {
        .Overworld => 0,
        .Nether => 1,
        .End => 2,
    };

    const base = key_mod.chunkKeyBase(x, z, dim_index);
    var result = ChunkColumnData{};
    errdefer result.deinit(allocator);

    const offset = chunk_mod.yOffset(dim_type);
    var iter = provider.db.iterator();
    defer iter.deinit();

    iter.seek(base.buf[0..base.len]);

    while (iter.valid()) {
        const k = iter.key();
        if (k.len < base.len or !std.mem.eql(u8, k[0..base.len], base.buf[0..base.len])) break;

        const tag_byte = k[base.len];

        if (tag_byte == key_mod.TAG_VERSION or tag_byte == key_mod.TAG_VERSION_OLD) {
            result.has_version = true;
        } else if (tag_byte == key_mod.TAG_SUBCHUNK_PREFIX and k.len == base.len + 2) {
            const sc_index: i8 = @bitCast(k[base.len + 1]);
            const array_idx: i32 = @as(i32, sc_index) + @as(i32, @intCast(offset));
            if (array_idx >= 0 and array_idx < chunk_mod.MAX_SUBCHUNKS) {
                const v = iter.value();
                result.subchunks[@intCast(array_idx)] = try allocator.dupe(u8, v);
            }
        } else if (tag_byte == key_mod.TAG_BLOCK_ENTITY and read_block_entities) {
            const v = iter.value();
            result.block_entity_data = try allocator.dupe(u8, v);
        }

        iter.next();
    }

    if (!result.has_version) return error.ChunkNotFound;

    return result;
}

pub fn readBlockEntityBytes(provider: *LevelDBProvider, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: Protocol.DimensionType) !?[]const u8 {
    provider.awaitChunkRecords(x, z, dim_type, &.{.block_entities});
    const dim_index: i32 = switch (dim_type) {
        .Overworld => 0,
        .Nether => 1,
        .End => 2,
    };
    const key = key_mod.blockEntityKey(x, z, dim_index);
    const data = provider.db.get(key.slice()) orelse return null;
    defer LevelDB.DB.freeValue(data);
    return try allocator.dupe(u8, data);
}
