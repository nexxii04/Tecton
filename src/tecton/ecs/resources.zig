const std = @import("std");
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const Tecton = @import("../tecton.zig").Tecton;
const Events = @import("../events/root.zig").Events;
const entity_id_mod = @import("entity_id.zig");
const components = @import("components.zig");
const commands_mod = @import("commands.zig");
const protocol_mod = @import("protocol.zig");

const EntityId = entity_id_mod.EntityId;
const GameWorld = components.GameWorld;
const GameCommands = commands_mod.Commands(components.game_components);
const DropQueue = commands_mod.DropQueue;

pub const DimensionEcs = struct {
    world: GameWorld,
    commands: GameCommands,
    drops: DropQueue,
    runtime_index: protocol_mod.RuntimeIndex,

    pub fn create(allocator: std.mem.Allocator, capacity: usize) !*DimensionEcs {
        const state = try allocator.create(DimensionEcs);
        errdefer allocator.destroy(state);
        state.world = try GameWorld.init(allocator, capacity);
        errdefer state.world.deinit();
        state.commands = try GameCommands.init(allocator, capacity);
        errdefer state.commands.deinit(allocator);
        state.drops = try DropQueue.init(allocator, capacity);
        errdefer state.drops.deinit(allocator);
        state.runtime_index = .{};
        return state;
    }

    pub fn destroy(self: *DimensionEcs, allocator: std.mem.Allocator) void {
        self.drops.deinit(allocator);
        self.commands.deinit(allocator);
        self.world.deinit();
        self.runtime_index.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Resources = struct {
    allocator: std.mem.Allocator,
    tecton: *Tecton,
    bus: *Events,
    dimension: *Dimension,
    ecs: *DimensionEcs,
    tick: u64,

    pub fn runtimeToId(self: *const Resources, runtime: i64) ?EntityId {
        return self.ecs.runtime_index.resolve(runtime);
    }
};

test "dimension ecs bundle owns world commands drops and runtime index" {
    const allocator = std.testing.allocator;
    const state = try DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    const id = try state.world.create(.item);
    try state.commands.addComponent(allocator, id, components.Lifetime{ .despawn_at = 5 });
    try state.runtime_index.publish(allocator, 42, id);

    state.commands.flush(&state.world);
    try std.testing.expect(state.world.get(id, components.Lifetime) != null);
    try std.testing.expectEqual(id, state.runtime_index.resolve(42).?);

    state.runtime_index.unpublish(42);
}
