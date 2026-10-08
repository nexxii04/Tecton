const std = @import("std");
const Chunk = @import("../chunk/chunk.zig").Chunk;
const Protocol = @import("protocol");

pub const GeneratorProperties = struct {
    seed: u64,
    dimension_type: Protocol.DimensionType,

    pub fn init(io: std.Io, seed: ?u64, dimension_type: Protocol.DimensionType) GeneratorProperties {
        return .{
            .seed = seed orelse @as(u64, @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .real).nanoseconds)))),
            .dimension_type = dimension_type,
        };
    }
};

pub const TerrainGenerator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        generate: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32) anyerror!*Chunk,
        spawn: *const fn (ptr: *anyopaque) Protocol.BlockPosition,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn generate(self: TerrainGenerator, allocator: std.mem.Allocator, x: i32, z: i32) !*Chunk {
        return self.vtable.generate(self.ptr, allocator, x, z);
    }

    pub fn spawnPoint(self: TerrainGenerator) Protocol.BlockPosition {
        return self.vtable.spawn(self.ptr);
    }

    pub fn deinit(self: TerrainGenerator) void {
        self.vtable.deinit_fn(self.ptr);
    }
};
