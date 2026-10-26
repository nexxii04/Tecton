const std = @import("std");
const Protocol = @import("protocol");

const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const resources_mod = @import("resources.zig");
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const query = @import("query.zig");
const mobs = @import("mobs.zig");

const EntityId = entity_id.EntityId;
const Transform = components.Transform;
const Health = components.Health;
const ProtocolId = components.ProtocolId;
const ActorFlags = components.ActorFlags;
const Fire = components.Fire;

pub const FIRE_DAMAGE_INTERVAL_TICKS: i32 = 20;
pub const FIRE_DAMAGE_PER_HIT: f32 = 1.0;
pub const FIRE_BLOCK_IGNITION_TICKS: i32 = 150;
pub const LAVA_IGNITION_TICKS: i32 = 300;

const Contact = struct {
    doused: bool = false,
    ignition_ticks: i32 = 0,
};

fn identifierAt(dimension: *Dimension, x: i32, y: i32, z: i32) ?[]const u8 {
    const perm = dimension.getPermutation(.{ .x = x, .y = y, .z = z }, 0) catch return null;
    return perm.identifier;
}

pub fn contactOf(dimension: *Dimension, transform: *const Transform) Contact {
    var contact = Contact{};
    const bx: i32 = @intFromFloat(@floor(transform.position.x));
    const by: i32 = @intFromFloat(@floor(transform.position.y));
    const bz: i32 = @intFromFloat(@floor(transform.position.z));
    if (dimension.getChunk(bx >> 4, bz >> 4) == null) return contact;

    for ([_]i32{ by, by + 1 }) |y| {
        const identifier = identifierAt(dimension, bx, y, bz) orelse continue;
        if (std.mem.eql(u8, identifier, "minecraft:water") or std.mem.eql(u8, identifier, "minecraft:flowing_water")) {
            contact.doused = true;
        }
        if (std.mem.eql(u8, identifier, "minecraft:lava") or std.mem.eql(u8, identifier, "minecraft:flowing_lava")) {
            contact.ignition_ticks = LAVA_IGNITION_TICKS;
        }
        if (std.mem.eql(u8, identifier, "minecraft:fire") or std.mem.eql(u8, identifier, "minecraft:soul_fire")) {
            if (contact.ignition_ticks == 0) contact.ignition_ticks = FIRE_BLOCK_IGNITION_TICKS;
        }
    }
    return contact;
}

fn setOnFireFlag(world: *components.GameWorld, id: EntityId, burning: bool) void {
    const flags = world.get(id, ActorFlags) orelse return;
    if (flags.flags.getFlag(.OnFire) == burning) return;
    flags.flags.setFlag(.OnFire, burning);
    flags.dirty = true;
}

const FireCtx = struct {
    state: *resources_mod.DimensionEcs,
    dimension: *Dimension,
    allocator: std.mem.Allocator,
};

pub fn fireApply(state: *resources_mod.DimensionEcs, dimension: *Dimension) void {
    var ctx = FireCtx{ .state = state, .dimension = dimension, .allocator = dimension.allocator };
    query.eachKind(&state.world, .mob, .{ Transform, Fire, ProtocolId }, &ctx, struct {
        fn call(c: *FireCtx, id: EntityId, transform: *Transform, fire: *Fire, _: *ProtocolId) void {
            const contact = contactOf(c.dimension, transform);

            if (contact.doused) {
                if (fire.ticks > 0) {
                    fire.ticks = 0;
                    fire.damage_timer = 0;
                    setOnFireFlag(&c.state.world, id, false);
                }
                return;
            }

            if (fire.ticks <= 0) {
                if (contact.ignition_ticks > 0 and c.state.world.get(id, Health) != null) {
                    fire.ticks = contact.ignition_ticks;
                    fire.damage_timer = 0;
                    setOnFireFlag(&c.state.world, id, true);
                }
                return;
            }

            if (c.dimension.world.weather != .clear) {
                fire.ticks = 0;
                fire.damage_timer = 0;
                setOnFireFlag(&c.state.world, id, false);
                return;
            }

            fire.ticks -= 1;
            if (fire.ticks <= 0) {
                fire.damage_timer = 0;
                setOnFireFlag(&c.state.world, id, false);
                return;
            }

            fire.damage_timer += 1;
            if (fire.damage_timer >= FIRE_DAMAGE_INTERVAL_TICKS) {
                fire.damage_timer = 0;
                c.state.damage_queue.append(c.allocator, .{
                    .target = id,
                    .amount = FIRE_DAMAGE_PER_HIT,
                    .cause = .fire_tick,
                    .source_runtime = null,
                }) catch {
                    c.state.damage_overflow += 1;
                };
            }
        }
    }.call);
}

test "burning mobs take fire damage once per second and stop at zero" {
    const allocator = std.testing.allocator;
    const World = @import("../world/world.zig").World;
    const state = try resources_mod.DimensionEcs.create(allocator, 8);

    var world = try World.init(undefined, allocator, "fire-test", null);
    defer world.deinit();
    var dim = Dimension.init(&world, allocator, "test", .Overworld, null);
    defer dim.deinit();
    dim.ecs = state;

    const id = try state.world.create(.mob);
    try state.world.add(id, ProtocolId{ .runtime = 800, .unique = 800 });
    try state.world.add(id, Transform{ .position = Protocol.Vector3f.init(0, 100, 0) });
    try state.world.add(id, Fire{ .ticks = 40 });
    try state.world.add(id, Health{ .current = 20, .max = 20 });

    for (0..19) |_| fireApply(state, &dim);
    try std.testing.expectEqual(@as(usize, 0), state.damage_queue.items.len);

    fireApply(state, &dim);
    try std.testing.expectEqual(@as(usize, 1), state.damage_queue.items.len);
    try std.testing.expectEqual(@as(f32, 1.0), state.damage_queue.items[0].amount);
    try std.testing.expectEqual(@import("../events/types.zig").DamageCause.fire_tick, state.damage_queue.items[0].cause);
    state.damage_queue.clearRetainingCapacity();

    for (0..21) |_| fireApply(state, &dim);
    try std.testing.expectEqual(@as(i32, 0), state.world.get(id, Fire).?.ticks);
    try std.testing.expectEqual(@as(usize, 0), state.damage_queue.items.len);
}
