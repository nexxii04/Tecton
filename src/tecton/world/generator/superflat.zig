const std = @import("std");

const Protocol = @import("protocol");

const BlockPermutation = @import("../block/block_permutation.zig").BlockPermutation;
const Chunk = @import("../chunk/chunk.zig").Chunk;
const TerrainGenerator = @import("./terrain_generator.zig").TerrainGenerator;
const GeneratorProperties = @import("./terrain_generator.zig").GeneratorProperties;

pub const SuperflatGenerator = struct {
    allocator: std.mem.Allocator,
    properties: GeneratorProperties,
    bedrock: *BlockPermutation,
    dirt: *BlockPermutation,
    grass: *BlockPermutation,

    pub fn init(allocator: std.mem.Allocator, properties: GeneratorProperties) !*SuperflatGenerator {
        const self = try allocator.create(SuperflatGenerator);
        self.* = SuperflatGenerator{
            .allocator = allocator,
            .properties = properties,
            .bedrock = try BlockPermutation.resolve(allocator, "minecraft:bedrock", null),
            .dirt = try BlockPermutation.resolve(allocator, "minecraft:dirt", null),
            .grass = try BlockPermutation.resolve(allocator, "minecraft:grass_block", null),
        };
        return self;
    }

    pub fn deinit(self: *SuperflatGenerator) void {
        self.allocator.destroy(self);
    }

    pub fn asGenerator(self: *SuperflatGenerator) TerrainGenerator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = TerrainGenerator.VTable{
        .generate = generate,
        .deinit_fn = deinitErased,
        .spawn = spawnPoint,
    };

    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32) anyerror!*Chunk {
        const self: *SuperflatGenerator = @ptrCast(@alignCast(ptr));

        const chunk = try allocator.create(Chunk);
        chunk.* = Chunk.init(allocator, x, z, self.properties.dimension_type);

        var bx: u8 = 0;
        while (bx < 16) : (bx += 1) {
            var bz: u8 = 0;
            while (bz < 16) : (bz += 1) {
                try chunk.setPermutation(@intCast(bx), -64, @intCast(bz), self.bedrock, 0);
                try chunk.setPermutation(@intCast(bx), -63, @intCast(bz), self.dirt, 0);
                try chunk.setPermutation(@intCast(bx), -62, @intCast(bz), self.dirt, 0);
                try chunk.setPermutation(@intCast(bx), -61, @intCast(bz), self.grass, 0);
            }
        }

        chunk.dirty = false;
        return chunk;
    }

    fn spawnPoint(_: *anyopaque) Protocol.BlockPosition {
        return .{
            .x = 0,
            .y = -58,
            .z = 0,
        };
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *SuperflatGenerator = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
