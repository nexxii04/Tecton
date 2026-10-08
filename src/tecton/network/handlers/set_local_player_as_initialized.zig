const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Compression = @import("../compression/compression.zig").Compression;
const SharedBroadcast = @import("../shared_broadcast.zig").SharedBroadcast;

const Player = @import("../../player/player.zig").Player;
const buildAbilities = @import("./abilities.zig").buildAbilities;

const PlayerInitStage = enum(u8) {
    on_spawn,
    send_existing_players,
    broadcast_new_player,
};

const PlayerInitTask = struct {
    tecton: *Tecton,
    network: *NetworkHandler,
    player: *Player,
    stage: PlayerInitStage = .on_spawn,
};

pub fn handleSetLocalPlayerAsInitialized(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    _: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    if (player.spawned) return;

    try queuePlayerInit(tecton, network, player);
}

fn queuePlayerInit(tecton: *Tecton, network: *NetworkHandler, player: *Player) !void {
    tecton.tasks.cancelByOwner("player_init", player.entity.runtime_id, null);

    const state = try network.allocator.create(PlayerInitTask);
    errdefer network.allocator.destroy(state);
    state.* = .{
        .tecton = tecton,
        .network = network,
        .player = player,
    };

    try tecton.tasks.enqueue(.{
        .func = runPlayerInitTask,
        .ctx = @ptrCast(state),
        .name = "player_init",
        .owner_id = player.entity.runtime_id,
        .cleanup = destroyPlayerInitTask,
    });
}

fn runPlayerInitTask(ctx: *anyopaque) bool {
    const state: *PlayerInitTask = @ptrCast(@alignCast(ctx));
    return runPlayerInitTaskImpl(state) catch |err| {
        Raknet.Logger.ERROR("Player init failed for {s} at stage {s}: {any}", .{
            state.player.username,
            @tagName(state.stage),
            err,
        });
        return true;
    };
}

fn runPlayerInitTaskImpl(state: *PlayerInitTask) !bool {
    const player = state.player;
    if (!player.connection.isActive() or state.tecton.getPlayerByConnection(player.connection) == null) {
        return true;
    }

    switch (state.stage) {
        .on_spawn => {
            try player.onSpawn();

            const is_operator = std.mem.eql(u8, state.tecton.permission_manager.getPlayerGroup(player.username), "operator");
            var abilities = try buildAbilities(state.network.allocator, player.entity.runtime_id, player.gamemode, is_operator);
            defer abilities.deinit();
            var stream = BinaryStream.init(state.network.allocator, null, null);
            defer stream.deinit();
            const serialized = try abilities.serialize(&stream);
            try state.network.sendPacket(player.connection, serialized);

            state.stage = .send_existing_players;
            return false;
        },
        .send_existing_players => {
            try sendExistingPlayers(state);
            state.stage = .broadcast_new_player;
            return false;
        },
        .broadcast_new_player => {
            try broadcastNewPlayer(state);
            player.spawned = true;
            return true;
        },
    }
}

fn destroyPlayerInitTask(ctx: *anyopaque) void {
    const state: *PlayerInitTask = @ptrCast(@alignCast(ctx));
    state.network.allocator.destroy(state);
}

fn sendExistingPlayers(state: *PlayerInitTask) !void {
    const snapshots = state.tecton.getPlayerSnapshots();
    if (snapshots.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const entries = try temp_allocator.alloc(Protocol.PlayerListEntry, snapshots.len);
    var written: usize = 0;
    for (snapshots) |p| {
        if (!p.spawned and p.entity.runtime_id != state.player.entity.runtime_id) continue;
        entries[written] = .{
            .action = .Add,
            .uuid = p.uuid,
            .entity_unique_id = p.entity.unique_id,
            .username = p.username,
            .xuid = p.xuid,
            .skin = &p.login_data.client_data,
            .build_platform = @intCast(p.login_data.client_data.device_os),
        };
        written += 1;
    }
    if (written == 0) return;

    var stream = BinaryStream.init(temp_allocator, null, null);
    defer stream.deinit();
    var packet = Protocol.PlayerListPacket{
        .entries = entries[0..written],
    };
    const serialized = try packet.serialize(&stream, temp_allocator);
    try state.network.sendPacket(state.player.connection, serialized);
}

fn broadcastNewPlayer(state: *PlayerInitTask) !void {
    const snapshots = state.tecton.getPlayerSnapshots();
    if (snapshots.len <= 1) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const entry = [_]Protocol.PlayerListEntry{.{
        .action = .Add,
        .uuid = state.player.uuid,
        .entity_unique_id = state.player.entity.unique_id,
        .username = state.player.username,
        .xuid = state.player.xuid,
        .skin = &state.player.login_data.client_data,
        .build_platform = @intCast(state.player.login_data.client_data.device_os),
    }};

    var stream = BinaryStream.init(temp_allocator, null, null);
    defer stream.deinit();
    var packet = Protocol.PlayerListPacket{
        .entries = &entry,
    };
    const serialized = try packet.serialize(&stream, temp_allocator);

    var broadcast = try SharedBroadcast.begin(
        state.network.allocator,
        serialized,
        state.network.options,
    );
    defer broadcast.deinit();

    for (snapshots) |other| {
        if (other.entity.runtime_id == state.player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        broadcast.send(other.connection, .normal);
    }
}
