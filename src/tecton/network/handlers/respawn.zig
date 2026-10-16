const Raknet = @import("Raknet");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const Fire = @import("../../entity/traits/fire.zig");
const Health = @import("../../entity/traits/health.zig");
const visibility = @import("../../entity/traits/visibility.zig");

pub const State = enum(u8) {
    SearchingForSpawn = 0,
    ReadyToSpawn = 1,
    ClientReadyToSpawn = 2,
    _,
};

pub fn handleRespawn(tecton: *Tecton, network: *NetworkHandler, connection: *Raknet.Connection, stream: *BinaryStream) !void {
    _ = stream;

    const player = tecton.getPlayerByConnection(connection) orelse return;
    respawnPlayer(network, player);
}

pub fn respawnPlayer(network: *NetworkHandler, player: *Player) void {
    const health_state = player.entity.getTraitState(Health.HealthTrait) orelse return;
    const dimension = player.entity.dimension orelse return;
    if (!Health.revive(health_state, &player.entity)) return;
    Fire.extinguish(&player.entity);

    const spawn = dimension.spawn_position;
    const position = Protocol.Vector3f.init(
        @as(f32, @floatFromInt(spawn.x)) + 0.5,
        @as(f32, @floatFromInt(spawn.y)),
        @as(f32, @floatFromInt(spawn.z)) + 0.5,
    );
    player.entity.position = position;
    player.entity.motion = Protocol.Vector3f.init(0, 0, 0);

    sendRespawnStates(network, player, position);
    sendMovePlayer(network, player, position);
    sendHealthAttributes(network, player);

    visibility.forgetPlayerForViewers(player);
}

fn sendRespawnStates(network: *NetworkHandler, player: *Player, position: Protocol.Vector3f) void {
    const states = [_]State{ .SearchingForSpawn, .ReadyToSpawn };
    for (states) |state| {
        var stream = BinaryStream.init(network.allocator, null, null);
        defer stream.deinit();

        stream.writeVarInt(Protocol.Packet.Respawn) catch return;
        Protocol.Vector3f.write(&stream, position) catch return;
        stream.writeUint8(@intFromEnum(state)) catch return;
        stream.writeVarLong(@intCast(player.entity.runtime_id)) catch return;

        network.sendPacket(player.connection, stream.getBuffer()) catch {};
    }
}

fn sendMovePlayer(network: *NetworkHandler, player: *Player, position: Protocol.Vector3f) void {
    var stream = BinaryStream.init(network.allocator, null, null);
    defer stream.deinit();

    const move = Protocol.MovePlayerPacket{
        .runtime_id = @bitCast(player.entity.runtime_id),
        .position = position,
        .rotation = .zero(),
        .mode = .Teleport,
        .on_ground = false,
    };
    const serialized = move.serialize(&stream) catch return;
    network.sendPacket(player.connection, serialized) catch {};
}

pub fn sendHealthAttributes(network: *NetworkHandler, player: *Player) void {
    var stream = BinaryStream.init(network.allocator, null, null);
    defer stream.deinit();

    var attrs = player.entity.attributes.collectAll(network.allocator) catch return;
    defer attrs.deinit(network.allocator);

    const packet = Protocol.UpdateAttributesPacket{
        .runtime_actor_id = player.entity.runtime_id,
        .attributes = attrs,
        .tick = 0,
    };
    const serialized = packet.serialize(&stream) catch return;
    network.sendPacket(player.connection, serialized) catch {};
}
