const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const LoginData = Protocol.Login.Decoder.LoginData;
const Raknet = @import("Raknet");

const Container = @import("../container/container.zig").Container;
const EntityType = @import("../entity/entity_type.zig").EntityType;
const Entity = @import("../entity/entity.zig").Entity;
const ChunkLoadingTrait = @import("../entity/traits/chunk_loading.zig");
const ChunkStreaming = @import("../entity/traits/chunk_streaming.zig");
const Visibility = @import("../entity/traits/visibility.zig");
const CreatedOutputTrait = @import("../entity/traits/created_output.zig").CreatedOutputTrait;
const CursorTrait = @import("../entity/traits/cursor.zig").CursorTrait;
const Fire = @import("../entity/traits/fire.zig");
const Health = @import("../entity/traits/health.zig");
const InventoryTrait = @import("../entity/traits/inventory.zig").InventoryTrait;
const StatsTrait = @import("../entity/traits/stats.zig").StatsTrait;
const TradeWindowTrait = @import("../entity/traits/trade_window.zig").TradeWindowTrait;
pub const NetworkHandler = @import("../transport/network_handler.zig").NetworkHandler;
const contracts = @import("../core/contracts.zig");
const EcsWorld = @import("../entity/ecs.zig").EcsWorld;
const events_mod = @import("../events/root.zig");
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const World = @import("../world/world.zig").World;

pub const Host = contracts.ServerHost(Player, Entity, events_mod.Events, Dimension, World, EcsWorld, NetworkHandler);
const MoveDelta = @import("move_delta.zig");
const Pose = @import("pose.zig").Pose;
const SharedBroadcast = @import("../transport/shared_broadcast.zig").SharedBroadcast;

pub const PLAYER_EYE_HEIGHT: f32 = 1.62;
pub const DROP_HEIGHT_ABOVE_FEET: f32 = 1.3;
pub const DROP_FORWARD_SPEED: f32 = 0.4;

pub fn internalToWorldFeetPosition(pos: Protocol.Vector3f) Protocol.Vector3f {
    return Protocol.Vector3f.init(pos.x, pos.y - PLAYER_EYE_HEIGHT, pos.z);
}

pub fn worldFeetToInternalPosition(pos: Protocol.Vector3f) Protocol.Vector3f {
    return Protocol.Vector3f.init(pos.x, pos.y + PLAYER_EYE_HEIGHT, pos.z);
}

pub fn playerDropSpawnPosition(pos: Protocol.Vector3f) Protocol.Vector3f {
    const feet = internalToWorldFeetPosition(pos);
    return Protocol.Vector3f.init(feet.x, feet.y + DROP_HEIGHT_ABOVE_FEET, feet.z);
}

pub fn damageable(gamemode: Protocol.GameMode) bool {
    return switch (gamemode) {
        .Creative, .Spectator, .CreativeSpectator, .SurvivalSpectator => false,
        else => true,
    };
}

pub const MAX_ATTACK_REACH: f32 = 8.0;

pub fn withinAttackReach(attacker: Protocol.Vector3f, target: Protocol.Vector3f) bool {
    const dx = target.x - attacker.x;
    const dy = target.y - attacker.y;
    const dz = target.z - attacker.z;
    return dx * dx + dy * dy + dz * dz <= MAX_ATTACK_REACH * MAX_ATTACK_REACH;
}

pub const FALL_DAMAGE_GRACE: f32 = 3.0;
pub const FALL_DAMAGE_PER_BLOCK: f32 = 1.0;

/// Bedrock grants a three-block exemption and then one point per block past it.
pub fn fallDamage(blocks_fallen: f32) f32 {
    if (!(blocks_fallen > FALL_DAMAGE_GRACE)) return 0;
    return @ceil((blocks_fallen - FALL_DAMAGE_GRACE) * FALL_DAMAGE_PER_BLOCK);
}

pub const MAX_TICK_DESCENT: f32 = 4.0;

/// A drop bigger than any tick of falling is a teleport, not a fall.
pub fn trackFall(distance: f32, previous_y: f32, new_y: f32, grounded: bool) f32 {
    if (grounded) return 0;
    if (new_y >= previous_y) return distance;
    const drop = previous_y - new_y;
    if (drop > MAX_TICK_DESCENT) return 0;
    return distance + drop;
}

pub fn playerDropVelocity(rotation: Protocol.Vector2f) Protocol.Vector3f {
    const yaw = rotation.y * std.math.pi / 180.0;
    const pitch = rotation.x * std.math.pi / 180.0;
    return Protocol.Vector3f.init(
        -@sin(yaw) * @cos(pitch) * DROP_FORWARD_SPEED,
        -@sin(pitch) * DROP_FORWARD_SPEED,
        @cos(yaw) * @cos(pitch) * DROP_FORWARD_SPEED,
    );
}

pub const Player = struct {
    entity: Entity,
    connection: *Raknet.Connection,
    network: *NetworkHandler,
    tecton: Host,
    login_data: LoginData,

    xuid: []const u8,
    username: []const u8,
    uuid: []const u8,

    view_distance: i32 = 8,
    sent_chunks: std.AutoHashMap(i64, void),
    pending_chunks: std.AutoHashMap(i64, void),
    visible_players: std.AutoHashMap(i64, u32),
    visible_sweep: std.ArrayList(i64) = .empty,
    visibility_epoch: u32 = 0,

    visibility_due: bool = false,
    visible_entities: std.AutoHashMap(i64, i64),
    pending_removal: std.atomic.Value(bool) = .init(false),
    spawned: bool = false,
    join_startup_started: bool = false,
    pending_dimension: ?*Dimension = null,
    opened_container: ?*Container = null,
    block_target: ?Protocol.BlockPosition = null,
    gamemode: Protocol.GameMode = .Survival,
    last_broadcast: MoveDelta.LastBroadcast = .{},
    broadcast_band: ?u8 = null,
    on_ground: bool = true,
    falling_distance: f32 = 0,
    pending_move: ?MoveDelta.State = null,
    gliding: bool = false,
    swimming: bool = false,
    crawling: bool = false,
    pose: Pose = .standing,

    pub const NbtHooks = struct {
        pub const InventoryState = InventoryTrait.TraitState;
        pub const HealthState = Health.State;

        pub fn inventoryState(entity: *Entity) ?*InventoryState {
            return entity.getTraitState(InventoryTrait);
        }

        pub fn healthState(entity: *Entity) ?*HealthState {
            return entity.getTraitState(Health.HealthTrait);
        }

        pub fn clampLoadedHealth(current: f32, max: f32) f32 {
            return Health.clampLoadedHealth(current, max);
        }

        pub fn syncAttributes(state: *const HealthState, entity: *Entity) void {
            Health.syncAttributes(state, entity);
        }
    };

    pub fn init(
        self: *Player,
        allocator: std.mem.Allocator,
        connection: *Raknet.Connection,
        network: *NetworkHandler,
        tecton: Host,
        loginData: LoginData,
        entity_type: *const EntityType,
    ) !void {
        self.* = .{
            .entity = Entity.init(allocator, entity_type, null),
            .connection = connection,
            .network = network,
            .tecton = tecton,
            .gamemode = tecton.config.gameMode(),
            .login_data = loginData,
            .xuid = loginData.identity_data.xuid,
            .username = loginData.identity_data.display_name,
            .uuid = loginData.identity_data.identity,
            .sent_chunks = std.AutoHashMap(i64, void).init(allocator),
            .pending_chunks = std.AutoHashMap(i64, void).init(allocator),
            .visible_players = std.AutoHashMap(i64, u32).init(allocator),
            .visible_entities = std.AutoHashMap(i64, i64).init(allocator),
        };

        self.entity.flags.setFlag(.HasGravity, true);
        self.entity.flags.setFlag(.Breathing, true);
        self.entity.flags.setFlag(.ShowName, true);
        self.entity.flags.setFlag(.AlwaysShowName, true);
        self.entity.attributes.registerWithCurrent(.Movement, 0, 3.4028235e+38, 0.1, 0.1) catch {};
        self.entity.attributes.registerWithCurrent(.UnderwaterMovement, 0, 3.4028235e+38, 0.02, 0.02) catch {};
        self.entity.attributes.registerWithCurrent(.LavaMovement, 0, 3.4028235e+38, 0.02, 0.02) catch {};

        const health = try Health.HealthTrait.create(allocator, .{
            .current = Health.MAX_HEALTH,
            .max = Health.MAX_HEALTH,
        });
        try self.entity.addTrait(health);

        const fire = try Fire.FireTrait.create(allocator, .{});
        try self.entity.addTrait(fire);

        const inv = try InventoryTrait.create(allocator, .{
            .container = undefined,
            .selected_slot = 0,
            .opened = false,
        });
        try self.entity.addTrait(inv);

        const stats = try StatsTrait.create(allocator, .{
            .tick_count = 0,
        });
        try self.entity.addTrait(stats);

        const chunk_loading = try ChunkLoadingTrait.ChunkLoadingTrait.create(allocator, .{
            .last_chunk_x = 0,
            .last_chunk_z = 0,
            .initialized = false,
            .visibility_tick = Visibility.VISIBILITY_UPDATE_INTERVAL - 1,
        });
        try self.entity.addTrait(chunk_loading);

        const cursor_trait = try CursorTrait.create(allocator, .{
            .container = undefined,
        });
        try self.entity.addTrait(cursor_trait);

        const trade_window = try TradeWindowTrait.create(allocator, .{
            .container = undefined,
            .initialized = false,
        });
        try self.entity.addTrait(trade_window);

        const created_output = try CreatedOutputTrait.create(allocator, .{
            .container = undefined,
            .initialized = false,
        });
        try self.entity.addTrait(created_output);
    }

    pub fn deinit(self: *Player) void {
        self.sent_chunks.deinit();
        self.pending_chunks.deinit();
        self.visible_players.deinit();
        self.visible_entities.deinit();
        self.visible_sweep.deinit(self.entity.allocator);
        self.login_data.deinit();
        self.entity.deinit();
    }

    pub fn getCommandPermission(_: *Player) void {}

    pub fn disconnect(self: *Player, reason: ?[]const u8) !void {
        if (reason) |msg| {
            var stream = BinaryStream.init(self.entity.allocator, null, null);
            defer stream.deinit();
            var dp = Protocol.DisconnectPacket{
                .reason = .Kicked,
                .messages = .{
                    .message = msg,
                    .filtered_message = msg,
                },
            };
            if (dp.serialize(&stream)) |data| {
                self.network.sendImmediate(self.connection, data) catch {};
            } else |_| {}
        }

        if (!self.beginRemoval()) return;
        self.finalizeRemoval();
    }

    pub fn disconnectFromNetwork(self: *Player) void {
        if (!self.beginRemoval()) return;

        self.tecton.enqueuePlayerRemoval(self);
    }

    fn beginRemoval(self: *Player) bool {
        if (self.pending_removal.swap(true, .acq_rel)) return false;
        self.connection.deactivate();
        self.tecton.removeConnectionMapping(self.connection);
        return true;
    }

    pub fn finalizeRemoval(self: *Player) void {
        self.savePlayerData();
        if (self.entity.dimension) |dimension| {
            self.tecton.setPlayerLocation(self.uuid, dimension.world.identifier, dimension.identifier);
        }

        self.tecton.tasks.cancelByOwner("chunk_streaming", self.entity.runtime_id, ChunkStreaming.destroyStreamState);
        self.tecton.tasks.cancelByOwner("join_startup", self.entity.runtime_id, null);
        self.tecton.tasks.cancelByOwner("player_init", self.entity.runtime_id, null);
        self.releaseChunks();
        if (self.entity.dimension) |dimension| {
            if (dimension.floating_texts) |manager| manager.forgetViewer(self.entity.runtime_id);
        }

        const allocator = self.entity.allocator;
        const snapshots = self.tecton.getPlayerSnapshots();

        {
            var stream = BinaryStream.init(allocator, null, null);
            defer stream.deinit();
            const remove = Protocol.RemoveEntityPacket{ .unique_entity_id = self.entity.unique_id };
            const serialized = remove.serialize(&stream) catch null;
            if (serialized) |data| {
                if (self.entity.dimension) |dimension| {
                    if (SharedBroadcast.begin(
                        self.network.allocator,
                        data,
                        self.network.options,
                    )) |begun| {
                        var broadcast = begun;
                        defer broadcast.deinit();
                        for (snapshots) |other| {
                            if (other.entity.runtime_id == self.entity.runtime_id) continue;
                            if (!other.spawned) continue;
                            if (other.entity.dimension != dimension) continue;
                            _ = other.visible_players.remove(self.entity.runtime_id);
                            broadcast.send(other.connection, .normal);
                        }
                    } else |_| {}
                }
            }
        }

        {
            var stream = BinaryStream.init(allocator, null, null);
            defer stream.deinit();
            const entry = [_]Protocol.PlayerListEntry{.{
                .action = .Remove,
                .uuid = self.uuid,
                .entity_unique_id = self.entity.unique_id,
                .username = self.username,
                .xuid = self.xuid,
                .skin = null,
                .build_platform = 0,
            }};
            var packet = Protocol.PlayerListPacket{
                .entries = &entry,
            };
            const serialized = packet.serialize(&stream, allocator) catch null;
            if (serialized) |data| {
                if (SharedBroadcast.begin(
                    self.network.allocator,
                    data,
                    self.network.options,
                )) |begun| {
                    var broadcast = begun;
                    defer broadcast.deinit();
                    for (snapshots) |other| {
                        if (other.entity.runtime_id == self.entity.runtime_id) continue;
                        if (!other.spawned) continue;
                        broadcast.send(other.connection, .normal);
                    }
                } else |_| {}
            }
        }

        self.tecton.removePlayer(self);
        self.tecton.unregisterEcsEntity(&self.entity);
        self.deinit();
        self.entity.allocator.destroy(self);
    }

    pub fn savePlayerData(self: *Player) void {
        const dimension = self.entity.dimension orelse return;
        dimension.world.provider.writePlayer(self.uuid, self) catch |err| {
            Raknet.Logger.ERROR("Failed to save player {s}: {any}", .{ self.username, err });
        };
    }

    pub fn loadPlayerData(self: *Player) bool {
        const dimension = self.entity.dimension orelse return false;
        return dimension.world.provider.readPlayer(self.uuid, self) catch false;
    }

    pub fn transferToDimension(self: *Player, dimension: *Dimension) void {
        if (self.pending_dimension != null) {
            Raknet.Logger.WARN("Player {s} already has a pending dimension transfer", .{self.username});
            return;
        }

        self.savePlayerData();
        self.tecton.tasks.cancelByOwner("chunk_streaming", self.entity.runtime_id, ChunkStreaming.destroyStreamState);
        self.tecton.tasks.cancelByOwner("join_startup", self.entity.runtime_id, null);
        self.tecton.tasks.cancelByOwner("player_init", self.entity.runtime_id, null);
        self.releaseChunks();
        if (self.entity.getTraitState(ChunkLoadingTrait.ChunkLoadingTrait)) |state| {
            const s: *ChunkLoadingTrait.State = @ptrCast(@alignCast(state));
            s.initialized = false;
        }

        self.clearTransferVisibility();

        const spawn = dimension.spawn_position;
        const pos = Protocol.Vector3f.init(
            @as(f32, @floatFromInt(spawn.x)) + 0.5,
            @as(f32, @floatFromInt(spawn.y)),
            @as(f32, @floatFromInt(spawn.z)) + 0.5,
        );

        const current_type = if (self.entity.dimension) |d| d.dimension_type else null;
        if (current_type != null and current_type.? == dimension.dimension_type) {
            self.entity.dimension = dimension;
            self.entity.instance_id = dimension.instance_id;
            self.tecton.instances.assignDimension(self.entity.runtime_id, dimension) catch {};
            self.entity.position = pos;
            self.tecton.setPlayerLocation(self.uuid, dimension.world.identifier, dimension.identifier);

            var stream = BinaryStream.init(self.entity.allocator, null, null);
            defer stream.deinit();
            const move = Protocol.MovePlayerPacket{
                .runtime_id = @bitCast(self.entity.runtime_id),
                .position = pos,
                .rotation = .zero(),
                .mode = .Teleport,
                .on_ground = false,
            };
            const serialized = move.serialize(&stream) catch return;
            self.network.sendPacket(self.connection, serialized) catch {};
        } else {
            self.spawned = false;
            self.pending_dimension = dimension;

            var stream = BinaryStream.init(self.entity.allocator, null, null);
            defer stream.deinit();
            var pkt = Protocol.ChangeDimensionPacket{
                .dimension = dimension.dimension_type,
                .position = pos,
                .respawn = false,
            };
            const serialized = pkt.serialize(&stream) catch return;
            self.network.sendPacket(self.connection, serialized) catch {};
        }
    }

    fn clearTransferVisibility(self: *Player) void {
        const tecton = self.tecton;

        self.last_broadcast.reset();

        var visible_it = self.visible_players.keyIterator();
        while (visible_it.next()) |runtime_id| {
            const other = tecton.players.byRuntimeId(runtime_id.*) orelse continue;
            if (other.pending_removal.load(.acquire)) continue;
            sendRemoveEntity(self, other.entity.unique_id);
        }
        self.visible_players.clearRetainingCapacity();

        var entity_it = self.visible_entities.iterator();
        while (entity_it.next()) |entry| {
            sendRemoveEntity(self, entry.value_ptr.*);
        }
        self.visible_entities.clearRetainingCapacity();

        if (self.entity.dimension) |dimension| {
            if (dimension.floating_texts) |manager| manager.despawnForViewer(self);
        }

        const snapshots = tecton.getPlayerSnapshots();
        for (snapshots) |other| {
            if (other.entity.runtime_id == self.entity.runtime_id) continue;
            if (!other.spawned) continue;
            if (other.visible_players.remove(self.entity.runtime_id)) {
                sendRemoveEntity(other, self.entity.unique_id);
            }
        }
    }

    fn releaseChunks(self: *Player) void {
        const dimension = self.entity.dimension orelse return;
        const allocator = self.entity.allocator;

        var hashes = std.ArrayList(i64){ .items = &.{}, .capacity = 0 };
        var it = self.sent_chunks.keyIterator();
        while (it.next()) |key| {
            hashes.append(allocator, key.*) catch {};
        }
        self.sent_chunks.clearAndFree();
        self.pending_chunks.clearRetainingCapacity();
        dimension.releaseUnrenderedChunks(hashes.items);
        hashes.deinit(allocator);
    }

    pub fn onSpawn(self: *Player) !void {
        Raknet.Logger.DEBUG("Player {s} has spawned.", .{self.username});

        self.last_broadcast.reset();

        if (self.entity.getTraitState(InventoryTrait)) |state| {
            var s: *InventoryTrait.TraitState = state;
            s.container.update();
        }
    }

    pub fn updatePose(self: *Player) !void {
        const pose = Pose.next(
            self.pose,
            self.gliding,
            self.swimming,
            self.crawling,
            self.entity.flags.getFlag(.Sneaking),
        ) orelse return;

        self.pose = pose;
        self.entity.flags.setFlag(.Gliding, pose == .gliding);
        self.entity.flags.setFlag(.Swimming, pose == .swimming);
        try self.broadcastActorFlags();
    }

    pub fn broadcastActorFlags(self: *Player) !void {
        var str = BinaryStream.init(self.entity.allocator, null, null);
        defer str.deinit();

        const data = try self.entity.flags.buildDataItems(self.entity.allocator, self.pose.size());
        var packet = Protocol.SetActorDataPacket.init(self.entity.allocator, self.entity.runtime_id, 0, data);
        defer packet.deinit();
        const serialized = try packet.serialize(&str);

        const snapshots = self.tecton.getPlayerSnapshots();
        for (snapshots) |other| {
            if (!other.spawned) continue;
            if (other.entity.runtime_id != self.entity.runtime_id and !other.visible_players.contains(self.entity.runtime_id)) continue;
            try self.network.sendPacket(other.connection, serialized);
        }
    }

    fn sendSpawnChunks(self: *Player) !void {
        const allocator = self.entity.allocator;

        var pub_stream = BinaryStream.init(allocator, null, null);
        defer pub_stream.deinit();

        var update = Protocol.NetworkChunkPublisherUpdatePacket{
            .coordinate = Protocol.BlockPosition{
                .x = @intFromFloat(@floor(self.entity.position.x)),
                .y = @intFromFloat(@floor(self.entity.position.y)),
                .z = @intFromFloat(@floor(self.entity.position.z)),
            },
            .radius = @intCast(self.view_distance * 16),
            .saved_chunks = &[_]Protocol.ChunkCoords{},
        };
        const pub_serialized = update.serialize(&pub_stream) catch return;
        self.network.sendPacket(self.connection, pub_serialized) catch {};

        ChunkStreaming.queueChunkStreaming(self) catch {};
    }
};

fn sendRemoveEntity(player: *Player, unique_entity_id: i64) void {
    var stream = BinaryStream.init(player.entity.allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.RemoveEntityPacket{ .unique_entity_id = unique_entity_id };
    const serialized = packet.serialize(&stream) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const damageable = test_owner.damageable;
    pub const MAX_ATTACK_REACH = test_owner.MAX_ATTACK_REACH;
    pub const withinAttackReach = test_owner.withinAttackReach;
    pub const playerDropVelocity = test_owner.playerDropVelocity;
    pub const FALL_DAMAGE_GRACE = test_owner.FALL_DAMAGE_GRACE;
    pub const MAX_TICK_DESCENT = test_owner.MAX_TICK_DESCENT;
    pub const fallDamage = test_owner.fallDamage;
    pub const trackFall = test_owner.trackFall;
};

test "only survival and adventure players take damage" {
    try @import("player_test.zig").Suite(test_scope).case_000();
}

test "an attack has to be within reach of the attacker" {
    try @import("player_test.zig").Suite(test_scope).case_001();
}

test "player drop velocity matches pocketmine direction toss" {
    try @import("player_test.zig").Suite(test_scope).case_002();
}

test "a fall shorter than three blocks costs nothing" {
    try @import("player_test.zig").Suite(test_scope).case_003();
}

test "the fall tracker only counts the descent and clears on landing" {
    try @import("player_test.zig").Suite(test_scope).case_004();
}
