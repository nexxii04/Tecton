const std = @import("std");
const SubChunk = @import("./subchunk.zig").SubChunk;
const BiomeStorage = @import("./storage/biome_storage.zig").BiomeStorage;
const BlockStorage = @import("./storage/block_storage.zig").BlockStorage;
const BlockPermutation = @import("../block/block_permutation.zig").BlockPermutation;
const BinaryStream = @import("BinaryStream").BinaryStream;
const DimensionType = @import("protocol").DimensionType;

pub const MAX_SUBCHUNKS: usize = 24;
pub const OVERWORLD_OFFSET: usize = 4;

pub const empty_layer_byte_budget: usize = 512;
pub const empty_subchunk_byte_budget: usize = 1024;
pub const superflat_chunk_byte_budget: usize = 20 * 1024;

const COLUMN_COUNT: usize = 16 * 16;

const HEIGHTMAP_UNCOMPUTED: i32 = std.math.minInt(i32);

pub fn yOffset(dimension: DimensionType) usize {
    return if (dimension == .Overworld) OVERWORLD_OFFSET else 0;
}

fn columnIndex(x: i32, z: i32) usize {
    return @intCast((x & 0xf) | ((z & 0xf) << 4));
}

pub const Chunk = struct {
    allocator: std.mem.Allocator,
    x: i32,
    z: i32,
    dimension: DimensionType,
    subchunks: [MAX_SUBCHUNKS]?*SubChunk,

    heightmap: [COLUMN_COUNT]i32,
    dirty: bool,
    cache: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, x: i32, z: i32, dimension: DimensionType) Chunk {
        return Chunk{
            .allocator = allocator,
            .x = x,
            .z = z,
            .dimension = dimension,
            .subchunks = [_]?*SubChunk{null} ** MAX_SUBCHUNKS,
            .heightmap = [_]i32{HEIGHTMAP_UNCOMPUTED} ** COLUMN_COUNT,
            .dirty = false,
            .cache = null,
        };
    }

    pub fn deinit(self: *Chunk) void {
        for (&self.subchunks) |*slot| {
            if (slot.*) |sc| {
                sc.deinit();
                self.allocator.destroy(sc);
                slot.* = null;
            }
        }
        if (self.cache) |c| self.allocator.free(c);
    }

    fn resolveIndex(self: *const Chunk, y: i32) ?usize {
        const offset: i32 = @intCast(yOffset(self.dimension));
        const idx = offset + (y >> 4);
        if (idx < 0 or idx >= MAX_SUBCHUNKS) return null;
        return @intCast(idx);
    }

    fn getOrCreateSubChunk(self: *Chunk, idx: usize) !*SubChunk {
        if (self.subchunks[idx]) |sc| return sc;
        const offset = yOffset(self.dimension);
        const sc = try self.allocator.create(SubChunk);
        sc.* = SubChunk.init(self.allocator, @intCast(@as(i32, @intCast(idx)) - @as(i32, @intCast(offset))));
        self.subchunks[idx] = sc;
        return sc;
    }

    pub fn getPermutation(self: *Chunk, x: i32, y: i32, z: i32, layer: usize) !*BlockPermutation {
        return self.getPermutationReadOnly(x, y, z, layer);
    }

    pub fn getPermutationReadOnly(self: *const Chunk, x: i32, y: i32, z: i32, layer: usize) !*BlockPermutation {
        const idx = self.resolveIndex(y) orelse return error.OutOfBounds;
        const sc = self.subchunks[idx] orelse return BlockPermutation.getByNetworkId(0) orelse error.UnknownPermutation;
        const state = sc.getState(@intCast(x & 0xf), @intCast(@as(u32, @bitCast(y)) & 0xf), @intCast(z & 0xf), layer);
        return BlockPermutation.getByNetworkId(state) orelse return error.UnknownPermutation;
    }

    pub fn setPermutation(self: *Chunk, x: i32, y: i32, z: i32, permutation: *BlockPermutation, layer: usize) !void {
        const idx = self.resolveIndex(y) orelse return error.OutOfBounds;
        const sc = try self.getOrCreateSubChunk(idx);
        try sc.setState(@intCast(x & 0xf), @intCast(@as(u32, @bitCast(y)) & 0xf), @intCast(z & 0xf), permutation.network_id, layer);
        self.heightmap[columnIndex(x, z)] = HEIGHTMAP_UNCOMPUTED;
        self.dirty = true;
        self.invalidateCache();
    }

    pub fn minBuildY(self: *const Chunk) i32 {
        return -@as(i32, @intCast(yOffset(self.dimension))) * 16;
    }

    pub fn buildLimit(self: *const Chunk) i32 {
        return (@as(i32, @intCast(MAX_SUBCHUNKS)) - @as(i32, @intCast(yOffset(self.dimension)))) * 16;
    }

    pub fn topBlockY(self: *Chunk, x: i32, z: i32) i32 {
        const column = columnIndex(x, z);
        if (self.heightmap[column] == HEIGHTMAP_UNCOMPUTED) {
            self.heightmap[column] = self.scanColumnTop(x, z);
        }
        return self.heightmap[column];
    }

    pub fn isSkyExposed(self: *Chunk, x: i32, y: i32, z: i32) bool {
        return self.topBlockY(x, z) < y + 2;
    }

    fn scanColumnTop(self: *const Chunk, x: i32, z: i32) i32 {
        var y = self.buildLimit() - 1;
        const floor = self.minBuildY();
        while (y >= floor) : (y -= 1) {
            const permutation = self.getPermutationReadOnly(x, y, z, 0) catch return y;
            if (!std.mem.eql(u8, permutation.identifier, "minecraft:air")) return y;
        }
        return floor - 1;
    }

    pub fn invalidateHeightmap(self: *Chunk) void {
        @memset(&self.heightmap, HEIGHTMAP_UNCOMPUTED);
    }

    pub fn bytesUsed(self: *const Chunk) usize {
        var total: usize = @sizeOf(Chunk);
        for (self.subchunks) |maybe_sc| {
            if (maybe_sc) |sc| total += sc.bytesUsed();
        }
        return total;
    }

    pub fn getSubChunkSendCount(self: *const Chunk) usize {
        var count: usize = MAX_SUBCHUNKS;
        while (count > 0) : (count -= 1) {
            if (self.subchunks[count - 1]) |sc| {
                if (!sc.isEmpty()) return count;
            }
        }
        return 0;
    }

    fn invalidateCache(self: *Chunk) void {
        if (self.cache) |c| {
            self.allocator.free(c);
            self.cache = null;
        }
    }

    pub fn serialize(self: *Chunk, stream: *BinaryStream) !void {
        const send_count = self.getSubChunkSendCount();
        for (0..send_count) |i| {
            if (self.subchunks[i]) |sc| {
                try sc.serialize(stream);
            } else {
                const offset = yOffset(self.dimension);
                try stream.writeUint8(9);
                try stream.writeUint8(0);
                try stream.writeInt8(@intCast(@as(i32, @intCast(i)) - @as(i32, @intCast(offset))));
            }
        }
        // Biomes cover the dimension's entire height, independently of how many
        // terrain sections were sent. Missing terrain still needs a biome palette.
        const biome_count: usize = switch (self.dimension) {
            .Overworld => 24,
            .Nether => 8,
            .End => 16,
        };
        const empty_biomes = BiomeStorage.init(self.allocator);
        for (0..biome_count) |i| {
            const biomes = if (self.subchunks[i]) |sc| &sc.biomes else &empty_biomes;
            try biomes.serialize(stream);
        }
        try stream.writeUint8(0);
    }
};

const testing = std.testing;

const TestBlocks = struct {
    air: *BlockPermutation,
    stone: *BlockPermutation,
};

fn registerTestBlocks(allocator: std.mem.Allocator) !TestBlocks {
    const BlockType = @import("../block/block_type.zig").BlockType;
    const BlockState = @import("../block/block_permutation.zig").BlockState;

    try BlockPermutation.initRegistry(allocator);
    errdefer BlockPermutation.deinitRegistry();
    try BlockType.initRegistry(allocator);
    errdefer BlockType.deinitRegistry();

    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air = try BlockPermutation.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
    try air.register();
    try air_type.addPermutation(air);

    const stone_type = try BlockType.init(allocator, "minecraft:stone");
    try stone_type.register();
    const stone = try BlockPermutation.init(allocator, 1, "minecraft:stone", BlockState.init(allocator));
    try stone.register();
    try stone_type.addPermutation(stone);

    return .{ .air = air, .stone = stone };
}

fn deinitTestBlocks() void {
    @import("../block/block_type.zig").BlockType.deinitRegistry();
    BlockPermutation.deinitRegistry();
}

test "the heightmap reports the top block of a column" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    try testing.expectEqual(@as(i32, -64), chunk.minBuildY());
    try testing.expectEqual(@as(i32, 320), chunk.buildLimit());
    try testing.expectEqual(@as(i32, -65), chunk.topBlockY(1, 1));

    try chunk.setPermutation(1, 64, 1, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 64), chunk.topBlockY(1, 1));

    try testing.expectEqual(@as(i32, 64), chunk.heightmap[columnIndex(1, 1)]);
    try chunk.setPermutation(2, 70, 1, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 64), chunk.heightmap[columnIndex(1, 1)]);
    try testing.expectEqual(HEIGHTMAP_UNCOMPUTED, chunk.heightmap[columnIndex(2, 1)]);
    try testing.expectEqual(@as(i32, 70), chunk.topBlockY(2, 1));

    try chunk.setPermutation(1, 30, 1, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 64), chunk.topBlockY(1, 1));

    try chunk.setPermutation(1, 64, 1, blocks.air, 0);
    try testing.expectEqual(@as(i32, 30), chunk.topBlockY(1, 1));

    try chunk.setPermutation(0, -64, 0, blocks.stone, 0);
    try testing.expectEqual(@as(i32, -64), chunk.topBlockY(0, 0));
}

test "block storage grows across seven-bit threshold and rejects corrupt wire data" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var storage = try BlockStorage.init(allocator);
    defer storage.deinit();

    for (0..80) |i| {
        try storage.setState(@intCast(i & 15), @intCast((i >> 4) & 15), 0, @intCast(1000 + i));
    }
    for (0..80) |i| {
        try testing.expectEqual(@as(i32, @intCast(1000 + i)), storage.getState(@intCast(i & 15), @intCast((i >> 4) & 15), 0));
    }

    var invalid_bits = [_]u8{14};
    var reader = BinaryStream.init(testing.failing_allocator, &invalid_bits, null);
    try testing.expectError(error.InvalidBitsPerBlock, BlockStorage.deserialize(&reader, allocator));

    var corrupt = [_]u8{0} ** 516;
    corrupt[0] = (1 << 1) | 1;
    corrupt[1] = 1;
    corrupt[513] = 2;
    corrupt[514] = @intCast(blocks.air.network_id << 1);
    reader = BinaryStream.init(testing.failing_allocator, &corrupt, null);
    try testing.expectError(error.InvalidPaletteIndex, BlockStorage.deserialize(&reader, allocator));
}

test "sky exposure looks past the two block grace" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    try testing.expect(chunk.isSkyExposed(1, 64, 1));

    try chunk.setPermutation(1, 64, 1, blocks.stone, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));
    try chunk.setPermutation(1, 65, 1, blocks.stone, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));

    try chunk.setPermutation(1, 66, 1, blocks.stone, 0);
    try testing.expect(!chunk.isSkyExposed(1, 64, 1));

    try chunk.setPermutation(1, 66, 1, blocks.air, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));
}

test "a superflat chunk stays inside the per-chunk byte budget" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var layer = try BlockStorage.init(allocator);
    defer layer.deinit();
    try testing.expect(layer.heapBytes() <= empty_layer_byte_budget);
    try testing.expectEqual(0, layer.getState(3, 3, 3));
    try layer.setState(3, 3, 3, blocks.air.network_id);
    try testing.expect(layer.heapBytes() <= empty_layer_byte_budget);

    var sub = SubChunk.init(allocator, 0);
    defer sub.deinit();
    try testing.expect(sub.bytesUsed() <= empty_subchunk_byte_budget);
    try testing.expectEqual(@as(usize, 0), sub.biomes.heapBytes());

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    try testing.expect(chunk.bytesUsed() <= superflat_chunk_byte_budget);
    try testing.expect(chunk.subchunks[4 + 12] == null);
    try testing.expectEqualStrings("minecraft:air", (try chunk.getPermutation(5, 200, 5, 0)).identifier);
    try testing.expect(chunk.subchunks[4 + 12] == null);

    try chunk.setPermutation(0, 64, 0, blocks.stone, 0);
    try chunk.setPermutation(15, 64, 15, blocks.stone, 0);

    const sc = chunk.subchunks[8].?;
    try testing.expectEqual(@as(usize, 1), sc.layers.items.len);
    try testing.expectEqual(@as(usize, 2), sc.layers.items[0].paletteSlice().len);
    try testing.expect(sc.layers.items[0].heapBytes() <= 1024);
    try testing.expect(chunk.bytesUsed() <= superflat_chunk_byte_budget);

    try testing.expectEqual(0, sc.getState(1, 1, 1, 1));
    try testing.expectEqual(@as(usize, 1), sc.layers.items.len);

    try testing.expectEqual(@as(usize, 0), sc.biomes.heapBytes());
    try testing.expectEqual(@as(u32, 0), sc.getBiome(1, 1, 1));
    try sc.setBiome(1, 1, 1, 7);
    try testing.expectEqual(@as(u32, 7), sc.getBiome(1, 1, 1));
    try testing.expectEqual(@as(u32, 0), sc.getBiome(2, 1, 1));
}

test "packed block storage round-trips through the wire format" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var storage = try BlockStorage.init(allocator);
    defer storage.deinit();

    try storage.setState(0, 0, 0, blocks.stone.network_id);
    for (0..40) |i| {
        try storage.setState(@intCast(i & 0xf), @intCast(i >> 4), 3, @intCast(100 + i));
    }
    try testing.expect(storage.heapBytes() <= 4096);

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try storage.serialize(&stream);

    var reader = BinaryStream.init(allocator, stream.getBuffer(), null);
    var decoded = try BlockStorage.deserialize(&reader, allocator);
    defer decoded.deinit();

    for (0..4096) |pos| {
        try testing.expectEqual(storage.paletteIndexAt(pos), decoded.paletteIndexAt(pos));
        const bx: u8 = @intCast((pos >> 8) & 0xf);
        const by: u8 = @intCast(pos & 0xf);
        const bz: u8 = @intCast((pos >> 4) & 0xf);
        try testing.expectEqual(storage.getState(bx, by, bz), decoded.getState(bx, by, bz));
    }
}

fn exerciseChunkGrowth(allocator: std.mem.Allocator, stone: *BlockPermutation) !void {
    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();
    try chunk.setPermutation(0, 64, 0, stone, 0);
    for (0..40) |index| try chunk.subchunks[8].?.setState(@intCast(index & 15), @intCast(index >> 4), 3, @intCast(100 + index), 0);
    try std.testing.expectEqual(@as(i32, 139), chunk.subchunks[8].?.getState(7, 2, 3, 0));
}

test "chunk layer growth unwinds every allocation failure" {
    const blocks = try registerTestBlocks(testing.allocator);
    defer deinitTestBlocks();
    try testing.checkAllAllocationFailures(testing.allocator, exerciseChunkGrowth, .{blocks.stone});
}

test "chunk serialization borrows a fixed output buffer without allocating" {
    const blocks = try registerTestBlocks(testing.allocator);
    defer deinitTestBlocks();
    var chunk = Chunk.init(testing.allocator, 0, 0, .Overworld);
    defer chunk.deinit();
    try chunk.setPermutation(0, -64, 0, blocks.stone, 0);
    var bytes: [4096]u8 = undefined;
    var stream = BinaryStream.init(testing.failing_allocator, &bytes, null);
    stream.reset();
    try chunk.serialize(&stream);
    try testing.expect(stream.getBuffer().len > 0);
}

test "chunk network payload includes every biome section even without terrain" {
    for ([_]DimensionType{ .Overworld, .Nether, .End }, [_]usize{ 24, 8, 16 }) |dimension, biome_count| {
        var chunk = Chunk.init(testing.allocator, 0, 0, dimension);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), chunk.getSubChunkSendCount());

        var bytes: [128]u8 = undefined;
        var stream = BinaryStream.init(testing.failing_allocator, &bytes, null);
        stream.reset();
        try chunk.serialize(&stream);

        var reader = BinaryStream.init(testing.failing_allocator, stream.getBuffer(), null);
        for (0..biome_count) |_| {
            try testing.expectEqual(@as(u8, 0x01), try reader.readUint8());
            try testing.expectEqual(@as(i32, 0), try reader.readZigZag());
        }
        try testing.expectEqual(@as(u8, 0), try reader.readUint8());
        try testing.expect(reader.isEof());
    }
}

test "chunk network payload keeps biome sections for sparse terrain" {
    const blocks = try registerTestBlocks(testing.allocator);
    defer deinitTestBlocks();
    var chunk = Chunk.init(testing.allocator, 0, 0, .Overworld);
    defer chunk.deinit();
    try chunk.setPermutation(0, -32, 0, blocks.stone, 0);
    const above_terrain = try chunk.getOrCreateSubChunk(20);
    try above_terrain.biomes.palette.append(testing.allocator, 300);
    try testing.expectEqual(@as(usize, 3), chunk.getSubChunkSendCount());

    var stream = BinaryStream.init(testing.allocator, null, null);
    defer stream.deinit();
    try chunk.serialize(&stream);

    var reader = BinaryStream.init(testing.failing_allocator, stream.getBuffer(), null);
    for (0..chunk.getSubChunkSendCount()) |_| {
        var sub = try SubChunk.deserialize(&reader, testing.allocator);
        sub.deinit();
    }
    for (0..MAX_SUBCHUNKS) |i| {
        try testing.expectEqual(@as(u8, 0x01), try reader.readUint8());
        try testing.expectEqual(@as(i32, if (i == 20) 300 else 0), try reader.readZigZag());
    }
    try testing.expectEqual(@as(u8, 0), try reader.readUint8());
    try testing.expect(reader.isEof());
}

test "a chunk without the overworld offset keeps its own build range" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var chunk = Chunk.init(allocator, 0, 0, .Nether);
    defer chunk.deinit();

    try testing.expectEqual(@as(i32, 0), chunk.minBuildY());
    try testing.expectEqual(@as(i32, 384), chunk.buildLimit());
    try testing.expectEqual(@as(i32, -1), chunk.topBlockY(0, 0));

    try chunk.setPermutation(0, 0, 0, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 0), chunk.topBlockY(0, 0));

    chunk.invalidateHeightmap();
    try testing.expectEqual(HEIGHTMAP_UNCOMPUTED, chunk.heightmap[columnIndex(0, 0)]);
    try testing.expectEqual(@as(i32, 0), chunk.topBlockY(0, 0));
}
