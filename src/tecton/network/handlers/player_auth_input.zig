const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const inventory = @import("../../entity/traits/inventory.zig");
const InventoryTrait = inventory.InventoryTrait;
const Health = @import("../../entity/traits/health.zig");
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const ArmorAggregate = @import("../../items/enchantments/compat.zig").ArmorAggregate;
const Events = @import("../../events/types.zig");
const ItemType = @import("../../items/item_type.zig").ItemType;
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;
const BreakSpeed = @import("../../world/block/break_speed.zig").BreakSpeed;
const resolveWithPlacement = @import("../../world/block/traits/rotation.zig").resolveWithPlacement;
const PlacementContext = @import("../../world/block/traits/rotation.zig").PlacementContext;
const placeUpperBlock = @import("../../world/block/traits/rotation.zig").placeUpperBlock;
const applyTraitsForBlock = @import("../../world/block/traits/trait.zig").applyTraitsForBlock;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const entities = @import("../../world/dimension/entities.zig");
const broadcast = @import("../../world/dimension/broadcast.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const processItemStackRequest = @import("./item_stack_request.zig").processItemStackRequest;

pub fn handlePlayerBlockAction(
    tecton: *Tecton,
    network: *NetworkHandler,
    player: *Player,
    action: Protocol.PlayerBlockAction,
) !void {
    try handleBlockAction(tecton, network, player, action);
}

pub fn handlePlayerAuthInput(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    var packet = try Protocol.PlayerAuthInputPacket.deserialize(stream, network.allocator);
    defer packet.deinit(network.allocator);

    const previous_position = player.entity.position;
    var move_event = Events.PlayerMoveEvent{
        .player = player,
        .from = previous_position,
        .to = packet.position,
    };
    if (!tecton.events.emit(.PlayerMove, &move_event)) return;
    player.entity.position = move_event.to;
    player.entity.rotation.x = packet.rotation.x;
    player.entity.rotation.y = packet.rotation.y;
    player.entity.motion = .{ .x = packet.motion.x, .y = 0, .z = packet.motion.y };
    player.entity.head_yaw = packet.rotation.z;
    tecton.syncEcsEntity(&player.entity);

    applyFallDamage(tecton, player, previous_position.y, packet.input_data.hasFlag(.VerticalCollision));

    {
        const input = packet.input_data;
        var pose_input = false;

        if (input.hasFlag(.StartSneaking)) {
            player.entity.flags.setFlag(.Sneaking, true);
            pose_input = true;
        }
        if (input.hasFlag(.StopSneaking)) {
            player.entity.flags.setFlag(.Sneaking, false);
            pose_input = true;
        }
        if (applyPoseTransition(input.hasFlag(.StartGliding), input.hasFlag(.StopGliding), &player.gliding)) pose_input = true;
        if (applyPoseTransition(input.hasFlag(.StartSwimming), input.hasFlag(.StopSwimming), &player.swimming)) pose_input = true;
        if (applyPoseTransition(input.hasFlag(.StartCrawling), input.hasFlag(.StopCrawling), &player.crawling)) pose_input = true;

        if (pose_input) try player.updatePose();
    }

    if (packet.input_data.hasFlag(.PerformItemInteraction)) {
        if (packet.item_transaction) |transaction| {
            try handleItemUseTransaction(tecton, network, player, transaction);
        }
    }

    if (packet.item_stack_request) |request| {
        try processItemStackRequest(tecton, network, connection, request);
    }

    if (packet.input_data.hasFlag(.PerformBlockActions)) {
        for (packet.getBlockActions()) |action| {
            try handleBlockAction(tecton, network, player, action);
        }
    }

    player.pending_move = .{
        .position = .{ player.entity.position.x, player.entity.position.y, player.entity.position.z },
        .rotation = .{ player.entity.rotation.x, player.entity.rotation.y, player.entity.head_yaw },
        .on_ground = player.on_ground,
    };
}

fn applyFallDamage(tecton: *Tecton, player: *Player, previous_y: f32, grounded: bool) void {
    const fallen = player.falling_distance;
    player.falling_distance = PlayerMath.trackFall(fallen, previous_y, player.entity.position.y, grounded);

    if (!bodiesLand(grounded, fallen)) return;
    if (!PlayerMath.damageable(player.gamemode)) return;

    const health_state = player.entity.getTraitState(Health.HealthTrait) orelse return;
    if (Health.isInvulnerable(health_state, tecton.tick_count)) return;

    var armor: ArmorAggregate = .empty;
    if (player.entity.getTraitState(InventoryTrait)) |inv_state| {
        if (inv_state.armor) |*pieces| armor.refresh(pieces);
    }

    const amount = EnchantmentEffects.mitigate(&armor, .fall, PlayerMath.fallDamage(fallen));
    if (amount <= 0) return;

    var event = Events.DamageEvent{
        .attacker = null,
        .victim = &player.entity,
        .amount = amount,
        .cause = .fall,
    };
    if (!tecton.events.emit(.Damage, &event)) return;

    player.entity.fireEvent(.Damage, .{ &player.entity, event.amount });
}

pub fn bodiesLand(grounded: bool, fallen: f32) bool {
    return grounded and fallen > 0;
}

test "only a grounded body that fell anything lands" {
    try std.testing.expect(bodiesLand(true, 4.5));
    try std.testing.expect(bodiesLand(true, 0.01));
    try std.testing.expect(!bodiesLand(false, 4.5));
    try std.testing.expect(!bodiesLand(true, 0));
    try std.testing.expect(!bodiesLand(true, -1));
}

fn applyPoseTransition(start: bool, stop: bool, state: *bool) bool {
    if (start) {
        state.* = true;
        return true;
    }
    if (stop) {
        state.* = false;
        return true;
    }
    return false;
}

fn handleItemUseTransaction(
    tecton: *Tecton,
    network: *NetworkHandler,
    player: *Player,
    transaction: Protocol.ItemUseTransaction,
) !void {
    if (transaction.action_type == 1) {
        const equip_state = player.entity.getTraitState(InventoryTrait) orelse return;
        _ = inventory.equipFromSlot(network, player, equip_state, equip_state.selected_slot);
        return;
    }

    if (transaction.action_type != 0) {
        return;
    }

    const dimension = player.entity.dimension orelse return;

    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;
    const held = inventory.getHeldItem(inv_state) orelse return;

    const identifier = held.item_type.identifier;
    if (std.mem.eql(u8, identifier, "minecraft:firework_rocket")) {
        var item_use_event = Events.ItemUseEvent{ .player = player, .identifier = identifier };
        if (!tecton.events.emit(.ItemUse, &item_use_event)) return;
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
    if (!tecton.events.emit(.BlockPlace, &place_event)) return;

    try dimension.setPermutation(pos, permutation, 0);
    try applyTraitsForBlock(player.entity.allocator, dimension, pos);
    try placeUpperBlock(player.entity.allocator, dimension, pos, permutation);

    if (player.gamemode != .Creative) {
        inv_state.container.base.removeItem(inv_state.selected_slot, 1);
    }

    const network_id: u32 = @bitCast(permutation.network_id);
    {
        const scratch = network.scratch.begin();
        defer scratch.deinit();

        const update = Protocol.UpdateBlockPacket{
            .position = pos,
            .network_block_id = network_id,
        };
        const serialized = try update.serialize(scratch.stream());

        broadcast.broadcastBlockUpdateToViewersExcept(dimension, pos, player, serialized);
    }
}

fn handleBlockAction(
    tecton: *Tecton,
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
            if (!tecton.events.emit(.BlockBreak, &break_event)) {
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
                        const entity = entities.spawnItemEntity(dimension, drop_item_type, drop.count, spawn_pos, 10, Protocol.Vector3f.init(0, 0.25, 0)) catch continue;
                        spawned.append(network.allocator, entity) catch {};
                    }
                    break_event.entities = spawned.items;
                }
            }

            broadcastLevelEvent(dimension, network, .ParticlesDestroyBlock, centered(pos), @bitCast(perm.network_id));

            {
                const scratch = network.scratch.begin();
                defer scratch.deinit();

                const update = Protocol.UpdateBlockPacket{
                    .position = pos,
                    .network_block_id = @bitCast(air.network_id),
                };
                const serialized = try update.serialize(scratch.stream());
                broadcast.broadcastBlockUpdateToViewers(dimension, pos, serialized);
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
    const scratch = network.scratch.begin();
    defer scratch.deinit();

    const update = Protocol.UpdateBlockPacket{
        .position = pos,
        .network_block_id = network_block_id,
    };
    const serialized = update.serialize(scratch.stream()) catch return;
    network.sendPacket(player.connection, serialized) catch {};
}

fn broadcastLevelEvent(dimension: *Dimension, network: *NetworkHandler, event: Protocol.LevelEvent, position: Protocol.Vector3f, data: i32) void {
    const scratch = network.scratch.begin();
    defer scratch.deinit();

    const pkt = Protocol.LevelEventPacket{
        .event = event,
        .position = position,
        .data = data,
    };
    const serialized = pkt.serialize(scratch.stream()) catch return;
    broadcast.broadcastToNearby(dimension, position, broadcast.PARTICLE_BROADCAST_RADIUS, serialized);
}
