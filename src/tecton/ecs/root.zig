pub const entity_id = @import("entity_id.zig");
pub const Kind = entity_id.Kind;
pub const EntityId = entity_id.EntityId;
pub const store = @import("store.zig");
pub const DenseStore = store.DenseStore;
pub const world = @import("world.zig");
pub const World = world.World;
pub const WorldError = world.WorldError;
pub const components = @import("components.zig");
pub const GameWorld = components.GameWorld;
pub const query = @import("query.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
