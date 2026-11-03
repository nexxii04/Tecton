const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const transport = @import("../../transport/root.zig");

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
const bow = @import("./bow.zig");
const processItemStackRequest = @import("./item_stack_request.zig").processItemStackRequest;
const plugin_gate = @import("./plugin_gate.zig");

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
    connection: *transport.Connection,
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
    player.entity.head_yaw = packet.rotation.z;
    if (player.entity.dimension) |dim| {
        @import("../../ecs/players.zig").writePlayerTransform(
            dim,
            player.entity.runtime_id,
            &player.entity,
            move_event.to,
            Protocol.Vector2f.init(packet.rotation.x, packet.rotation.y),
            Protocol.Vector3f.init(packet.motion.x, 0, packet.motion.y),
        );
    } else {
        player.entity.position = move_event.to;
        player.entity.rotation.x = packet.rotation.x;
        player.entity.rotation.y = packet.rotation.y;
        player.entity.motion = .{ .x = packet.motion.x, .y = 0, .z = packet.motion.y };
    }

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
        if (bow.isHoldingBow(player)) {
            bow.startDraw(tecton, player);
            return;
        }
        bow.cancelDraw(player);

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
    if (plugin_gate.itemUseDenied(tecton, player, identifier)) return;
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
    if (!block.fireEvent(.Place, .{ &block, player })) {
        correctPlacement(network, player, dimension, pos);
        return;
    }

    if (plugin_gate.blockPlaceDenied(tecton, player, pos, permutation)) {
        correctPlacement(network, player, dimension, pos);
        return;
    }

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
                    for (break_event.getDrops()) |drop| {
                        const drop_item_type = ItemType.get(drop.identifier) orelse continue;
                        _ = entities.spawnItemEntity(dimension, drop_item_type, drop.count, spawn_pos, 10, Protocol.Vector3f.init(0, 0.25, 0)) catch continue;
                    }
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

test "a canceled block place leaves the target empty and the stack intact on the auth input route" {
    const allocator = std.testing.allocator;
    const RootEvents = @import("../../events/root.zig");
    const PluginRuntime = @import("../../plugins/runtime.zig").PluginRuntime;
    const abi = @import("../../plugins/abi.zig");
    const Entity = @import("../../entity/entity.zig").Entity;
    const EntityType = @import("../../entity/entity_type.zig").EntityType;
    const World = @import("../../world/world.zig").World;
    const ItemStack = @import("../../items/item_stack.zig").ItemStack;
    const block_permutation_mod = @import("../../world/block/block_permutation.zig");
    const BlockType = @import("../../world/block/block_type.zig").BlockType;
    const BlockPerm = block_permutation_mod.BlockPermutation;
    const BlockState = block_permutation_mod.BlockState;

    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();
    const stone = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:stone"),
        77,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try stone.register();

    try BlockPerm.initRegistry(allocator);
    defer BlockPerm.deinitRegistry();
    try BlockType.initRegistry(allocator);
    defer BlockType.deinitRegistry();
    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air_block = try BlockPerm.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
    try air_block.register();
    try air_type.addPermutation(air_block);
    const stone_type = try BlockType.init(allocator, "minecraft:stone");
    try stone_type.register();
    const stone_block = try BlockPerm.init(allocator, 1, "minecraft:stone", BlockState.init(allocator));
    try stone_block.register();
    try stone_type.addPermutation(stone_block);

    var events = RootEvents.Events.init(allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1, .state = .running };

    const Cancel = struct {
        fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
            view.result.* = @intFromEnum(abi.EventResult.cancel);
        }
    };
    var subscription: u64 = 0;
    try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.block_place), abi.event_phase_pre, 0, Cancel.callback, null, &subscription));

    var tecton: Tecton = undefined;
    tecton.events = events;

    const ScratchBuffer = @import("../../transport/scratch.zig").ScratchBuffer;
    var network: NetworkHandler = undefined;
    network.allocator = allocator;
    network.port = null;
    network.options = .{ .compression_method = .NotPresent, .compression_threshold = 255 };
    network.send_buffers = .empty;
    network.scratch = ScratchBuffer.init(allocator);
    defer network.scratch.deinit();
    network.outbound_dropped = .init(0);
    network.oversize_sends = .init(0);
    network.backpressure_sends = .init(0);

    const Chunk = @import("../../world/chunk/chunk.zig").Chunk;
    const WorldProvider = @import("../../world/provider/world_provider.zig").WorldProvider;
    const TestProvider = struct {
        fn readChunk(_: *anyopaque, x: i32, z: i32, dimension: *Dimension) anyerror!*Chunk {
            const chunk = try dimension.allocator.create(Chunk);
            chunk.* = Chunk.init(dimension.allocator, x, z, dimension.dimension_type);
            return chunk;
        }

        fn writeChunk(_: *anyopaque, _: *Chunk, _: *Dimension) anyerror!void {}
        fn readBuffer(_: *anyopaque, _: []const u8) anyerror!?[]const u8 {
            return null;
        }
        fn writeBuffer(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn deinit(_: *anyopaque) void {}

        const vtable = WorldProvider.VTable{
            .read_chunk = readChunk,
            .read_chunk_direct = null,
            .read_chunk_column = null,
            .read_chunk_block_entity_data = null,
            .write_chunk = writeChunk,
            .uncache_chunk = null,
            .read_buffer = readBuffer,
            .write_buffer = writeBuffer,
            .write_player = null,
            .read_player = null,
            .write_chunk_entities = null,
            .read_chunk_entities = null,
            .write_block_entities = null,
            .read_block_entities = null,
            .deinit_fn = deinit,
        };
    };
    var provider_context: u8 = 0;
    var world: World = undefined;
    world.provider = .{ .ptr = &provider_context, .vtable = &TestProvider.vtable };
    var dimension = Dimension.init(&world, allocator, "overworld", .Overworld, null);
    defer dimension.deinit();

    const player_type = EntityType.init("minecraft:player", 1, &.{}, &.{});
    var player: Player = undefined;
    player.entity = Entity.init(allocator, &player_type, &dimension);
    player.entity.flags.setFlag(.Sneaking, true);
    player.gamemode = .Survival;
    defer player.entity.deinit();

    try player.entity.addTrait(try InventoryTrait.create(allocator, .{ .container = undefined, .selected_slot = 0, .opened = false }));
    const state = player.entity.getTraitState(InventoryTrait) orelse return error.TestUnexpectedResult;
    state.container.base.setItem(0, ItemStack.init(allocator, stone, .{ .stack_size = 5 }));

    const transaction = Protocol.ItemUseTransaction{
        .legacy_request_id = 0,
        .action_type = 0,
        .trigger_type = 0,
        .block_position = .{ .x = 0, .y = 64, .z = 0 },
        .block_face = 1,
        .hot_bar_slot = 0,
        .item_in_hand = undefined,
        .position = Protocol.Vector3f.init(0, 0, 0),
        .clicked_position = Protocol.Vector3f.init(0, 0, 0),
        .block_runtime_id = 0,
        .client_prediction = 0,
    };
    try handleItemUseTransaction(&tecton, &network, &player, transaction);

    const held = state.container.base.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), held.stack_size);
    try std.testing.expectEqualStrings("minecraft:air", (try dimension.getPermutation(.{ .x = 0, .y = 65, .z = 0 }, 0)).identifier);
}

test "a canceled item use leaves the stack and world untouched on the auth input route" {
    const allocator = std.testing.allocator;
    const RootEvents = @import("../../events/root.zig");
    const PluginRuntime = @import("../../plugins/runtime.zig").PluginRuntime;
    const abi = @import("../../plugins/abi.zig");
    const Entity = @import("../../entity/entity.zig").Entity;
    const EntityType = @import("../../entity/entity_type.zig").EntityType;
    const World = @import("../../world/world.zig").World;
    const ItemStack = @import("../../items/item_stack.zig").ItemStack;

    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();
    const stone = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:stone"),
        77,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    try stone.register();

    var events = RootEvents.Events.init(allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1, .state = .running };

    const Cancel = struct {
        fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
            view.result.* = @intFromEnum(abi.EventResult.cancel);
        }
    };
    var subscription: u64 = 0;
    try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.item_use), abi.event_phase_pre, 0, Cancel.callback, null, &subscription));

    var tecton: Tecton = undefined;
    tecton.events = events;
    var network: NetworkHandler = undefined;
    var world: World = undefined;
    var dimension = Dimension.init(&world, allocator, "overworld", .Overworld, null);
    defer dimension.deinit();

    const player_type = EntityType.init("minecraft:player", 1, &.{}, &.{});
    var player: Player = undefined;
    player.entity = Entity.init(allocator, &player_type, &dimension);
    defer player.entity.deinit();

    try player.entity.addTrait(try InventoryTrait.create(allocator, .{ .container = undefined, .selected_slot = 0, .opened = false }));
    const state = player.entity.getTraitState(InventoryTrait) orelse return error.TestUnexpectedResult;
    state.container.base.setItem(0, ItemStack.init(allocator, stone, .{ .stack_size = 5 }));

    const transaction = Protocol.ItemUseTransaction{
        .legacy_request_id = 0,
        .action_type = 0,
        .trigger_type = 0,
        .block_position = .{ .x = 0, .y = 64, .z = 0 },
        .block_face = 1,
        .hot_bar_slot = 0,
        .item_in_hand = undefined,
        .position = Protocol.Vector3f.init(0, 0, 0),
        .clicked_position = Protocol.Vector3f.init(0, 0, 0),
        .block_runtime_id = 0,
        .client_prediction = 0,
    };
    try handleItemUseTransaction(&tecton, &network, &player, transaction);

    const held = state.container.base.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), held.stack_size);
    try std.testing.expectEqual(@as(usize, 0), dimension.chunks.count());
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

fn correctPlacement(network: *NetworkHandler, player: *Player, dimension: *Dimension, pos: Protocol.BlockPosition) void {
    const perm = dimension.getPermutation(pos, 0) catch return;
    sendBlockCorrection(network, player, pos, @bitCast(perm.network_id));
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
