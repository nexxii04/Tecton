const std = @import("std");
const Raknet = @import("Raknet");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Compression = @import("../compression/compression.zig").Compression;

const Player = @import("../../player/player.zig").Player;

const PlayerInitStage = enum(u8) {
    on_spawn,
    send_existing_players,
    broadcast_new_player,
};

const PlayerInitTask = struct {
    network: *NetworkHandler,
    player: *Player,
    stage: PlayerInitStage = .on_spawn,
};

pub fn handleSetLocalPlayerAsInitialized(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    _: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
    if (player.spawned) return;

    try queuePlayerInit(network, player);
}

fn queuePlayerInit(network: *NetworkHandler, player: *Player) !void {
    network.conduit.tasks.cancelByOwner("player_init", player.entity.runtime_id, null);

    const state = try network.allocator.create(PlayerInitTask);
    errdefer network.allocator.destroy(state);
    state.* = .{
        .network = network,
        .player = player,
    };

    try network.conduit.tasks.enqueue(.{
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
    if (!player.connection.active or state.network.conduit.getPlayerByConnection(player.connection) == null) {
        return true;
    }

    switch (state.stage) {
        .on_spawn => {
            try player.onSpawn();
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
    const snapshots = state.network.conduit.getPlayerSnapshots();
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
            .entity_unique_id = p.entity.runtime_id,
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
    const snapshots = state.network.conduit.getPlayerSnapshots();
    if (snapshots.len <= 1) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const entry = [_]Protocol.PlayerListEntry{.{
        .action = .Add,
        .uuid = state.player.uuid,
        .entity_unique_id = state.player.entity.runtime_id,
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

    const packets = [_][]const u8{serialized};
    const compressed = try Compression.compress(&packets, state.network.options, state.network.allocator);
    defer state.network.allocator.free(compressed);

    for (snapshots) |other| {
        if (other.entity.runtime_id == state.player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        other.connection.sendReliableMessage(compressed, .Normal);
    }
}
