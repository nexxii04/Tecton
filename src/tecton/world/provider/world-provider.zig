const std = @import("std");
const Chunk = @import("../chunk/chunk.zig").Chunk;
const chunk_mod = @import("../chunk/chunk.zig");
const Dimension = @import("../dimension/dimension.zig").Dimension;
const ChunkHash = @import("../dimension/dimension.zig").ChunkHash;
const Player = @import("../../player/player.zig").Player;

pub const ChunkColumnData = struct {
    has_version: bool = false,
    subchunks: [chunk_mod.MAX_SUBCHUNKS]?[]const u8 = .{null} ** chunk_mod.MAX_SUBCHUNKS,
    block_entity_data: ?[]const u8 = null,

    pub fn deinit(self: *ChunkColumnData, allocator: std.mem.Allocator) void {
        for (&self.subchunks) |*sc| {
            if (sc.*) |data| {
                allocator.free(data);
                sc.* = null;
            }
        }
        if (self.block_entity_data) |d| allocator.free(d);
    }
};

pub const WorldProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_chunk: *const fn (ptr: *anyopaque, x: i32, z: i32, dimension: *Dimension) anyerror!*Chunk,
        read_chunk_direct: ?*const fn (ptr: *anyopaque, x: i32, z: i32, dim_type: @import("protocol").DimensionType) anyerror!*Chunk,
        read_chunk_column: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType, read_block_entities: bool) anyerror!ChunkColumnData,
        read_chunk_block_entity_data: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType) anyerror!?[]const u8,
        write_chunk: *const fn (ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void,
        uncache_chunk: ?*const fn (ptr: *anyopaque, x: i32, z: i32, dimension: *Dimension) void,
        read_buffer: *const fn (ptr: *anyopaque, key: []const u8) anyerror!?[]const u8,
        write_buffer: *const fn (ptr: *anyopaque, key: []const u8, buffer: []const u8) anyerror!void,
        write_player: ?*const fn (ptr: *anyopaque, uuid: []const u8, player: *Player) anyerror!void,
        read_player: ?*const fn (ptr: *anyopaque, uuid: []const u8, player: *Player) anyerror!bool,
        write_chunk_entities: ?*const fn (ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void,
        write_block_entities: ?*const fn (ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void,
        read_block_entities: ?*const fn (ptr: *anyopaque, chunk: *Chunk, dimension: *Dimension) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };

    pub fn readChunk(self: WorldProvider, x: i32, z: i32, dimension: *Dimension) !*Chunk {
        return self.vtable.read_chunk(self.ptr, x, z, dimension);
    }

    pub fn readChunkDirect(self: WorldProvider, x: i32, z: i32, dim_type: @import("protocol").DimensionType) !*Chunk {
        if (self.vtable.read_chunk_direct) |f| return f(self.ptr, x, z, dim_type);
        return error.NotSupported;
    }

    /// Allocated with `allocator`; release with `ChunkColumnData.deinit(allocator)`.
    pub fn readChunkColumn(self: WorldProvider, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType, read_block_entities: bool) !ChunkColumnData {
        if (self.vtable.read_chunk_column) |f| return f(self.ptr, allocator, x, z, dim_type, read_block_entities);
        return error.NotSupported;
    }

    /// Allocated with `allocator`, owned by the caller.
    pub fn readChunkBlockEntityData(self: WorldProvider, allocator: std.mem.Allocator, x: i32, z: i32, dim_type: @import("protocol").DimensionType) !?[]const u8 {
        if (self.vtable.read_chunk_block_entity_data) |f| return f(self.ptr, allocator, x, z, dim_type);
        return null;
    }

    pub fn writeChunk(self: WorldProvider, chunk: *Chunk, dimension: *Dimension) !void {
        return self.vtable.write_chunk(self.ptr, chunk, dimension);
    }

    pub fn uncacheChunk(self: WorldProvider, x: i32, z: i32, dimension: *Dimension) void {
        if (self.vtable.uncache_chunk) |f| f(self.ptr, x, z, dimension);
    }

    pub fn readBuffer(self: WorldProvider, key: []const u8) !?[]const u8 {
        return self.vtable.read_buffer(self.ptr, key);
    }

    pub fn writeBuffer(self: WorldProvider, key: []const u8, buffer: []const u8) !void {
        return self.vtable.write_buffer(self.ptr, key, buffer);
    }

    pub fn writePlayer(self: WorldProvider, uuid: []const u8, player: *Player) !void {
        if (self.vtable.write_player) |f| return f(self.ptr, uuid, player);
    }

    pub fn readPlayer(self: WorldProvider, uuid: []const u8, player: *Player) !bool {
        if (self.vtable.read_player) |f| return f(self.ptr, uuid, player);
        return false;
    }

    pub fn writeChunkEntities(self: WorldProvider, chunk: *Chunk, dimension: *Dimension) !void {
        if (self.vtable.write_chunk_entities) |f| return f(self.ptr, chunk, dimension);
    }

    pub fn writeBlockEntities(self: WorldProvider, chunk: *Chunk, dimension: *Dimension) !void {
        if (self.vtable.write_block_entities) |f| return f(self.ptr, chunk, dimension);
    }

    pub fn readBlockEntities(self: WorldProvider, chunk: *Chunk, dimension: *Dimension) !void {
        if (self.vtable.read_block_entities) |f| return f(self.ptr, chunk, dimension);
    }

    pub fn deinit(self: WorldProvider) void {
        self.vtable.deinit_fn(self.ptr);
    }
};
