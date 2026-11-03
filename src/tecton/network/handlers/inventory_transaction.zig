const std = @import("std");
const log = @import("../../core/log.zig");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const transport = @import("../../transport/root.zig");

const inventory = @import("../../entity/traits/inventory.zig");
const InventoryTrait = inventory.InventoryTrait;
const Fire = @import("../../entity/traits/fire.zig");
const Health = @import("../../entity/traits/health.zig");
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const ArmorAggregate = @import("../../items/enchantments/compat.zig").ArmorAggregate;
const Container = @import("../../container/container.zig").Container;
const Events = @import("../../events/types.zig");
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const entities = @import("../../world/dimension/entities.zig");
const broadcast = @import("../../world/dimension/broadcast.zig");
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;
const resolveWithPlacement = @import("../../world/block/traits/rotation.zig").resolveWithPlacement;
const placeUpperBlock = @import("../../world/block/traits/rotation.zig").placeUpperBlock;
const applyTraitsForBlock = @import("../../world/block/traits/trait.zig").applyTraitsForBlock;
const applyTraitsFromRegistry = @import("../../world/block/traits/trait.zig").applyTraitsFromRegistry;
const bow = @import("./bow.zig");
const plugin_gate = @import("./plugin_gate.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;

pub fn handleInventoryTransaction(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *transport.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    const packet = Protocol.InventoryTransactionPacket.deserialize(stream) catch |err| {
        var hex: [384]u8 = undefined;
        var pos: usize = 0;
        const raw = stream.getBuffer();
        for (raw[0..@min(raw.len, 128)]) |b| {
            const written = std.fmt.bufPrint(hex[pos..], "{x:0>2} ", .{b}) catch break;
            pos += written.len;
        }
        log.err(
            "InventoryTransaction deserialize failed: {any} (len={d}, offset={d}) hex: {s}",
            .{ err, raw.len, stream.offset, hex[0..pos] },
        );
        return;
    };

    switch (packet.transaction_type) {
        .Normal => {
            const data = packet.transaction_data.normal;
            if (!data.is_drop or data.drop_count == 0) return;

            const dimension = player.entity.dimension orelse return;
            const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;
            const item = inv_state.container.base.getItem(inv_state.selected_slot) orelse return;
            const count = @min(if (data.drop_count == 0) @as(u16, 1) else data.drop_count, item.stack_size);
            const dropped = item.cloneWithCount(player.entity.allocator, count) catch return;

            const throw_vel = PlayerMath.playerDropVelocity(player.entity.rotation);
            const spawn_pos = PlayerMath.playerDropSpawnPosition(player.entity.position);
            _ = entities.spawnItemStackEntity(dimension, dropped, spawn_pos, 40, throw_vel) catch return;

            inv_state.container.base.removeItem(inv_state.selected_slot, count);
            inv_state.container.updateSlot(inv_state.selected_slot);
        },
        .UseItem => {
            const data = packet.transaction_data.use_item;
            try handleUseItem(tecton, network, player, data);
        },
        .UseItemOnEntity => {
            const data = packet.transaction_data.use_item_on_entity;
            const dimension = player.entity.dimension orelse return;
            if (data.action_type == 0) {
                const target = dimension.getEntity(@bitCast(data.target_entity_runtime_id)) orelse return;
                _ = target.fireEvent(.Interact, .{ target, player });
                return;
            }

            if (data.action_type == 1) {
                const runtime_id: i64 = @bitCast(data.target_entity_runtime_id);
                if (runtime_id == player.entity.runtime_id) return;

                if (@import("../../ecs/combat.zig").attackEcsTarget(tecton, player, dimension, runtime_id)) return;

                const victim = tecton.findPlayerByRuntimeId(runtime_id);
                if (victim) |other| {
                    if (other.entity.dimension != dimension) return;
                    if (!PlayerMath.damageable(other.gamemode)) return;
                }
                const target = if (victim) |other|
                    &other.entity
                else
                    (dimension.getEntity(runtime_id) orelse return);

                if (!PlayerMath.withinAttackReach(player.entity.position, target.position)) return;

                if (target.getTraitState(Health.HealthTrait)) |health_state| {
                    if (Health.isInvulnerable(health_state, tecton.tick_count)) return;
                }

                const inv_state = player.entity.getTraitState(InventoryTrait);
                const weapon = if (inv_state) |state| inventory.getHeldItem(state) else null;
                const impact = EnchantmentEffects.meleeImpact(weapon, target.entity_type.identifier);

                var armor: ArmorAggregate = .empty;
                var worn: ?*Container = null;
                if (target.getTraitState(InventoryTrait)) |victim_inventory| {
                    if (victim_inventory.armor) |*pieces| {
                        armor.refresh(pieces);
                        worn = pieces;
                    }
                }

                var damage_event = Events.DamageEvent{
                    .attacker = &player.entity,
                    .victim = target,
                    .amount = EnchantmentEffects.mitigate(&armor, .entity_attack, impact.damage),
                    .cause = .entity_attack,
                };
                if (!tecton.events.emit(.Damage, &damage_event)) return;

                if (inv_state) |state| {
                    if (state.container.base.getItemMut(state.selected_slot)) |held| {
                        var wear_entropy: std.Random.IoSource = .{ .io = tecton.io };
                        if (EnchantmentEffects.wearTool(held, 1, wear_entropy.interface()) > 0) {
                            state.container.updateSlot(state.selected_slot);
                        }
                    }
                }

                const dx = target.position.x - player.entity.position.x;
                const dz = target.position.z - player.entity.position.z;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist > 0.001) {
                    const kb_strength = impact.knockback;
                    target.motion.x = (dx / dist) * kb_strength;
                    target.motion.y = 0.3;
                    target.motion.z = (dz / dist) * kb_strength;

                    broadcastMotion(network, target);
                }

                if (worn) |pieces| {
                    if (PlayerMath.damageable(player.gamemode)) {
                        const attacker_state = player.entity.getTraitState(Health.HealthTrait);
                        const window_open = if (attacker_state) |state|
                            Health.isInvulnerable(state, tecton.tick_count)
                        else
                            false;
                        if (!window_open) {
                            var entropy: std.Random.IoSource = .{ .io = tecton.io };
                            const reflected = EnchantmentEffects.thornsReflection(pieces, entropy.interface());
                            if (reflected > 0) {
                                var thorns_event = Events.DamageEvent{
                                    .attacker = target,
                                    .victim = &player.entity,
                                    .amount = reflected,
                                    .cause = .entity_attack,
                                };
                                if (tecton.events.emit(.Damage, &thorns_event)) {
                                    player.entity.fireEvent(.Damage, .{ &player.entity, thorns_event.amount });
                                }
                            }
                        }
                    }
                }

                const burn_ticks = EnchantmentEffects.fireAspectDurationTicks(weapon);
                if (burn_ticks > 0) {
                    _ = Fire.ignite(target, .fire_aspect, &player.entity, burn_ticks);
                }

                target.fireEvent(.Damage, .{ target, damage_event.amount });
            }
        },
        .ReleaseItem => {
            const data = packet.transaction_data.release_item;
            if (data.action_type != @intFromEnum(Protocol.ReleaseItemAction.Release)) return;
            _ = bow.release(tecton, player);
        },
        else => {
            log.warn("Unhandled InventoryTransaction from {s}: {any}", .{
                player.username,
                packet.transaction_type,
            });
        },
    }
}

fn handleUseItem(
    tecton: *Tecton,
    network: *NetworkHandler,
    player: *Player,
    data: Protocol.InventoryTransactionData.UseItemTransactionData,
) !void {
    if (data.action_type == 1) {
        if (bow.isHoldingBow(player)) {
            bow.startDraw(tecton, player);
            return;
        }
        bow.cancelDraw(player);

        const equip_state = player.entity.getTraitState(InventoryTrait) orelse return;
        _ = inventory.equipFromSlot(network, player, equip_state, equip_state.selected_slot);
        return;
    }

    if (data.action_type != 0) return;

    const dimension = player.entity.dimension orelse return;

    if (!player.entity.flags.getFlag(.Sneaking)) {
        if (dimension.getBlockPtr(data.block_position)) |clicked_block| {
            if (!clicked_block.fireEvent(.Interact, .{ clicked_block, player })) {
                return;
            }
        } else {
            if (dimension.getChunk(data.block_position.x >> 4, data.block_position.z >> 4)) |chunk| {
                dimension.world.provider.readBlockEntities(chunk, dimension) catch {};
                if (dimension.getBlockPtr(data.block_position)) |loaded_block| {
                    if (!loaded_block.fireEvent(.Interact, .{ loaded_block, player })) {
                        return;
                    }
                }
            }

            var temp_block = dimension.getBlock(data.block_position);
            applyTraitsFromRegistry(player.entity.allocator, &temp_block) catch {};
            if (temp_block.traits.items.len > 0) {
                const result = temp_block.fireEvent(.Interact, .{ &temp_block, player });
                for (temp_block.traits.items) |instance| {
                    if (instance.vtable.destroy_fn) |f| f(instance.ctx, player.entity.allocator);
                }
                temp_block.traits.deinit(player.entity.allocator);
                if (!result) return;
            }
        }
    }

    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return;
    const held = inventory.getHeldItem(inv_state) orelse return;

    const identifier = held.item_type.identifier;
    if (plugin_gate.itemUseDenied(tecton, player, identifier)) return;
    const base_permutation = BlockPermutation.resolve(player.entity.allocator, identifier, null) catch return;

    if (std.mem.eql(u8, base_permutation.identifier, "minecraft:air")) return;

    const permutation = resolveWithPlacement(player.entity.allocator, base_permutation, .{
        .yaw = player.entity.rotation.y,
        .pitch = player.entity.rotation.x,
        .block_face = data.block_face,
        .clicked_position = data.clicked_position,
    });

    const face = data.block_face;
    const pos = Protocol.BlockPosition{
        .x = data.block_position.x + if (face == 5) @as(i32, 1) else if (face == 4) @as(i32, -1) else @as(i32, 0),
        .y = data.block_position.y + if (face == 1) @as(i32, 1) else if (face == 0) @as(i32, -1) else @as(i32, 0),
        .z = data.block_position.z + if (face == 3) @as(i32, 1) else if (face == 2) @as(i32, -1) else @as(i32, 0),
    };

    var block = dimension.getBlock(pos);
    if (!block.fireEvent(.Place, .{ &block, player })) return;

    if (plugin_gate.blockPlaceDenied(tecton, player, pos, permutation)) return;

    try dimension.setPermutation(pos, permutation, 0);
    try applyTraitsForBlock(player.entity.allocator, dimension, pos);
    try placeUpperBlock(player.entity.allocator, dimension, pos, permutation);

    if (player.gamemode != .Creative) {
        inv_state.container.base.removeItem(inv_state.selected_slot, 1);
    }

    const network_id: u32 = @bitCast(permutation.network_id);
    var s = BinaryStream.init(network.allocator, null, null);
    defer s.deinit();
    const update = Protocol.UpdateBlockPacket{
        .position = pos,
        .network_block_id = network_id,
    };
    const serialized = try update.serialize(&s);
    broadcast.broadcastBlockUpdateToViewersExcept(dimension, pos, player, serialized);
}

test "a canceled block place leaves the target empty and the stack intact on the inventory route" {
    const allocator = std.testing.allocator;
    const RootEvents = @import("../../events/root.zig");
    const PluginRuntime = @import("../../plugins/runtime.zig").PluginRuntime;
    const abi = @import("../../plugins/abi.zig");
    const Entity = @import("../../entity/entity.zig").Entity;
    const EntityType = @import("../../entity/entity_type.zig").EntityType;
    const World = @import("../../world/world.zig").World;
    const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
    const ItemStack = @import("../../items/item_stack.zig").ItemStack;
    const ItemType = @import("../../items/item_type.zig").ItemType;
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
    var network: NetworkHandler = undefined;
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

    const data = Protocol.InventoryTransactionData.UseItemTransactionData{
        .action_type = 0,
        .trigger_type = 0,
        .block_position = .{ .x = 0, .y = 64, .z = 0 },
        .block_face = 1,
        .hot_bar_slot = 0,
        .hand = 0,
        .position = Protocol.Vector3f.init(0, 0, 0),
        .clicked_position = Protocol.Vector3f.init(0, 0, 0),
        .block_runtime_id = 0,
        .client_prediction = 0,
        .client_cooldown_state = 0,
    };
    try handleUseItem(&tecton, &network, &player, data);

    const held = state.container.base.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), held.stack_size);
    try std.testing.expectEqual(@as(usize, 0), dimension.chunks.count());
    try std.testing.expectEqualStrings("minecraft:air", (try dimension.getPermutation(.{ .x = 0, .y = 65, .z = 0 }, 0)).identifier);
}

test "a canceled item use leaves the stack and world untouched on the inventory route" {
    const allocator = std.testing.allocator;
    const RootEvents = @import("../../events/root.zig");
    const PluginRuntime = @import("../../plugins/runtime.zig").PluginRuntime;
    const abi = @import("../../plugins/abi.zig");
    const Entity = @import("../../entity/entity.zig").Entity;
    const EntityType = @import("../../entity/entity_type.zig").EntityType;
    const World = @import("../../world/world.zig").World;
    const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
    const ItemStack = @import("../../items/item_stack.zig").ItemStack;
    const ItemType = @import("../../items/item_type.zig").ItemType;

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

    const data = Protocol.InventoryTransactionData.UseItemTransactionData{
        .action_type = 0,
        .trigger_type = 0,
        .block_position = .{ .x = 0, .y = 64, .z = 0 },
        .block_face = 1,
        .hot_bar_slot = 0,
        .hand = 0,
        .position = Protocol.Vector3f.init(0, 0, 0),
        .clicked_position = Protocol.Vector3f.init(0, 0, 0),
        .block_runtime_id = 0,
        .client_prediction = 0,
        .client_cooldown_state = 0,
    };
    try handleUseItem(&tecton, &network, &player, data);

    const held = state.container.base.getItem(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 5), held.stack_size);
    try std.testing.expectEqual(@as(usize, 0), dimension.chunks.count());
}

fn broadcastMotion(network: *NetworkHandler, entity: *const @import("../../entity/entity.zig").Entity) void {
    const allocator = network.allocator;
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const motion_packet = Protocol.SetActorMotionPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .motion = entity.motion,
    };
    const serialized = motion_packet.serialize(&stream) catch return;

    broadcast.broadcastToEntityViewers(entity.dimension orelse return, entity, serialized);
}
