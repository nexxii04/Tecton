const std = @import("std");
const World = @import("world.zig").World;
const Dimension = @import("dimension/dimension.zig").Dimension;
const api = @import("../plugins/api.zig");

pub const InstanceId = u32;

pub const GameInstance = struct {
    allocator: std.mem.Allocator,
    id: InstanceId,
    name: []const u8,
    world: *World,
    dimension: *Dimension,
    members: std.AutoHashMap(i64, void),
    generation: u64 = 1,
    accepting_players: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        id: InstanceId,
        name: []const u8,
        world: *World,
        dimension: *Dimension,
    ) !GameInstance {
        return .{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
            .world = world,
            .dimension = dimension,
            .members = std.AutoHashMap(i64, void).init(allocator),
        };
    }

    pub fn deinit(self: *GameInstance) void {
        self.members.deinit();
        self.allocator.free(self.name);
    }

    pub fn handle(self: *const GameInstance) api.Handle {
        return .{ .index = self.id, .generation = @intCast(self.generation), .kind = .instance };
    }

    pub fn addPlayer(self: *GameInstance, runtime_id: i64) !void {
        if (!self.accepting_players) return error.InstanceUnavailable;
        try self.members.put(runtime_id, {});
    }

    pub fn removePlayer(self: *GameInstance, runtime_id: i64) void {
        _ = self.members.remove(runtime_id);
    }

    pub fn contains(self: *const GameInstance, runtime_id: i64) bool {
        return self.members.contains(runtime_id);
    }
};

pub const GameInstanceRegistry = struct {
    allocator: std.mem.Allocator,
    instances: std.AutoHashMap(InstanceId, *GameInstance),
    player_instances: std.AutoHashMap(i64, InstanceId),
    next_id: InstanceId = 1,

    pub fn init(allocator: std.mem.Allocator) GameInstanceRegistry {
        return .{
            .allocator = allocator,
            .instances = std.AutoHashMap(InstanceId, *GameInstance).init(allocator),
            .player_instances = std.AutoHashMap(i64, InstanceId).init(allocator),
        };
    }

    pub fn deinit(self: *GameInstanceRegistry) void {
        var iterator = self.instances.valueIterator();
        while (iterator.next()) |instance| {
            instance.*.deinit();
            self.allocator.destroy(instance.*);
        }
        self.instances.deinit();
        self.player_instances.deinit();
    }

    pub fn create(self: *GameInstanceRegistry, name: []const u8, world: *World, dimension: *Dimension) !*GameInstance {
        const instance = try self.allocator.create(GameInstance);
        errdefer self.allocator.destroy(instance);
        instance.* = try GameInstance.init(self.allocator, self.next_id, name, world, dimension);
        dimension.instance_id = self.next_id;
        errdefer instance.deinit();
        try self.instances.put(self.next_id, instance);
        self.next_id += 1;
        return instance;
    }

    pub fn destroy(self: *GameInstanceRegistry, id: InstanceId) error{InstanceBusy, InstanceNotFound}!void {
        const instance = self.instances.get(id) orelse return error.InstanceNotFound;
        if (instance.members.count() != 0) return error.InstanceBusy;
        _ = self.instances.remove(id);
        instance.deinit();
        self.allocator.destroy(instance);
    }

    pub fn get(self: *GameInstanceRegistry, id: InstanceId) ?*GameInstance {
        return self.instances.get(id);
    }

    pub fn join(self: *GameInstanceRegistry, runtime_id: i64, id: InstanceId) !void {
        if (self.player_instances.contains(runtime_id)) return error.PlayerAlreadyAssigned;
        const instance = self.instances.get(id) orelse return error.InstanceNotFound;
        try instance.addPlayer(runtime_id);
        self.player_instances.put(runtime_id, id) catch |err| {
            instance.removePlayer(runtime_id);
            return err;
        };
    }

    pub fn leave(self: *GameInstanceRegistry, runtime_id: i64) void {
        if (self.player_instances.fetchRemove(runtime_id)) |entry| {
            if (self.instances.get(entry.value)) |instance| instance.removePlayer(runtime_id);
        }
    }

    pub fn instanceOf(self: *const GameInstanceRegistry, runtime_id: i64) ?*GameInstance {
        const id = self.player_instances.get(runtime_id) orelse return null;
        return self.instances.get(id);
    }

    pub fn assignDimension(self: *GameInstanceRegistry, runtime_id: i64, dimension: *Dimension) !void {
        if (self.instanceOf(runtime_id)) |current| {
            if (current.dimension == dimension) return;
            self.leave(runtime_id);
        }
        var iterator = self.instances.valueIterator();
        while (iterator.next()) |instance| {
            if (instance.*.dimension == dimension) {
                try self.join(runtime_id, instance.*.id);
                return;
            }
        }
        return error.InstanceNotFound;
    }
};
