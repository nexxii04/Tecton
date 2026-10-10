const std = @import("std");
const Raknet = @import("Raknet");
const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const Protocol = @import("protocol");

const Host = @import("../player/player.zig").Host;
const World = @import("../world/world.zig").World;
const Generator = @import("../world/generator/root.zig");
const LevelDBProvider = @import("../world/provider/leveldb_provider.zig").LevelDBProvider;

pub const WorldRegistry = struct {
    allocator: std.mem.Allocator,
    by_name: std.StringHashMap(*World),
    ops: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) WorldRegistry {
        return .{
            .allocator = allocator,
            .by_name = std.StringHashMap(*World).init(allocator),
            .ops = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn get(self: *const WorldRegistry, name: []const u8) ?*World {
        return self.by_name.get(name);
    }

    pub fn has(self: *const WorldRegistry, name: []const u8) bool {
        return self.by_name.contains(name);
    }

    pub fn count(self: *const WorldRegistry) usize {
        return self.by_name.count();
    }

    pub fn keyIterator(self: *const WorldRegistry) std.StringHashMap(*World).KeyIterator {
        return self.by_name.keyIterator();
    }

    pub fn valueIterator(self: *const WorldRegistry) std.StringHashMap(*World).ValueIterator {
        return self.by_name.valueIterator();
    }

    pub fn opInFlight(self: *const WorldRegistry, name: []const u8) bool {
        return self.ops.contains(name);
    }

    pub fn beginOp(self: *WorldRegistry, owned_name: []u8) bool {
        self.ops.put(owned_name, {}) catch return false;
        return true;
    }

    pub fn endOp(self: *WorldRegistry, name: []const u8) void {
        _ = self.ops.remove(name);
    }

    pub fn adopt(self: *WorldRegistry, world: *World) !void {
        try self.by_name.put(world.identifier, world);
    }

    pub fn detach(self: *WorldRegistry, world: *World) void {
        _ = self.by_name.remove(world.identifier);
    }

    pub fn destroy(self: *WorldRegistry, world: *World) void {
        self.detach(world);
        world.deinit();
        self.allocator.destroy(world);
    }

    pub fn deinit(self: *WorldRegistry) void {
        var worlds_it = self.by_name.valueIterator();
        while (worlds_it.next()) |world| {
            world.*.deinit();
            self.allocator.destroy(world.*);
        }
        self.by_name.deinit();
    }

    pub fn deinitOps(self: *WorldRegistry) void {
        self.ops.deinit();
    }
};

pub fn build(tecton: Host, worlds_dir: []const u8, name: []const u8) !*World {
    var path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}/db", .{ worlds_dir, name });
    std.Io.Dir.cwd().createDirPath(tecton.io, db_path) catch {};

    const provider = try LevelDBProvider.init(tecton.io, tecton.allocator, db_path);
    const world = tecton.allocator.create(World) catch |err| {
        provider.deinit();
        return err;
    };

    world.* = World.init(tecton, tecton.allocator, name, provider.asProvider()) catch |err| {
        tecton.allocator.destroy(world);
        provider.deinit();
        return err;
    };
    errdefer {
        world.deinit();
        tecton.allocator.destroy(world);
    }
    try createDimensions(tecton, worlds_dir, world);
    return world;
}

pub fn load(tecton: Host, worlds_dir: []const u8, name: []const u8) !*World {
    const world = try build(tecton, worlds_dir, name);
    errdefer tecton.worlds.destroy(world);
    try tecton.worlds.adopt(world);
    return world;
}

fn createDimensions(tecton: Host, worlds_dir: []const u8, world: *World) !void {
    try createDimension(tecton, world, "overworld", .Overworld, true);
    try createDimension(tecton, world, "nether", .Nether, false);
    try createDimension(tecton, world, "end", .End, false);

    var level_dat_buf: [512]u8 = undefined;
    const level_dat_path = std.fmt.bufPrint(&level_dat_buf, "{s}/{s}/level.dat", .{ worlds_dir, world.identifier }) catch return;
    if (readLevelDatSpawn(tecton.io, tecton.allocator, level_dat_path)) |spawn| {
        if (world.getDimension("overworld")) |dim| {
            dim.spawn_position = spawn;
            Raknet.Logger.INFO("World '{s}' spawn: {d}, {d}, {d}", .{ world.identifier, spawn.x, spawn.y, spawn.z });
        }
    } else |_| {}
}

fn createDimension(
    tecton: Host,
    world: *World,
    identifier: []const u8,
    dimension_type: Protocol.DimensionType,
    load_spawn_chunks: bool,
) !void {
    const props = Generator.GeneratorProperties.init(tecton.io, null, dimension_type);
    const superflat = try Generator.SuperflatGenerator.init(tecton.allocator, props);
    const threaded = Generator.ThreadedGenerator.init(tecton.io, tecton.allocator, superflat.asGenerator()) catch |err| {
        superflat.deinit();
        return err;
    };
    const dim = try world.createDimension(identifier, dimension_type, threaded, load_spawn_chunks);
    dim.simulation_distance = @intCast(tecton.config.simulation_distance);
}

fn readLevelDatSpawn(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Protocol.BlockPosition {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const data = try reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(data);
    if (data.len < 8) return error.InvalidLevelDat;

    var stream = BinaryStream.init(allocator, data[8..], null);
    defer stream.deinit();
    var root = try NBT.CompoundTag.read(&stream, allocator, NBT.ReadWriteOptions.default);
    defer root.deinit(allocator);

    const sx = switch (root.get("SpawnX") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };
    const sy = switch (root.get("SpawnY") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };
    const sz = switch (root.get("SpawnZ") orelse return error.NoSpawn) {
        .Int => |t| t.value,
        else => return error.NoSpawn,
    };

    return Protocol.BlockPosition{ .x = sx, .y = sy, .z = sz };
}

test "a name is reserved while its operation runs, and freed after" {
    var registry = WorldRegistry.init(std.testing.allocator);
    defer registry.deinit();
    defer registry.deinitOps();

    var name = [_]u8{ 'w', 'o', 'r', 'l', 'd' };
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(!registry.opInFlight(&name));
    try std.testing.expect(registry.beginOp(&name));
    try std.testing.expect(registry.opInFlight(&name));
    try std.testing.expect(!registry.has(&name));

    registry.endOp(&name);
    try std.testing.expect(!registry.opInFlight(&name));
}
