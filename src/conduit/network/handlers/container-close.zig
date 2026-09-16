const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const BlockContainer = @import("../../container/block-container.zig").BlockContainer;
const TradeWindowTrait = @import("../../entity/traits/trade-window.zig").TradeWindowTrait;
const trade_window = @import("../../entity/traits/trade-window.zig");
const BarrelTrait = @import("../../world/block/traits/barrel.zig").BarrelTrait;
const ChestTrait = @import("../../world/block/traits/chest.zig").ChestTrait;
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;

pub fn handleContainerClose(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
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
        sendBarrelClose(network, block, position);
        return;
    }

    if (!block.hasTrait(ChestTrait.identifier)) return;

    const state = block.getTraitState(ChestTrait) orelse return;

    sendCloseAt(network, block, position);
    if (state.pair_position) |pair_pos| {
        sendCloseAt(network, block, .{
            .x = pair_pos.x,
            .y = position.y,
            .z = pair_pos.z,
        });
    }
}

fn sendCloseAt(network: *NetworkHandler, block: *@import("../../world/block/block.zig").Block, position: Protocol.BlockPosition) void {
    const perm = block.getPermutation(0) catch return;
    const snapshots = network.conduit.getPlayerSnapshots();

    for (snapshots) |p| {
        if (!p.spawned) continue;
        {
            var s = BinaryStream.init(network.allocator, null, null);
            defer s.deinit();
            const event_packet = Protocol.BlockEventPacket{
                .position = position,
                .event_type = .ChangeState,
                .data = 0,
            };
            const serialized = event_packet.serialize(&s) catch continue;
            network.sendPacket(p.connection, serialized) catch {};
        }
        {
            var s = BinaryStream.init(network.allocator, null, null);
            defer s.deinit();
            const sound_packet = Protocol.LevelSoundEventPacket{
                .event = .chest_closed,
                .position = .{
                    .x = @floatFromInt(position.x),
                    .y = @floatFromInt(position.y),
                    .z = @floatFromInt(position.z),
                },
                .data = perm.network_id,
                .actor_identifier = "",
                .is_baby_mob = false,
                .is_global = false,
            };
            const serialized = sound_packet.serialize(&s) catch continue;
            network.sendPacket(p.connection, serialized) catch {};
        }
    }
}

fn sendBarrelClose(network: *NetworkHandler, block: *@import("../../world/block/block.zig").Block, position: Protocol.BlockPosition) void {
    const BlockType = @import("../../world/block/block-type.zig").BlockType;
    const BlockState = @import("../../world/block/block-permutation.zig").BlockState;

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

    const snapshots = network.conduit.getPlayerSnapshots();
    const network_id: u32 = @bitCast(new_perm.network_id);
    for (snapshots) |p| {
        if (!p.spawned) continue;
        {
            var s = BinaryStream.init(network.allocator, null, null);
            defer s.deinit();
            const update = Protocol.UpdateBlockPacket{
                .position = position,
                .network_block_id = network_id,
            };
            const serialized = update.serialize(&s) catch continue;
            network.sendPacket(p.connection, serialized) catch {};
        }
        {
            var s = BinaryStream.init(network.allocator, null, null);
            defer s.deinit();
            const sound = Protocol.LevelSoundEventPacket{
                .event = .block_barrel_close,
                .position = .{
                    .x = @floatFromInt(position.x),
                    .y = @floatFromInt(position.y),
                    .z = @floatFromInt(position.z),
                },
                .data = new_perm.network_id,
                .actor_identifier = "",
                .is_baby_mob = false,
                .is_global = false,
            };
            const serialized = sound.serialize(&s) catch continue;
            network.sendPacket(p.connection, serialized) catch {};
        }
    }
}
