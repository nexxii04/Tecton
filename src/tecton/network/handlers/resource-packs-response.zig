const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Player = @import("../../player/player.zig").Player;
const PlayerLocation = @import("../../player/player-locations.zig").Location;
const Tecton = @import("../../tecton.zig").Tecton;
const World = @import("../../world/world.zig").World;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const EntityTypeRegistry = @import("../../entity/entity-type-registry.zig");

const JoinStartupStage = enum(u8) {
    prepare_player,
    send_pre_spawn_data,
    send_start_game,
    send_registry_batch,
    send_commands,
    send_entity_batch,
    send_abilities_spawn,
};

const JoinStartupTask = struct {
    tecton: *Tecton,
    network: *NetworkHandler,
    player: *Player,
    stage: JoinStartupStage = .prepare_player,
    wait_ticks: u8 = 0,
    spawn_pos: Protocol.BlockPosition = Protocol.BlockPosition.init(0, 100, 0),
};

const JOIN_STAGE_DELAY_TICKS: u8 = 20;

pub fn handleResourcePack(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const response = try Protocol.ResourcePackResponsePacket.deserialize(stream, network.allocator);
    defer response.deinit(network.allocator);
    switch (response.response) {
        .HaveAllPacks => {
            var str = BinaryStream.init(network.allocator, null, null);
            defer str.deinit();

            const empty_packs = [_]Protocol.ResourceIdVersions{};
            const empty_experiments = [_]Protocol.Experiments{};

            var stack = Protocol.ResourcePackStackPacket{
                .must_accept = false,
                .texture_packs = &empty_packs,
                .game_version = Protocol.MINECRAFT_VERSION,
                .experiments = &empty_experiments,
                .experiments_previously_toggled = false,
                .has_editor_packs = false,
            };

            const serialized = try stack.serialize(&str);
            try network.sendPacket(connection, serialized);
        },
        .Refused => {
            if (tecton.getPlayerByConnection(connection)) |player| {
                try player.disconnect(null);
            }
        },
        .None => {},
        .SendPacks => {},
        .Completed => {
            if (tecton.getPlayerByConnection(connection)) |player| {
                try queueJoinStartup(tecton, network, player);
            }
        },
    }
}

fn queueJoinStartup(tecton: *Tecton, network: *NetworkHandler, player: *Player) !void {
    if (player.join_startup_started) return;
    player.join_startup_started = true;

    const state = try network.allocator.create(JoinStartupTask);
    errdefer network.allocator.destroy(state);
    state.* = .{
        .tecton = tecton,
        .network = network,
        .player = player,
    };

    try tecton.tasks.enqueue(.{
        .func = runJoinStartupTask,
        .ctx = @ptrCast(state),
        .name = "join_startup",
        .owner_id = player.entity.runtime_id,
        .cleanup = destroyJoinStartupTask,
    });
}

fn runJoinStartupTask(ctx: *anyopaque) bool {
    const state: *JoinStartupTask = @ptrCast(@alignCast(ctx));
    return runJoinStartupTaskImpl(state) catch |err| {
        Raknet.Logger.ERROR("Join startup failed for {s}: {any}", .{ state.player.username, err });
        state.player.join_startup_started = false;
        return true;
    };
}

fn runJoinStartupTaskImpl(state: *JoinStartupTask) !bool {
    const player = state.player;
    if (!player.connection.isActive() or state.tecton.getPlayerByConnection(player.connection) == null) {
        player.join_startup_started = false;
        return true;
    }

    if (state.wait_ticks > 0) {
        state.wait_ticks -= 1;
        return false;
    }

    switch (state.stage) {
        .prepare_player => {
            const location = state.tecton.resolvePlayerLocation(player.uuid);
            const world = resolveJoinWorld(state.tecton, location) orelse {
                Raknet.Logger.ERROR("Join startup failed for {s}: no world available", .{player.username});
                player.join_startup_started = false;
                return true;
            };

            const dimension = resolveJoinDimension(world, location) orelse {
                Raknet.Logger.ERROR("Join startup failed for {s}: no dimension available", .{player.username});
                player.join_startup_started = false;
                return true;
            };
            player.entity.dimension = dimension;
            player.entity.instance_id = dimension.instance_id;
            player.tecton.instances.assignDimension(player.entity.runtime_id, dimension) catch {};
            player.tecton.registerEcsEntity(&player.entity);

            const loaded = player.loadPlayerData();
            state.spawn_pos = dimension.spawn_position;

            if (!loaded) {
                player.entity.position = Protocol.Vector3f.init(
                    @floatFromInt(state.spawn_pos.x),
                    @floatFromInt(state.spawn_pos.y),
                    @floatFromInt(state.spawn_pos.z),
                );
            }

            state.stage = .send_pre_spawn_data;
            return false;
        },
        .send_pre_spawn_data => {
            try sendPreSpawnDataBatch(state);
            state.wait_ticks = JOIN_STAGE_DELAY_TICKS;
            state.stage = .send_start_game;
            return false;
        },
        .send_start_game => {
            try sendStartGameBatch(state);
            state.wait_ticks = JOIN_STAGE_DELAY_TICKS;
            state.stage = .send_registry_batch;
            return false;
        },
        .send_registry_batch => {
            try sendRegistryBatch(state);
            state.wait_ticks = JOIN_STAGE_DELAY_TICKS;
            state.stage = .send_commands;
            return false;
        },
        .send_commands => {
            try sendCommandsPacket(state);
            state.wait_ticks = JOIN_STAGE_DELAY_TICKS;
            state.stage = .send_entity_batch;
            return false;
        },
        .send_entity_batch => {
            try sendEntityDataBatch(state);
            state.wait_ticks = JOIN_STAGE_DELAY_TICKS;
            state.stage = .send_abilities_spawn;
            return false;
        },
        .send_abilities_spawn => {
            try sendAbilitiesAndSpawnBatch(state);
            return true;
        },
    }
}

fn destroyJoinStartupTask(ctx: *anyopaque) void {
    const state: *JoinStartupTask = @ptrCast(@alignCast(ctx));
    state.network.allocator.destroy(state);
}

fn resolveJoinWorld(tecton: *Tecton, location: ?*const PlayerLocation) ?*World {
    if (location) |loc| {
        if (tecton.worlds.get(loc.world)) |world| return world;
    }
    if (tecton.worlds.get("world")) |world| return world;
    var it = tecton.worlds.valueIterator();
    const entry = it.next() orelse return null;
    return entry.*;
}

fn resolveJoinDimension(world: *World, location: ?*const PlayerLocation) ?*Dimension {
    if (location) |loc| {
        if (world.getDimension(loc.dimension)) |dimension| return dimension;
    }
    if (world.getDimension("overworld")) |dimension| return dimension;
    var it = world.dimensions.valueIterator();
    const entry = it.next() orelse return null;
    return entry.*;
}

fn sendPreSpawnDataBatch(state: *JoinStartupTask) !void {
    const psd = state.tecton.pre_spawn_data orelse return;

    var batched_packets = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer batched_packets.deinit(state.network.allocator);
    var owned_packets = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer freeOwnedPackets(state.network.allocator, &owned_packets);

    {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();
        var packet = Protocol.JigsawStructureDataPacket.init(psd.jigsaw_nbt);
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();
        var packet = Protocol.VoxelShapesPacket{
            .shapes = psd.voxel_shapes,
            .name_map = psd.voxel_name_map,
            .custom_shape_count = 0,
        };
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    if (batched_packets.items.len > 0) {
        try state.network.sendPackets(state.player.connection, batched_packets.items);
    }
}

fn sendStartGameBatch(state: *JoinStartupTask) !void {
    var batched_packets = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer batched_packets.deinit(state.network.allocator);
    var owned_packets = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer freeOwnedPackets(state.network.allocator, &owned_packets);

    var str = BinaryStream.init(state.network.allocator, null, null);
    defer str.deinit();

    const player = state.player;
    const entity_id: i64 = player.entity.runtime_id;
    const runtime_entity_id: u64 = @bitCast(player.entity.runtime_id);
    const properties = Protocol.NBT.Tag{ .Compound = Protocol.NBT.CompoundTag.init(state.network.allocator, null) };
    const gamerules = [_]Protocol.GameRules.GameRules{
        Protocol.GameRules.GameRules.init(true, "showcoordinates", .Bool, .{ .Bool = true }),
    };
    const empty_experiments = [_]Protocol.Experiments{};
    const empty_block_definitions = [_]Protocol.NetworkBlockTypeDefinition{};
    const block_definitions: []const Protocol.NetworkBlockTypeDefinition = if (state.tecton.pre_spawn_data) |psd| psd.block_palette else &empty_block_definitions;

    var packet = Protocol.StartGamePacket{
        .entity_id = entity_id,
        .runtime_entity_id = runtime_entity_id,
        .player_gamemode = .Creative,
        .player_position = player.entity.position,
        .pitch = player.entity.rotation.x,
        .yaw = player.entity.rotation.y,
        .seed = 12345678,
        .biome_type = 0,
        .biome_name = "plains",
        .dimension = 0,
        .generator = 1,
        .world_gamemode = .Survival,
        .hardcore = false,
        .difficulty = .Normal,
        .spawn_position = state.spawn_pos,
        .achievements_disabled = true,
        .editor_world_type = 0,
        .created_in_editor = false,
        .exported_from_editor = false,
        .day_cycle_stop_time = -1,
        .edu_offer = 0,
        .edu_features = false,
        .edu_product_uuid = "",
        .rain_level = 0.0,
        .lightning_level = 0.0,
        .confirmed_platform_locked_content = false,
        .multiplayer_game = true,
        .broadcast_to_lan = true,
        .xbl_broadcast_mode = 6,
        .platform_broadcast_mode = 6,
        .commands_enabled = true,
        .texture_packs_required = false,
        .gamerules = @constCast(&gamerules),
        .experiments = &empty_experiments,
        .experiments_previously_toggled = false,
        .bonus_chest = false,
        .map_enabled = false,
        .permission_level = .Operator,
        .server_chunk_tick_range = 4,
        .has_locked_behavior_pack = false,
        .has_locked_resource_pack = false,
        .is_from_locked_world_template = false,
        .use_msa_gamertags_only = false,
        .is_from_world_template = false,
        .is_world_template_option_locked = false,
        .only_spawn_v1_villagers = false,
        .persona_disabled = false,
        .custom_skins_disabled = false,
        .emote_chat_muted = false,
        .game_version = Protocol.MINECRAFT_VERSION,
        .limited_world_width = 0,
        .limited_world_length = 0,
        .is_new_nether = true,
        .edu_resource_uri_button_name = "",
        .edu_resource_uri_link = "",
        .experimental_gameplay_override = false,
        .chat_restriction_level = 0,
        .disable_player_interactions = false,
        .server_editor_connection_policy = 0,
        .allow_anonimous_block_drops_in_editor_worlds = false,
        .level_identifier = "Tecton",
        .level_name = state.tecton.raknet.options.advertisement.level_name,
        .premium_world_template_id = "00000000-0000-0000-0000-000000000000",
        .is_trial = false,
        .rewind_history_size = 0,
        .server_authoritative_block_breaking = true,
        .current_tick = 0,
        .enchantment_seed = 0,
        .block_type_definitions = block_definitions,
        .multiplayer_correlation_id = "<raknet>",
        .server_authoritative_inventory = true,
        .engine = "Tecton",
        .properties = properties,
        .block_palette_checksum = 0,
        .world_template_id = "00000000-0000-0000-0000-000000000000",
        .client_side_generation = false,
        .block_network_ids_are_hashes = true,
        .server_controlled_sounds = true,
        .contains_server_join_info = false,
        .server_telemetry_data = Protocol.ServerTelemetryData.init(
            "Tecton",
            "tecton.default",
            state.tecton.raknet.options.advertisement.level_name,
            player.username,
        ),
    };

    try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    try state.network.sendPackets(player.connection, batched_packets.items);
}

fn sendRegistryBatch(state: *JoinStartupTask) !void {
    var batched_packets = std.ArrayList([]const u8).empty;
    defer batched_packets.deinit(state.network.allocator);
    var owned_packets = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer freeOwnedPackets(state.network.allocator, &owned_packets);

    if (EntityTypeRegistry.EntityTypeRegistry.getSerializedPacket()) |serialized| {
        try batched_packets.append(state.network.allocator, serialized);
    }
    if (state.tecton.serialized_item_registry) |serialized| {
        try batched_packets.append(state.network.allocator, serialized);
    }

    if (state.tecton.serialized_biome_definitions) |serialized| {
        try batched_packets.append(state.network.allocator, serialized);
    }
    if (state.tecton.creative_content) |cc| {
        try batched_packets.append(state.network.allocator, cc.serialized);
    }

    if (batched_packets.items.len > 0) {
        try state.network.sendPackets(state.player.connection, batched_packets.items);
    }
}

fn sendCommandsPacket(state: *JoinStartupTask) !void {
    var str = BinaryStream.init(state.network.allocator, null, null);
    defer str.deinit();
    const serialized = try state.tecton.command_registry.buildAvailableCommandsPacket(&str);
    try state.network.sendPacket(state.player.connection, serialized);
}

fn sendEntityDataBatch(state: *JoinStartupTask) !void {
    var batched_packets = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer batched_packets.deinit(state.network.allocator);
    var owned_packets = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer freeOwnedPackets(state.network.allocator, &owned_packets);

    {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();

        const data = try state.player.entity.flags.buildDataItems(state.network.allocator, state.player.pose.size());
        var packet = Protocol.SetActorDataPacket.init(state.network.allocator, state.player.entity.runtime_id, 0, data);
        defer packet.deinit();
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();

        var attrs = try state.player.entity.attributes.collectAll(state.network.allocator);
        defer attrs.deinit(state.network.allocator);

        var packet = Protocol.UpdateAttributesPacket{
            .runtime_actor_id = state.player.entity.runtime_id,
            .attributes = attrs,
            .tick = 0,
        };
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    if (batched_packets.items.len > 0) {
        try state.network.sendPackets(state.player.connection, batched_packets.items);
    }
}

fn sendAbilitiesAndSpawnBatch(state: *JoinStartupTask) !void {
    var batched_packets = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer batched_packets.deinit(state.network.allocator);
    var owned_packets = std.ArrayList([]u8){ .items = &.{}, .capacity = 0 };
    defer freeOwnedPackets(state.network.allocator, &owned_packets);

    const send_update_abilities = false;
    if (send_update_abilities) {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();

        const AbilitySet = Protocol.AbilitySet;
        const abilities = try state.network.allocator.alloc(AbilitySet, 19);
        abilities[0] = .{ .ability = .Build, .value = true };
        abilities[1] = .{ .ability = .Mine, .value = true };
        abilities[2] = .{ .ability = .DoorsAndSwitches, .value = true };
        abilities[3] = .{ .ability = .OpenContainers, .value = true };
        abilities[4] = .{ .ability = .AttackPlayers, .value = true };
        abilities[5] = .{ .ability = .AttackMobs, .value = true };
        abilities[6] = .{ .ability = .OperatorCommands, .value = true };
        abilities[7] = .{ .ability = .Teleport, .value = true };
        abilities[8] = .{ .ability = .Invulnerable, .value = true };
        abilities[9] = .{ .ability = .Flying, .value = false };
        abilities[10] = .{ .ability = .MayFly, .value = true };
        abilities[11] = .{ .ability = .InstantBuild, .value = true };
        abilities[12] = .{ .ability = .Lightning, .value = false };
        abilities[13] = .{ .ability = .FlySpeed, .value = true };
        abilities[14] = .{ .ability = .WalkSpeed, .value = true };
        abilities[15] = .{ .ability = .Muted, .value = false };
        abilities[16] = .{ .ability = .WorldBuilder, .value = false };
        abilities[17] = .{ .ability = .NoClip, .value = false };
        abilities[18] = .{ .ability = .PrivilegedBuilder, .value = false };

        const layers = try state.network.allocator.alloc(Protocol.AbilityLayer, 1);
        layers[0] = .{
            .layer_type = @intFromEnum(Protocol.AbilityLayerType.Base),
            .abilities = abilities,
            .fly_speed = 0.05,
            .vertical_fly_speed = 1.0,
            .walk_speed = 0.1,
        };

        var packet = Protocol.UpdateAbilitiesPacket.init(
            state.network.allocator,
            state.player.entity.runtime_id,
            @intFromEnum(Protocol.PermissionLevel.Operator),
            1,
            layers,
        );
        defer packet.deinit();
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    {
        var str = BinaryStream.init(state.network.allocator, null, null);
        defer str.deinit();

        var packet = Protocol.PlayStatusPacket{
            .status = .PlayerSpawn,
        };
        try appendOwnedPacket(state.network, &batched_packets, &owned_packets, try packet.serialize(&str));
    }

    if (batched_packets.items.len > 0) {
        try state.network.sendPackets(state.player.connection, batched_packets.items);
    }
}

fn appendOwnedPacket(
    network: *NetworkHandler,
    packets: *std.ArrayList([]const u8),
    owned_packets: *std.ArrayList([]u8),
    serialized: []const u8,
) !void {
    const owned = try network.allocator.dupe(u8, serialized);
    errdefer network.allocator.free(owned);
    try owned_packets.append(network.allocator, owned);
    try packets.append(network.allocator, owned);
}

fn freeOwnedPackets(allocator: std.mem.Allocator, owned_packets: *std.ArrayList([]u8)) void {
    for (owned_packets.items) |packet| allocator.free(packet);
    owned_packets.deinit(allocator);
}
