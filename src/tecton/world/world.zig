const std = @import("std");
const Protocol = @import("protocol");
const Host = @import("../player/player.zig").Host;
const Dimension = @import("./dimension/dimension.zig").Dimension;
const WorldProvider = @import("./provider/world_provider.zig").WorldProvider;
const InternalProvider = @import("./provider/internal_provider.zig").InternalProvider;
const ThreadedGenerator = @import("./generator/threaded_generator.zig").ThreadedGenerator;
const FloatingTextManager = @import("../entity/floating_text.zig").FloatingTextManager;

pub const Weather = enum { clear, rain, thunder };

pub const World = struct {
    tecton: Host,
    allocator: std.mem.Allocator,
    identifier: []const u8,
    dimensions: std.StringHashMap(*Dimension),
    provider: WorldProvider,

    unloading: bool = false,
    weather: Weather = .clear,

    pub fn init(
        tecton: Host,
        allocator: std.mem.Allocator,
        identifier: []const u8,
        provider: ?WorldProvider,
    ) !World {
        const prov = provider orelse blk: {
            const internal = try InternalProvider.init(allocator);
            break :blk internal.asProvider();
        };

        return World{
            .tecton = tecton,
            .allocator = allocator,
            .identifier = try allocator.dupe(u8, identifier),
            .dimensions = std.StringHashMap(*Dimension).init(allocator),
            .provider = prov,
        };
    }

    pub fn createDimension(
        self: *World,
        identifier: []const u8,
        dimension_type: Protocol.DimensionType,
        generator: ?*ThreadedGenerator,
        load_spawn_chunks: bool,
    ) !*Dimension {
        if (self.dimensions.get(identifier)) |existing| return existing;

        const dim = try self.allocator.create(Dimension);
        dim.* = Dimension.init(self, self.allocator, identifier, dimension_type, generator);
        errdefer {
            dim.deinit();
            self.allocator.destroy(dim);
        }
        dim.floating_texts = try FloatingTextManager.create(self.allocator, dim);
        if (load_spawn_chunks) try dim.loadSpawnChunks();
        try self.dimensions.put(identifier, dim);
        return dim;
    }

    pub fn getDimension(self: *World, identifier: []const u8) ?*Dimension {
        return self.dimensions.get(identifier);
    }

    pub fn hasInflightBatches(self: *const World) bool {
        var iter = self.dimensions.valueIterator();
        while (iter.next()) |dim| {
            if (dim.*.inflight_batches > 0) return true;
        }
        return false;
    }

    pub fn save(self: *World) void {
        var dims_iter = self.dimensions.valueIterator();
        while (dims_iter.next()) |dim| {
            var chunk_iter = dim.*.chunks.valueIterator();
            while (chunk_iter.next()) |chunk| {
                self.provider.writeChunkEntities(chunk.*, dim.*) catch {};
                self.provider.writeBlockEntities(chunk.*, dim.*) catch {};
                if (chunk.*.dirty) {
                    self.provider.writeChunk(chunk.*, dim.*) catch continue;
                }
            }
        }
    }

    pub fn deinit(self: *World) void {
        var iter = self.dimensions.valueIterator();
        while (iter.next()) |dim| {
            dim.*.deinit();
            self.allocator.destroy(dim.*);
        }
        self.dimensions.deinit();
        self.provider.deinit();
        self.allocator.free(self.identifier);
    }
};
