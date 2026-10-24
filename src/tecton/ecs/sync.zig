const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;

const Tecton = @import("../tecton.zig").Tecton;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const components = @import("components.zig");
const query = @import("query.zig");
const entity_id = @import("entity_id.zig");
const protocol_bridge = @import("protocol.zig");

const EntityId = entity_id.EntityId;
const GameWorld = components.GameWorld;
const Transform = components.Transform;
const Physics = components.Physics;
const ProtocolId = components.ProtocolId;
const ActorFlags = components.ActorFlags;
const NetSync = components.NetSync;

const BuildFn = *const fn (std.mem.Allocator, *GameWorld, EntityId, *BinaryStream) anyerror![]const u8;

pub const Ref = struct {
    runtime: i64,
    unique: i64,
    offset: u32,
    len: u32,
    position: Protocol.Vector3f,
};

pub const ViewerPacket = struct {
    runtime: i64,
    offset: u32,
    len: u32,
};

pub const EntitySync = struct {
    stream: BinaryStream,
    adds: std.ArrayListUnmanaged(Ref) = .empty,
    removes: std.ArrayListUnmanaged(Ref) = .empty,
    moves: std.ArrayListUnmanaged(Ref) = .empty,
    metadata: std.ArrayListUnmanaged(Ref) = .empty,
    viewer_packets: std.ArrayListUnmanaged(ViewerPacket) = .empty,
    overflow: usize = 0,

    pub fn init(allocator: std.mem.Allocator) EntitySync {
        return .{ .stream = BinaryStream.init(allocator, null, null) };
    }

    pub fn deinit(self: *EntitySync, allocator: std.mem.Allocator) void {
        self.stream.deinit();
        self.adds.deinit(allocator);
        self.removes.deinit(allocator);
        self.moves.deinit(allocator);
        self.metadata.deinit(allocator);
        self.viewer_packets.deinit(allocator);
    }

    fn append(
        self: *EntitySync,
        allocator: std.mem.Allocator,
        world: *GameWorld,
        id: EntityId,
        build: BuildFn,
        position: Protocol.Vector3f,
    ) ?Ref {
        const proto = world.get(id, ProtocolId) orelse return null;
        const start = self.stream.written;
        _ = build(allocator, world, id, &self.stream) catch {
            self.stream.written = start;
            self.overflow += 1;
            return null;
        };
        return .{
            .runtime = proto.runtime,
            .unique = proto.unique,
            .offset = @intCast(start),
            .len = @intCast(self.stream.written - start),
            .position = position,
        };
    }

    fn appendRef(self: *EntitySync, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Ref), ref: ?Ref) void {
        const resolved = ref orelse return;
        list.append(allocator, resolved) catch {
            self.stream.written = resolved.offset;
            self.overflow += 1;
        };
    }

    pub fn queueAdd(self: *EntitySync, allocator: std.mem.Allocator, world: *GameWorld, id: EntityId) void {
        const transform = world.get(id, Transform) orelse return;
        self.appendRef(allocator, &self.adds, self.append(allocator, world, id, protocol_bridge.buildAddPacket, transform.position));
    }

    pub fn queueRemove(self: *EntitySync, allocator: std.mem.Allocator, world: *GameWorld, id: EntityId) void {
        self.appendRef(allocator, &self.removes, self.append(allocator, world, id, buildRemove, Protocol.Vector3f.init(0, 0, 0)));
    }

    fn buildRemove(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) anyerror![]const u8 {
        _ = allocator;
        return protocol_bridge.buildRemoveEntity(world, id, stream);
    }

    fn buildMove(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) anyerror![]const u8 {
        _ = allocator;
        const proto = world.get(id, ProtocolId) orelse return error.MissingProtocolId;
        const transform = world.get(id, Transform) orelse return error.MissingTransform;
        const netsync = world.get(id, NetSync) orelse return error.MissingNetSync;
        var on_ground = true;
        if (world.get(id, Physics)) |physics| on_ground = physics.on_ground;

        var packet = Protocol.MoveActorDeltaPacket.init(@bitCast(proto.runtime));
        packet.x = transform.position.x;
        packet.y = transform.position.y;
        packet.z = transform.position.z;
        packet.on_ground = on_ground;
        packet.force_move = !netsync.has_last;
        return packet.serialize(stream);
    }

    fn buildMetadata(allocator: std.mem.Allocator, world: *GameWorld, id: EntityId, stream: *BinaryStream) anyerror![]const u8 {
        const proto = world.get(id, ProtocolId) orelse return error.MissingProtocolId;
        const flags = world.get(id, ActorFlags) orelse return error.MissingActorFlags;
        const data = try flags.flags.buildDataItems(allocator, null);
        defer allocator.free(data);
        var packet = Protocol.SetActorDataPacket.initBorrowed(allocator, proto.runtime, 0, data);
        defer packet.deinit();
        return packet.serialize(stream);
    }

    pub fn queueViewerPacket(
        self: *EntitySync,
        allocator: std.mem.Allocator,
        runtime: i64,
        ctx: anytype,
        comptime build: anytype,
    ) void {
        const start = self.stream.written;
        build(ctx, &self.stream) catch {
            self.stream.written = start;
            self.overflow += 1;
            return;
        };
        self.viewer_packets.append(allocator, .{
            .runtime = runtime,
            .offset = @intCast(start),
            .len = @intCast(self.stream.written - start),
        }) catch {
            self.stream.written = start;
            self.overflow += 1;
        };
    }

    pub fn collectMovement(self: *EntitySync, allocator: std.mem.Allocator, world: *GameWorld, interval_in: u8) void {
        const Ctx = struct {
            sync: *EntitySync,
            world: *GameWorld,
            allocator: std.mem.Allocator,
            interval: u8,
        };
        var ctx = Ctx{ .sync = self, .world = world, .allocator = allocator, .interval = if (interval_in == 0) 1 else interval_in };
        query.each(world, .{ Transform, NetSync, ProtocolId }, &ctx, struct {
            fn call(c: *Ctx, id: EntityId, transform: *Transform, netsync: *NetSync, _: *ProtocolId) void {
                if (!transform.dirty) return;
                transform.dirty = false;
                if (netsync.cooldown > 0) {
                    netsync.cooldown -= 1;
                    return;
                }
                netsync.cooldown = c.interval - 1;
                const ref = c.sync.append(c.allocator, c.world, id, buildMove, transform.position);
                c.sync.appendRef(c.allocator, &c.sync.moves, ref);
                netsync.last_sent = transform.position;
                netsync.has_last = true;
            }
        }.call);
    }

    pub fn collectMetadata(self: *EntitySync, allocator: std.mem.Allocator, world: *GameWorld) void {
        const Ctx = struct {
            sync: *EntitySync,
            world: *GameWorld,
            allocator: std.mem.Allocator,
        };
        var ctx = Ctx{ .sync = self, .world = world, .allocator = allocator };
        query.each(world, .{ ActorFlags, ProtocolId }, &ctx, struct {
            fn call(c: *Ctx, id: EntityId, flags: *ActorFlags, _: *ProtocolId) void {
                if (!flags.dirty) return;
                flags.dirty = false;
                const position = if (c.world.get(id, Transform)) |t| t.position else Protocol.Vector3f.init(0, 0, 0);
                const ref = c.sync.append(c.allocator, c.world, id, buildMetadata, position);
                c.sync.appendRef(c.allocator, &c.sync.metadata, ref);
            }
        }.call);
    }

    pub fn payloadSlice(self: *const EntitySync, ref: Ref) []const u8 {
        return self.stream.payload[ref.offset .. ref.offset + ref.len];
    }

    pub fn reset(self: *EntitySync) void {
        self.stream.reset();
        self.adds.clearRetainingCapacity();
        self.removes.clearRetainingCapacity();
        self.moves.clearRetainingCapacity();
        self.metadata.clearRetainingCapacity();
        self.viewer_packets.clearRetainingCapacity();
    }

    pub fn flush(self: *EntitySync, tecton: *Tecton, dimension: *Dimension) void {
        const snapshots = tecton.getPlayerSnapshots();
        for (snapshots) |player| {
            if (!player.spawned) continue;
            if (player.entity.dimension != dimension) continue;

            for (self.removes.items) |ref| {
                if (player.visible_entities.fetchRemove(ref.runtime) == null) continue;
                tecton.network.sendPacket(player.connection, self.payloadSlice(ref)) catch {};
            }

            for (self.adds.items) |ref| {
                if (player.visible_entities.contains(ref.runtime)) continue;
                const dx = player.entity.position.x - ref.position.x;
                const dz = player.entity.position.z - ref.position.z;
                if (!Dimension.withinViewDistance(dx, dz, player.view_distance)) continue;
                tecton.network.sendPacket(player.connection, self.payloadSlice(ref)) catch continue;
                player.visible_entities.put(ref.runtime, ref.unique) catch {};
            }

            for (self.moves.items) |ref| {
                if (!player.visible_entities.contains(ref.runtime)) continue;
                tecton.network.sendPacket(player.connection, self.payloadSlice(ref)) catch {};
            }

            for (self.metadata.items) |ref| {
                if (!player.visible_entities.contains(ref.runtime)) continue;
                tecton.network.sendPacket(player.connection, self.payloadSlice(ref)) catch {};
            }

            for (self.viewer_packets.items) |packet| {
                if (!player.visible_entities.contains(packet.runtime)) continue;
                const bytes = self.stream.payload[packet.offset .. packet.offset + packet.len];
                tecton.network.sendPacket(player.connection, bytes) catch {};
            }
        }
        self.reset();
    }
};

test "entity sync queues movement and metadata once and resets" {
    const allocator = std.testing.allocator;
    const resources_mod = @import("resources.zig");
    const state = try resources_mod.DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    const id = try state.world.create(.item);
    try state.world.add(id, ProtocolId{ .runtime = 500, .unique = 500 });
    try state.world.add(id, components.TypeRef{ .identifier = "minecraft:item", .network_id = 64 });
    try state.world.add(id, Transform{ .position = Protocol.Vector3f.init(1, 64, 2), .velocity = Protocol.Vector3f.init(0.3, 0, 0), .dirty = true });
    try state.world.add(id, NetSync{});
    try state.world.add(id, ActorFlags{ .dirty = true });

    state.sync.queueAdd(allocator, &state.world, id);
    try std.testing.expectEqual(@as(usize, 1), state.sync.adds.items.len);
    try std.testing.expect(state.sync.payloadSlice(state.sync.adds.items[0]).len > 0);

    state.sync.collectMetadata(allocator, &state.world);
    state.sync.collectMovement(allocator, &state.world, 2);
    try std.testing.expectEqual(@as(usize, 1), state.sync.moves.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.sync.metadata.items.len);
    try std.testing.expect(!state.world.get(id, Transform).?.dirty);
    try std.testing.expect(!state.world.get(id, ActorFlags).?.dirty);
    try std.testing.expect(state.world.get(id, NetSync).?.has_last);
    try std.testing.expect(state.sync.payloadSlice(state.sync.moves.items[0]).len > 0);

    state.sync.queueRemove(allocator, &state.world, id);
    try std.testing.expectEqual(@as(usize, 1), state.sync.removes.items.len);
    state.sync.reset();
    try std.testing.expectEqual(@as(usize, 0), state.sync.adds.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.sync.removes.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.sync.moves.items.len);
}

test "cooldown suppresses intermediate broadcasts and fires on interval" {
    const allocator = std.testing.allocator;
    const resources_mod = @import("resources.zig");
    const state = try resources_mod.DimensionEcs.create(allocator, 8);
    defer state.destroy(allocator);

    const id = try state.world.create(.item);
    try state.world.add(id, ProtocolId{ .runtime = 501, .unique = 501 });
    try state.world.add(id, Transform{ .dirty = true });
    try state.world.add(id, NetSync{});

    state.sync.collectMovement(allocator, &state.world, 3);
    try std.testing.expectEqual(@as(usize, 1), state.sync.moves.items.len);
    state.sync.moves.clearRetainingCapacity();

    state.world.get(id, Transform).?.dirty = true;
    state.sync.collectMovement(allocator, &state.world, 3);
    try std.testing.expectEqual(@as(usize, 0), state.sync.moves.items.len);

    state.world.get(id, Transform).?.dirty = true;
    state.sync.collectMovement(allocator, &state.world, 3);
    state.world.get(id, Transform).?.dirty = true;
    state.sync.collectMovement(allocator, &state.world, 3);
    try std.testing.expectEqual(@as(usize, 1), state.sync.moves.items.len);
    state.sync.reset();
}
