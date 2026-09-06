const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const MoveDeltaFlags = Protocol.MoveDeltaFlags;
const Raknet = @import("Raknet");

const InventoryTrait = @import("../../entity/traits/inventory.zig");
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item-type.zig").ItemType;
const Player = @import("../../player/player.zig").Player;
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;
const resolveWithPlacement = @import("../../world/block/traits/rotation.zig").resolveWithPlacement;
const PlacementContext = @import("../../world/block/traits/rotation.zig").PlacementContext;
const placeUpperBlock = @import("../../world/block/traits/rotation.zig").placeUpperBlock;
const applyTraitsForBlock = @import("../../world/block/traits/trait.zig").applyTraitsForBlock;
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;

pub fn handlePlayerAuthInput(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
    const packet = try Protocol.PlayerAuthInputPacket.deserialize(stream);

    player.entity.position = packet.position;
    player.entity.rotation = packet.rotation;
    player.entity.motion = .{ .x = packet.motion.x, .y = 0, .z = packet.motion.y };
    player.entity.head_yaw = packet.head_yaw;

    {
        var flags_changed = false;
        if (packet.input_data.hasFlag(.StartSneaking)) {
            player.entity.flags.setFlag(.Sneaking, true);
            flags_changed = true;
        }
        if (packet.input_data.hasFlag(.StopSneaking)) {
            player.entity.flags.setFlag(.Sneaking, false);
            flags_changed = true;
        }
        if (flags_changed) try player.broadcastActorFlags();
    }

    if (packet.input_data.hasFlag(.PerformItemInteraction)) {
        if (packet.item_transaction) |transaction| {
            try handleItemUseTransaction(network, player, transaction);
        }
    }

    if (packet.input_data.hasFlag(.PerformBlockActions)) {
        for (packet.getBlockActions()) |action| {
            try handleBlockAction(network, player, action);
        }
    }

    network.scratch_stream.reset();

    const move_packet = Protocol.MoveActorDeltaPacket{
        .runtime_id = @intCast(player.entity.runtime_id),
        .flags = MoveDeltaFlags.All,
        .x = player.entity.position.x,
        .y = player.entity.position.y,
        .z = player.entity.position.z,
        .pitch = player.entity.rotation.x,
        .yaw = player.entity.rotation.y,
        .head_yaw = player.entity.head_yaw,
    };
    const serialized = try move_packet.serialize(&network.scratch_stream);

    const snapshots = network.conduit.getPlayerSnapshots();
    for (snapshots) |other| {
        if (other.entity.runtime_id == player.entity.runtime_id) continue;
        if (!other.spawned) continue;
        if (!other.visible_players.contains(player.entity.runtime_id)) continue;
        try network.sendPacket(other.connection, serialized);
    }
}

fn handleItemUseTransaction(
    network: *NetworkHandler,
    player: *Player,
    transaction: Protocol.ItemUseTransaction,
) !void {
    if (transaction.action_type != 0) return;

    const dimension = player.entity.dimension orelse return;

    const inv_state = player.entity.getTraitState(InventoryTrait.InventoryTrait) orelse return;
    const held = InventoryTrait.getHeldItem(inv_state) orelse return;

    const identifier = held.item_type.identifier;
    const base_permutation = BlockPermutation.resolve(player.entity.allocator, identifier, null) catch return;

    if (std.mem.eql(u8, base_permutation.identifier, "minecraft:air")) return;

    const permutation = resolveWithPlacement(player.entity.allocator, base_permutation, .{
        .yaw = player.entity.rotation.y,
        .pitch = player.entity.rotation.x,
        .block_face = transaction.block_face,
        .clicked_position = transaction.clicked_position,
    });

    const face = transaction.block_face;
    const pos = Protocol.BlockPosition{
        .x = transaction.block_position.x + if (face == 5) @as(i32, 1) else if (face == 4) @as(i32, -1) else @as(i32, 0),
        .y = transaction.block_position.y + if (face == 1) @as(i32, 1) else if (face == 0) @as(i32, -1) else @as(i32, 0),
        .z = transaction.block_position.z + if (face == 3) @as(i32, 1) else if (face == 2) @as(i32, -1) else @as(i32, 0),
    };

    var block = dimension.getBlock(pos);
    if (!block.fireEvent(.Place, .{ &block, player })) return;

    var place_event = Events.BlockPlaceEvent{
        .player = player,
        .position = pos,
        .permutation = permutation,
    };
    if (!network.conduit.events.emit(.BlockPlace, &place_event)) return;

    try dimension.setPermutation(pos, permutation, 0);
    try applyTraitsForBlock(player.entity.allocator, dimension, pos);
    try placeUpperBlock(player.entity.allocator, dimension, pos, permutation);

    if (player.gamemode != .Creative) {
        inv_state.container.base.removeItem(inv_state.selected_slot, 1);
    }

    const network_id: u32 = @bitCast(permutation.network_id);
    {
        network.scratch_stream.reset();
        const update = Protocol.UpdateBlockPacket{
            .position = pos,
            .network_block_id = network_id,
        };
        const serialized = try update.serialize(&network.scratch_stream);

        const snapshots = network.conduit.getPlayerSnapshots();
        for (snapshots) |p| {
            if (!p.spawned) continue;
            if (p.entity.runtime_id == player.entity.runtime_id) continue;
            try network.sendPacket(p.connection, serialized);
        }
    }
}

fn handleBlockAction(
    network: *NetworkHandler,
    player: *Player,
    action: Protocol.PlayerBlockAction,
) !void {
    const dimension = player.entity.dimension orelse return;

    switch (action.action) {
        .StartBreak, .ContinueDestroyBlock => {
            if (player.block_target) |target| {
                broadcastLevelEvent(network, player, .StopBlockCracking, target.toVector3f(), 0);
                player.block_target = null;
            }

            const perm = dimension.getPermutation(action.block_pos, 0) catch return;
            if (std.mem.eql(u8, perm.identifier, "minecraft:air")) return;

            player.block_target = action.block_pos;

            broadcastLevelEvent(network, player, .StartBlockCracking, action.block_pos.toVector3f(), 65535);
        },
        .AbortBreak => {
            if (player.block_target) |target| {
                broadcastLevelEvent(network, player, .StopBlockCracking, target.toVector3f(), 0);
                player.block_target = null;
            }
        },
        .PredictDestroyBlock, .CreativePlayerDestroyBlock => {
            if (player.block_target) |target| {
                broadcastLevelEvent(network, player, .StopBlockCracking, target.toVector3f(), 0);
            }
            player.block_target = null;

            const pos = action.block_pos;
            const perm = dimension.getPermutation(pos, 0) catch return;
            if (std.mem.eql(u8, perm.identifier, "minecraft:air")) return;

            const default_drop = [_]Events.ItemDrop{.{ .identifier = perm.identifier, .count = 1 }};
            var break_event = Events.BlockBreakEvent{
                .player = player,
                .position = pos,
                .permutation = perm,
                .drops = if (player.gamemode != .Creative) &default_drop else null,
            };
            if (!network.conduit.events.emit(.BlockBreak, &break_event)) return;

            if (dimension.getBlockPtr(pos)) |block| {
                _ = block.fireEvent(.Break, .{ block, player });
                dimension.removeBlock(pos);
            }

            const air = BlockPermutation.resolve(player.entity.allocator, "minecraft:air", null) catch return;
            try dimension.setPermutation(pos, air, 0);

            if (player.gamemode != .Creative) {
                if (break_event.getDrops().len > 0) {
                    const spawn_pos = Protocol.Vector3f.init(
                        @as(f32, @floatFromInt(pos.x)) + 0.5,
                        @as(f32, @floatFromInt(pos.y)) + 0.5,
                        @as(f32, @floatFromInt(pos.z)) + 0.5,
                    );
                    var spawned = std.ArrayList(*@import("../../entity/entity.zig").Entity){ .items = &.{}, .capacity = 0 };
                    defer spawned.deinit(network.allocator);
                    for (break_event.getDrops()) |drop| {
                        const drop_item_type = ItemType.get(drop.identifier) orelse continue;
                        const entity = dimension.spawnItemEntity(drop_item_type, drop.count, spawn_pos, 10, Protocol.Vector3f.init(0, 0.25, 0)) catch continue;
                        spawned.append(network.allocator, entity) catch {};
                    }
                    break_event.entities = spawned.items;
                }
            }

            broadcastLevelEvent(network, player, .ParticlesDestroyBlock, pos.toVector3f(), @bitCast(perm.network_id));

            {
                network.scratch_stream.reset();
                const update = Protocol.UpdateBlockPacket{
                    .position = pos,
                    .network_block_id = @bitCast(air.network_id),
                };
                const serialized = try update.serialize(&network.scratch_stream);
                const snapshots = network.conduit.getPlayerSnapshots();
                for (snapshots) |p| {
                    if (!p.spawned) continue;
                    try network.sendPacket(p.connection, serialized);
                }
            }
        },
        else => {},
    }
}

fn broadcastLevelEvent(network: *NetworkHandler, exclude: *Player, event: Protocol.LevelEvent, position: Protocol.Vector3f, data: i32) void {
    network.scratch_stream.reset();
    const pkt = Protocol.LevelEventPacket{
        .event = event,
        .position = position,
        .data = data,
    };
    const serialized = pkt.serialize(&network.scratch_stream) catch return;
    const snapshots = network.conduit.getPlayerSnapshots();
    for (snapshots) |p| {
        if (!p.spawned) continue;
        if (p.entity.runtime_id == exclude.entity.runtime_id) continue;
        network.sendPacket(p.connection, serialized) catch {};
    }
}
