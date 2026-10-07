const std = @import("std");
const SubChunk = @import("./subchunk.zig").SubChunk;
const BiomeStorage = @import("./storage/biome-storage.zig").BiomeStorage;
const BlockPermutation = @import("../block/block-permutation.zig").BlockPermutation;
const BinaryStream = @import("BinaryStream").BinaryStream;
const DimensionType = @import("protocol").DimensionType;

pub const MAX_SUBCHUNKS: usize = 24;
pub const OVERWORLD_OFFSET: usize = 4;

const COLUMN_COUNT: usize = 16 * 16;
/// Heightmap slot that has not been scanned yet.
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
    /// Highest non-air block of each column, scanned at most once per column and
    /// cleared by the writes that touch it: sky access is then a single compare
    /// instead of walking every block up to the build limit.
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
        sc.* = try SubChunk.init(self.allocator, @intCast(@as(i32, @intCast(idx)) - @as(i32, @intCast(offset))));
        self.subchunks[idx] = sc;
        return sc;
    }

    pub fn getPermutation(self: *Chunk, x: i32, y: i32, z: i32, layer: usize) !*BlockPermutation {
        const idx = self.resolveIndex(y) orelse return error.OutOfBounds;
        const sc = try self.getOrCreateSubChunk(idx);
        const state = try sc.getState(@intCast(x & 0xf), @intCast(@as(u32, @bitCast(y)) & 0xf), @intCast(z & 0xf), layer);
        return BlockPermutation.getByNetworkId(state) orelse return error.UnknownPermutation;
    }

    pub fn getPermutationReadOnly(self: *const Chunk, x: i32, y: i32, z: i32, layer: usize) !*BlockPermutation {
        const idx = self.resolveIndex(y) orelse return error.OutOfBounds;
        const sc = self.subchunks[idx] orelse return BlockPermutation.getByNetworkId(0) orelse error.UnknownPermutation;
        if (layer >= sc.layers.items.len) return BlockPermutation.getByNetworkId(0) orelse error.UnknownPermutation;
        const state = sc.layers.items[layer].getState(@intCast(x & 0xf), @intCast(@as(u32, @bitCast(y)) & 0xf), @intCast(z & 0xf));
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

    /// Lowest y this chunk can hold, inclusive.
    pub fn minBuildY(self: *const Chunk) i32 {
        return -@as(i32, @intCast(yOffset(self.dimension))) * 16;
    }

    /// One past the highest y this chunk can hold.
    pub fn buildLimit(self: *const Chunk) i32 {
        return (@as(i32, @intCast(MAX_SUBCHUNKS)) - @as(i32, @intCast(yOffset(self.dimension)))) * 16;
    }

    /// Highest non-air block of the column, or `minBuildY() - 1` when the whole
    /// column is air.
    pub fn topBlockY(self: *Chunk, x: i32, z: i32) i32 {
        const column = columnIndex(x, z);
        if (self.heightmap[column] == HEIGHTMAP_UNCOMPUTED) {
            self.heightmap[column] = self.scanColumnTop(x, z);
        }
        return self.heightmap[column];
    }

    /// True when the column is clear from `y + 2` up to the build limit, so rain
    /// reaches an entity standing at `y`. The block at `y + 1` is inside the
    /// grace: being level with a block is not shelter.
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

    /// Whole subchunks bypass `setPermutation`, so any chunk that receives them
    /// (disk loads, generated batches) has to drop its cached heights.
    pub fn invalidateHeightmap(self: *Chunk) void {
        @memset(&self.heightmap, HEIGHTMAP_UNCOMPUTED);
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
        for (0..send_count) |i| {
            if (self.subchunks[i]) |sc| {
                try sc.biomes.serialize(stream);
            }
        }
        try stream.writeUint8(0);
    }
};

const testing = std.testing;

const TestBlocks = struct {
    air: *BlockPermutation,
    stone: *BlockPermutation,
};

/// The block registries are global, so each test registers its own pair and
/// tears them down before the next one runs.
fn registerTestBlocks(allocator: std.mem.Allocator) !TestBlocks {
    const BlockType = @import("../block/block-type.zig").BlockType;
    const BlockState = @import("../block/block-permutation.zig").BlockState;

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
    @import("../block/block-type.zig").BlockType.deinitRegistry();
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

    // The first query fills the slot the sky check reads, and writing another
    // column leaves it cached.
    try testing.expectEqual(@as(i32, 64), chunk.heightmap[columnIndex(1, 1)]);
    try chunk.setPermutation(2, 70, 1, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 64), chunk.heightmap[columnIndex(1, 1)]);
    try testing.expectEqual(HEIGHTMAP_UNCOMPUTED, chunk.heightmap[columnIndex(2, 1)]);
    try testing.expectEqual(@as(i32, 70), chunk.topBlockY(2, 1));

    // A block below the surface does not move the top...
    try chunk.setPermutation(1, 30, 1, blocks.stone, 0);
    try testing.expectEqual(@as(i32, 64), chunk.topBlockY(1, 1));

    // ...but breaking the top block re-scans the column.
    try chunk.setPermutation(1, 64, 1, blocks.air, 0);
    try testing.expectEqual(@as(i32, 30), chunk.topBlockY(1, 1));

    // The lowest layer of the overworld still counts as a block.
    try chunk.setPermutation(0, -64, 0, blocks.stone, 0);
    try testing.expectEqual(@as(i32, -64), chunk.topBlockY(0, 0));
}

test "sky exposure looks past the two block grace" {
    const allocator = testing.allocator;
    const blocks = try registerTestBlocks(allocator);
    defer deinitTestBlocks();

    var chunk = Chunk.init(allocator, 0, 0, .Overworld);
    defer chunk.deinit();

    // An empty column has nothing overhead.
    try testing.expect(chunk.isSkyExposed(1, 64, 1));

    // A block level with the feet and one above it are not a roof.
    try chunk.setPermutation(1, 64, 1, blocks.stone, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));
    try chunk.setPermutation(1, 65, 1, blocks.stone, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));

    // From feet + 2 up, any block shelters.
    try chunk.setPermutation(1, 66, 1, blocks.stone, 0);
    try testing.expect(!chunk.isSkyExposed(1, 64, 1));

    // Breaking the roof exposes the column again without a rescan of the world.
    try chunk.setPermutation(1, 66, 1, blocks.air, 0);
    try testing.expect(chunk.isSkyExposed(1, 64, 1));
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
