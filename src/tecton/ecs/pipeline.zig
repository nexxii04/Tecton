const std = @import("std");
const Timestamp = std.Io.Timestamp;

const Tecton = @import("../tecton.zig").Tecton;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const EventsRoot = @import("../events/root.zig");
const entity_id = @import("entity_id.zig");
const components = @import("components.zig");
const query = @import("query.zig");
const resources_mod = @import("resources.zig");

const EntityId = entity_id.EntityId;
const Resources = resources_mod.Resources;
const DimensionEcs = resources_mod.DimensionEcs;
const Lifetime = components.Lifetime;
const ProtocolId = components.ProtocolId;

pub fn lifetimeApply(world: *components.GameWorld, commands: *resources_mod.GameCommands, allocator: std.mem.Allocator) void {
    const Ctx = struct { commands: *resources_mod.GameCommands, allocator: std.mem.Allocator };
    var ctx = Ctx{ .commands = commands, .allocator = allocator };
    query.each(world, .{Lifetime}, &ctx, struct {
        fn call(c: *Ctx, id: EntityId, lifetime: *Lifetime) void {
            lifetime.ticks += 1;
            if (lifetime.ticks >= lifetime.despawn_at) {
                c.commands.despawn(c.allocator, id, .expired) catch {};
            }
        }
    }.call);
}

pub const Stage = struct {
    name: []const u8,
    run: *const fn (*Resources) void,
};

fn damageSystem(res: *Resources) void {
    @import("mobs.zig").damageSystem(res);
}

fn deathSystem(res: *Resources) void {
    @import("mobs.zig").deathSystem(res);
}

fn movementSystem(res: *Resources) void {
    @import("movement.zig").movementApply(&res.ecs.world, res.dimension);
}

fn pickupSystem(res: *Resources) void {
    @import("item_entities.zig").pickupSystem(res);
}

fn mergeSystem(res: *Resources) void {
    @import("item_entities.zig").mergeSystem(res);
}

fn reindexSystem(res: *Resources) void {
    const entity_id_mod = @import("entity_id.zig");
    const dimension_mod = @import("../world/dimension/dimension.zig");
    const Ctx = struct { res: *Resources };
    var ctx = Ctx{ .res = res };
    query.each(&res.ecs.world, .{ components.Transform, ProtocolId }, &ctx, struct {
        fn call(c: *Ctx, id: entity_id_mod.EntityId, transform: *components.Transform, _: *ProtocolId) void {
            const cx = @as(i32, @intFromFloat(@floor(transform.position.x))) >> 4;
            const cz = @as(i32, @intFromFloat(@floor(transform.position.z))) >> 4;
            c.res.ecs.chunk_index.update(id, dimension_mod.chunkHash(cx, cz)) catch {};
        }
    }.call);
}

fn lifetimeSystem(res: *Resources) void {
    lifetimeApply(&res.ecs.world, &res.ecs.commands, res.allocator);
}

pub const simulation_stages = [_]Stage{
    .{ .name = "damage_queue", .run = damageSystem },
    .{ .name = "death", .run = deathSystem },
    .{ .name = "movement", .run = movementSystem },
    .{ .name = "pickup", .run = pickupSystem },
    .{ .name = "merge", .run = mergeSystem },
    .{ .name = "reindex", .run = reindexSystem },
    .{ .name = "lifetime", .run = lifetimeSystem },
};

pub fn flushEcs(state: *DimensionEcs, bus: *EventsRoot.Events, allocator: std.mem.Allocator) void {
    for (state.commands.despawns.items) |command| {
        if (!state.world.isAlive(command.id)) continue;
        const proto = state.world.get(command.id, ProtocolId) orelse continue;
        state.sync.queueRemove(allocator, &state.world, command.id);
        if (bus.hasListeners(.EntityDespawn)) {
            var event = EventsRoot.types.EntityDespawnEvent{
                .id = command.id,
                .runtime_id = proto.runtime,
                .cause = command.cause,
            };
            _ = bus.emit(.EntityDespawn, &event);
        }
        state.runtime_index.unpublish(proto.runtime);
        _ = state.chunk_index.remove(command.id);
    }
    state.commands.flush(&state.world);
}

pub fn runDimension(tecton: *Tecton, dim: *Dimension, tick: u64) void {
    const state = dim.ecs orelse return;
    var res = Resources{
        .allocator = dim.allocator,
        .tecton = tecton,
        .bus = &tecton.events,
        .dimension = dim,
        .ecs = state,
        .tick = tick,
    };

    const start = Timestamp.now(tecton.io, .awake);
    for (simulation_stages) |stage| {
        stage.run(&res);
    }
    state.sync.collectMetadata(dim.allocator, &state.world);
    state.sync.collectMovement(dim.allocator, &state.world, tecton.mob_broadcast_interval);
    flushEcs(state, &tecton.events, dim.allocator);
    const elapsed = start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.ecs_simulation, @intCast(@max(0, elapsed.nanoseconds)));

    const sync_start = Timestamp.now(tecton.io, .awake);
    state.sync.flush(tecton, dim);
    const sync_elapsed = sync_start.durationTo(.now(tecton.io, .awake));
    tecton.profiler.record(.ecs_sync, @intCast(@max(0, sync_elapsed.nanoseconds)));
}

test "lifetime system expires entities through commands" {
    const std_test = std.testing;
    const allocator = std_test.allocator;
    var world = try components.GameWorld.init(allocator, 8);
    defer world.deinit();
    var commands = try resources_mod.GameCommands.init(allocator, 8);
    defer commands.deinit(allocator);

    const short = try world.create(.item);
    try world.add(short, Lifetime{ .despawn_at = 3 });
    const eternal = try world.create(.item);
    try world.add(eternal, Lifetime{});

    for (0..2) |_| lifetimeApply(&world, &commands, allocator);
    try std_test.expectEqual(@as(usize, 0), commands.pendingOperations());

    lifetimeApply(&world, &commands, allocator);
    try std_test.expectEqual(@as(usize, 1), commands.pendingOperations());
    commands.flush(&world);
    try std_test.expect(!world.isAlive(short));
    try std_test.expect(world.isAlive(eternal));
    try std_test.expect(world.get(eternal, Lifetime) != null);
}

test "flush emits despawn events and unpublishes runtime ids" {
    const std_test = std.testing;
    const allocator = std_test.allocator;
    const state = try DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    var bus = EventsRoot.Events.init(allocator);
    defer bus.deinit();

    const seen = struct {
        var runtime: i64 = 0;
        var cause: EventsRoot.types.DespawnCause = .death;
    };

    _ = try bus.subscribe(.EntityDespawn, .post, 0, 1, struct {
        fn call(_: *EventsRoot.EventContext, event: *EventsRoot.types.EntityDespawnEvent) EventsRoot.EventResult {
            seen.runtime = event.runtime_id;
            seen.cause = event.cause;
            return .continue_;
        }
    }.call);

    const id = try state.world.create(.item);
    try state.world.add(id, ProtocolId{ .runtime = 4242, .unique = 4242 });
    try state.runtime_index.publish(allocator, 4242, id);
    try state.commands.despawn(allocator, id, .expired);

    flushEcs(state, &bus, allocator);
    try std_test.expect(!state.world.isAlive(id));
    try std_test.expect(state.runtime_index.resolve(4242) == null);
    try std_test.expectEqual(@as(i64, 4242), seen.runtime);
    try std_test.expectEqual(EventsRoot.types.DespawnCause.expired, seen.cause);
}
