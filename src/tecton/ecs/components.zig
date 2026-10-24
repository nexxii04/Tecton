const std = @import("std");
const Protocol = @import("protocol");
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const EntityActorFlags = @import("../entity/metadata/actor_flags.zig").EntityActorFlags;
const Attributes = @import("../entity/metadata/attributes.zig").Attributes;
const world_mod = @import("world.zig");

pub const Transform = struct {
    position: Protocol.Vector3f = Protocol.Vector3f.init(0, 0, 0),
    rotation: Protocol.Vector2f = Protocol.Vector2f.init(0, 0),
    velocity: Protocol.Vector3f = Protocol.Vector3f.init(0, 0, 0),
    head_yaw: f32 = 0,
    dirty: bool = true,
    moved: bool = false,
};

pub const PhysicsProfile = enum(u8) {
    item = 0,
    mob = 1,
    projectile = 2,

    pub fn index(self: PhysicsProfile) u8 {
        return @intFromEnum(self);
    }
};

pub const Physics = struct {
    profile: PhysicsProfile = .mob,
    on_ground: bool = false,
    falling_distance: f32 = 0,
    fall_ticks: u32 = 0,
};

pub const ProtocolId = struct {
    runtime: i64,
    unique: i64 = 0,
};

pub const TypeRef = struct {
    identifier: []const u8,
    network_id: i32,
};

pub const Health = struct {
    current: f32 = 20,
    max: f32 = 20,
    dead: bool = false,
    invulnerable_until: u64 = 0,
};

pub const ActorFlags = struct {
    flags: EntityActorFlags = EntityActorFlags.init(),
    dirty: bool = false,
};

pub const EntityAttributes = struct {
    attributes: Attributes,

    pub fn ecsDeinit(self: *EntityAttributes, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.attributes.deinit();
    }
};

pub const NameTag = struct {
    text: []const u8 = "",
    owned: bool = false,

    pub fn ecsDeinit(self: *NameTag, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
    }
};

pub const ItemPickup = struct {
    stack: ItemStack,
    pickup_delay: u32 = 0,

    pub fn ecsDeinit(self: *ItemPickup, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.stack.deinit();
    }
};

pub const Lifetime = struct {
    ticks: u32 = 0,
    despawn_at: u32 = std.math.maxInt(u32),
};

pub const LootSource = struct {
    table: u32 = 0,
};

pub const game_components = .{
    Transform,
    Physics,
    ProtocolId,
    TypeRef,
    Health,
    ActorFlags,
    EntityAttributes,
    NameTag,
    ItemPickup,
    Lifetime,
    LootSource,
};

pub const GameWorld = world_mod.World(game_components);

test "hot components stay cache friendly" {
    try std.testing.expect(@sizeOf(Transform) <= 48);
    try std.testing.expect(@sizeOf(Physics) <= 12);
    try std.testing.expect(@sizeOf(ProtocolId) <= 16);
    try std.testing.expect(@sizeOf(Health) <= 24);
    try std.testing.expect(@sizeOf(ActorFlags) <= 32);
    try std.testing.expect(@sizeOf(Lifetime) <= 8);
}

test "destroying an entity releases owned component memory" {
    const allocator = std.testing.allocator;
    const ItemType = @import("../items/item_type.zig").ItemType;
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:ecs_test_stone"),
        5000,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    defer item_type.deinit();

    var world = try GameWorld.init(allocator, 8);
    defer world.deinit();

    const id = try world.create(.item);
    const tag = try allocator.dupe(u8, "minecraft:elder");
    try world.add(id, NameTag{ .text = tag, .owned = true });
    try world.add(id, ItemPickup{ .stack = ItemStack.init(allocator, item_type, .{ .stack_size = 3 }), .pickup_delay = 10 });

    try std.testing.expect(world.destroy(id));
}

test "re-adding an owning component releases the previous value" {
    const allocator = std.testing.allocator;
    var world = try GameWorld.init(allocator, 8);
    defer world.deinit();

    const id = try world.create(.mob);
    const first = try allocator.dupe(u8, "first");
    const second = try allocator.dupe(u8, "second");
    try world.add(id, NameTag{ .text = first, .owned = true });
    try world.add(id, NameTag{ .text = second, .owned = true });
    try std.testing.expectEqualStrings("second", world.get(id, NameTag).?.text);

    world.remove(id, NameTag);
    try std.testing.expect(world.get(id, NameTag) == null);
}
