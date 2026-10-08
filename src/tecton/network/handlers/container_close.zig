const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const BlockContainer = @import("../../container/block_container.zig").BlockContainer;
const TradeWindowTrait = @import("../../entity/traits/trade_window.zig").TradeWindowTrait;
const trade_window = @import("../../entity/traits/trade_window.zig");
const BarrelTrait = @import("../../world/block/traits/barrel.zig").BarrelTrait;
const ChestTrait = @import("../../world/block/traits/chest.zig").ChestTrait;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const broadcast = @import("../../world/dimension/broadcast.zig");
const NetworkHandler = @import("../network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;

pub fn handleContainerClose(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    const packet = try Protocol.ContainerClosePacket.deserialize(stream);

    if (player.opened_container) |container| {
        if (container.occupants.get(player)) |window_id| {
            if (packet.identifier != window_id and packet.identifier != .None) {
                return;
            }

            if (container.container_type == .Trading) {
                if (player.entity.getTraitState(TradeWindowTrait)) |trade_state| {
                    trade_window.onWindowClosed(trade_state, player);
                }
            }

            container.close(player, false);

            if (container.container_type != .Trading) {
                if (container.occupants.count() == 0) {
                    trySendBlockClose(player, network, container);
                }
            }
        } else {
            player.opened_container = null;
            var str = BinaryStream.init(network.allocator, null, null);
            defer str.deinit();

            const response = Protocol.ContainerClosePacket{
                .identifier = packet.identifier,
                .container_type = packet.container_type,
                .server_initiated = false,
            };
            const serialized = try response.serialize(&str);
            try network.sendPacket(connection, serialized);
        }
    } else {
        var str = BinaryStream.init(network.allocator, null, null);
        defer str.deinit();

        const response = Protocol.ContainerClosePacket{
            .identifier = packet.identifier,
            .container_type = packet.container_type,
            .server_initiated = false,
        };
        const serialized = try response.serialize(&str);
        try network.sendPacket(connection, serialized);
    }
}

fn trySendBlockClose(player: *@import("../../player/player.zig").Player, network: *NetworkHandler, container: *@import("../../container/container.zig").Container) void {
    const block_container: *BlockContainer = @fieldParentPtr("base", container);
    const position = block_container.position orelse return;

    const dimension = player.entity.dimension orelse return;
    const block = dimension.getBlockPtr(position) orelse return;

    if (block.hasTrait(BarrelTrait.identifier)) {
        sendBarrelClose(dimension, network, block, position);
        return;
    }

    if (!block.hasTrait(ChestTrait.identifier)) return;

    const state = block.getTraitState(ChestTrait) orelse return;

    sendCloseAt(dimension, network, block, position);
    if (state.pair_position) |pair_pos| {
        sendCloseAt(dimension, network, block, .{
            .x = pair_pos.x,
            .y = position.y,
            .z = pair_pos.z,
        });
    }
}

fn sendCloseAt(dimension: *Dimension, network: *NetworkHandler, block: *@import("../../world/block/block.zig").Block, position: Protocol.BlockPosition) void {
    const perm = block.getPermutation(0) catch return;

    var event_stream = BinaryStream.init(network.allocator, null, null);
    defer event_stream.deinit();
    const event_packet = Protocol.BlockEventPacket{
        .position = position,
        .event_type = .ChangeState,
        .data = 0,
    };
    const event_serialized = event_packet.serialize(&event_stream) catch return;
    broadcast.broadcastBlockUpdateToViewers(dimension, position, event_serialized);

    const sound_position = Protocol.Vector3f.init(
        @floatFromInt(position.x),
        @floatFromInt(position.y),
        @floatFromInt(position.z),
    );

    var sound_stream = BinaryStream.init(network.allocator, null, null);
    defer sound_stream.deinit();
    const sound_packet = Protocol.LevelSoundEventPacket{
        .event = .chest_closed,
        .position = sound_position,
        .data = perm.network_id,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const sound_serialized = sound_packet.serialize(&sound_stream) catch return;
    broadcast.broadcastToNearby(dimension, sound_position, broadcast.SOUND_BROADCAST_RADIUS, sound_serialized);
}

fn sendBarrelClose(dimension: *Dimension, network: *NetworkHandler, block: *@import("../../world/block/block.zig").Block, position: Protocol.BlockPosition) void {
    const BlockType = @import("../../world/block/block_type.zig").BlockType;
    const BlockState = @import("../../world/block/block_permutation.zig").BlockState;

    const perm = block.getPermutation(0) catch return;
    if (!perm.state.contains("open_bit")) return;

    const block_type = BlockType.get(perm.identifier) orelse return;
    var state = BlockState.init(network.allocator);
    defer state.deinit();

    var iter = perm.state.iterator();
    while (iter.next()) |entry| {
        state.put(entry.key_ptr.*, entry.value_ptr.*) catch return;
    }
    state.put("open_bit", .{ .boolean = false }) catch return;

    const new_perm = block_type.getPermutation(state);
    block.setPermutation(new_perm, 0) catch {};

    const network_id: u32 = @bitCast(new_perm.network_id);

    var update_stream = BinaryStream.init(network.allocator, null, null);
    defer update_stream.deinit();
    const update = Protocol.UpdateBlockPacket{
        .position = position,
        .network_block_id = network_id,
    };
    const update_serialized = update.serialize(&update_stream) catch return;
    broadcast.broadcastBlockUpdateToViewers(dimension, position, update_serialized);

    const sound_position = Protocol.Vector3f.init(
        @floatFromInt(position.x),
        @floatFromInt(position.y),
        @floatFromInt(position.z),
    );

    var sound_stream = BinaryStream.init(network.allocator, null, null);
    defer sound_stream.deinit();
    const sound = Protocol.LevelSoundEventPacket{
        .event = .block_barrel_close,
        .position = sound_position,
        .data = new_perm.network_id,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const sound_serialized = sound.serialize(&sound_stream) catch return;
    broadcast.broadcastToNearby(dimension, sound_position, broadcast.SOUND_BROADCAST_RADIUS, sound_serialized);
}
