const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const InventoryTrait = @import("../../entity/traits/inventory.zig");
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item-type.zig").ItemType;
const Player = @import("../../player/player.zig").Player;
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;
const BreakSpeed = @import("../../world/block/break-speed.zig").BreakSpeed;
const resolveWithPlacement = @import("../../world/block/traits/rotation.zig").resolveWithPlacement;
const PlacementContext = @import("../../world/block/traits/rotation.zig").PlacementContext;
const placeUpperBlock = @import("../../world/block/traits/rotation.zig").placeUpperBlock;
const applyTraitsForBlock = @import("../../world/block/traits/trait.zig").applyTraitsForBlock;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const processItemStackRequest = @import("./item-stack-request.zig").processItemStackRequest;

/// Converts a rotation in degrees to the signed byte format used by
/// MoveActorDelta (256 steps across a full 360° turn).
fn rotationToByte(degrees: f32) i8 {
    const normalized = @mod(degrees, 360.0);
    const steps: u32 = @intFromFloat(normalized / 360.0 * 256.0);
    return @bitCast(@as(u8, @truncate(steps)));
}

pub fn handlePlayerAuthInput(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
    const packet = try Protocol.PlayerAuthInputPacket.deserialize(stream, network.allocator);

    const previous_position = player.entity.position;
    var move_event = Events.PlayerMoveEvent{
        .player = player,
        .from = previous_position,
        .to = packet.position,
    };
    if (!network.conduit.events.emit(.PlayerMove, &move_event)) return;
    player.entity.position = move_event.to;
    player.entity.rotation.x = packet.rotation.x;
    player.entity.rotation.y = packet.rotation.y;
    player.entity.motion = .{ .x = packet.motion.x, .y = 0, .z = packet.motion.y };
    player.entity.head_yaw = packet.rotation.z;
    network.conduit.syncEcsEntity(&player.entity);

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

    if (packet.item_stack_request) |request| {
        try processItemStackRequest(network, connection, request);
    }

    if (packet.input_data.hasFlag(.PerformBlockActions)) {
        for (packet.getBlockActions()) |action| {
            try handleBlockAction(network, player, action);
        }
    }

    network.scratch_stream.reset();

    const move_packet = Protocol.MoveActorDeltaPacket{
        .runtime_id = @intCast(player.entity.runtime_id),
        .x = player.entity.position.x,
        .y = player.entity.position.y,
        .z = player.entity.position.z,
        .rotation_x = rotationToByte(player.entity.rotation.x),
        .rotation_y = rotationToByte(player.entity.rotation.y),
        .rotation_y_head = rotationToByte(player.entity.head_yaw),
        .on_ground = true,
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
    if (transaction.action_type != 0) {
        return;
    }

    const dimension = player.entity.dimension orelse return;

    const inv_state = player.entity.getTraitState(InventoryTrait.InventoryTrait) orelse return;
    const held = InventoryTrait.getHeldItem(inv_state) orelse return;

    const identifier = held.item_type.identifier;
    if (std.mem.eql(u8, identifier, "minecraft:firework_rocket")) {
        var item_use_event = Events.ItemUseEvent{ .player = player, .identifier = identifier };
        if (!network.conduit.events.emit(.ItemUse, &item_use_event)) return;
    }
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

        dimension.broadcastBlockUpdateToViewersExcept(pos, player, serialized);
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
            if (player.gamemode == .Creative) return;

            if (player.block_target) |target| {
                if (target.eql(action.block_pos)) return;
                broadcastLevelEvent(dimension, network, .StopBlockCracking, target.toVector3f(), 0);
            }

            const perm = dimension.getPermutation(action.block_pos, 0) catch return;
            if (std.mem.eql(u8, perm.identifier, "minecraft:air")) return;

            player.block_target = action.block_pos;

            if (BreakSpeed.startBreakData(perm.identifier)) |data| {
                broadcastLevelEvent(dimension, network, .StartBlockCracking, action.block_pos.toVector3f(), data);
            }
        },
        .CrackBreak => {
            // The breaker's periodic crack tick: keep the target in sync but do
            // not re-emit START, which would reset the crack animation.
            player.block_target = action.block_pos;
        },
        .AbortBreak, .StopBreak => {
            if (player.block_target) |target| {
                broadcastLevelEvent(dimension, network, .StopBlockCracking, target.toVector3f(), 0);
                player.block_target = null;
            }
        },
        .PredictDestroyBlock, .CreativePlayerDestroyBlock => {
            if (player.block_target) |target| {
                broadcastLevelEvent(dimension, network, .StopBlockCracking, target.toVector3f(), 0);
            }
            player.block_target = null;

            const pos = action.block_pos;
            const perm = dimension.getPermutation(pos, 0) catch return;
            if (std.mem.eql(u8, perm.identifier, "minecraft:air")) {
                const air = BlockPermutation.resolve(player.entity.allocator, "minecraft:air", null) catch return;
                sendBlockCorrection(network, player, pos, @bitCast(air.network_id));
                return;
            }

            const default_drop = [_]Events.ItemDrop{.{ .identifier = perm.identifier, .count = 1 }};
            var break_event = Events.BlockBreakEvent{
                .player = player,
                .position = pos,
                .permutation = perm,
                .drops = if (player.gamemode != .Creative) &default_drop else null,
            };
            if (!network.conduit.events.emit(.BlockBreak, &break_event)) {
                // The server refused the break; tell the breaker the truth so
                // its client reverts the predicted destruction.
                sendBlockCorrection(network, player, pos, @bitCast(perm.network_id));
                return;
            }

            if (dimension.getBlockPtr(pos)) |block| {
                _ = block.fireEvent(.Break, .{ block, player });
                dimension.removeBlock(pos);
            }

            const air = BlockPermutation.resolve(player.entity.allocator, "minecraft:air", null) catch return;
            try dimension.setPermutation(pos, air, 0);

            if (player.gamemode != .Creative) {
                if (break_event.getDrops().len > 0) {
                    const spawn_pos = centered(pos);
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

            //std.debug.print("[breakdbg] auth destroy: burst 2001 for ({d},{d},{d}) gamemode={any}\n", .{ pos.x, pos.y, pos.z, player.gamemode });
            broadcastLevelEvent(dimension, network, .ParticlesDestroyBlock, centered(pos), @bitCast(perm.network_id));

            {
                network.scratch_stream.reset();
                const update = Protocol.UpdateBlockPacket{
                    .position = pos,
                    .network_block_id = @bitCast(air.network_id),
                };
                const serialized = try update.serialize(&network.scratch_stream);
                dimension.broadcastBlockUpdateToViewers(pos, serialized);
            }
        },
        else => {},
    }
}

fn centered(pos: Protocol.BlockPosition) Protocol.Vector3f {
    return Protocol.Vector3f.init(
        @as(f32, @floatFromInt(pos.x)) + 0.5,
        @as(f32, @floatFromInt(pos.y)) + 0.5,
        @as(f32, @floatFromInt(pos.z)) + 0.5,
    );
}

fn sendBlockCorrection(network: *NetworkHandler, player: *Player, pos: Protocol.BlockPosition, network_block_id: u32) void {
    network.scratch_stream.reset();
    const update = Protocol.UpdateBlockPacket{
        .position = pos,
        .network_block_id = network_block_id,
    };
    const serialized = update.serialize(&network.scratch_stream) catch return;
    network.sendPacket(player.connection, serialized) catch {};
}

fn broadcastLevelEvent(dimension: *Dimension, network: *NetworkHandler, event: Protocol.LevelEvent, position: Protocol.Vector3f, data: i32) void {
    network.scratch_stream.reset();
    const pkt = Protocol.LevelEventPacket{
        .event = event,
        .position = position,
        .data = data,
    };
    const serialized = pkt.serialize(&network.scratch_stream) catch return;
    dimension.broadcastToNearby(position, Dimension.PARTICLE_BROADCAST_RADIUS, serialized);
}
