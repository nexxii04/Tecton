const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const InventoryTrait = @import("../../entity/traits/inventory.zig");
const Events = @import("../../events/types.zig");
const Player = @import("../../player/player.zig").Player;
const PlayerMath = @import("../../player/player.zig");
const BlockPermutation = @import("../../world/block/block-permutation.zig").BlockPermutation;
const resolveWithPlacement = @import("../../world/block/traits/rotation.zig").resolveWithPlacement;
const placeUpperBlock = @import("../../world/block/traits/rotation.zig").placeUpperBlock;
const applyTraitsForBlock = @import("../../world/block/traits/trait.zig").applyTraitsForBlock;
const applyTraitsFromRegistry = @import("../../world/block/traits/trait.zig").applyTraitsFromRegistry;
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;

pub fn handleInventoryTransaction(
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = network.conduit.getPlayerByConnection(connection) orelse return;
    const packet = Protocol.InventoryTransactionPacket.deserialize(stream) catch |err| {
        var hex: [384]u8 = undefined;
        var pos: usize = 0;
        const raw = stream.getBuffer();
        for (raw[0..@min(raw.len, 128)]) |b| {
            const written = std.fmt.bufPrint(hex[pos..], "{x:0>2} ", .{b}) catch break;
            pos += written.len;
        }
        Raknet.Logger.ERROR(
            "InventoryTransaction deserialize failed: {any} (len={d}, offset={d}) hex: {s}",
            .{ err, raw.len, stream.offset, hex[0..pos] },
        );
        return;
    };
    // Raknet.Logger.WARN("{any}", .{packet});

    switch (packet.transaction_type) {
        .Normal => {
            const data = packet.transaction_data.normal;
            if (!data.is_drop or data.drop_count == 0) return;

            const dimension = player.entity.dimension orelse return;
            const inv_state = player.entity.getTraitState(InventoryTrait.InventoryTrait) orelse return;
            const item = inv_state.container.base.getItem(inv_state.selected_slot) orelse return;
            const count = @min(if (data.drop_count == 0) @as(u16, 1) else data.drop_count, item.stack_size);
            const dropped = item.cloneWithCount(player.entity.allocator, count) catch return;

            const throw_vel = PlayerMath.playerDropVelocity(player.entity.rotation);
            const spawn_pos = PlayerMath.playerDropSpawnPosition(player.entity.position);
            _ = dimension.spawnItemStackEntity(dropped, spawn_pos, 40, throw_vel) catch return;

            inv_state.container.base.removeItem(inv_state.selected_slot, count);
            inv_state.container.updateSlot(inv_state.selected_slot);
        },
        .UseItem => {
            const data = packet.transaction_data.use_item;
            try handleUseItem(network, player, data);
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
                const target = dimension.getEntity(@bitCast(data.target_entity_runtime_id)) orelse return;

                const dx = target.position.x - player.entity.position.x;
                const dz = target.position.z - player.entity.position.z;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist > 0.001) {
                    const kb_strength: f32 = 0.3;
                    target.motion.x = (dx / dist) * kb_strength;
                    target.motion.y = 0.3;
                    target.motion.z = (dz / dist) * kb_strength;

                    broadcastMotion(network, target);
                }

                target.fireEvent(.Damage, .{ target, @as(f32, 1.0) });
            }
        },
        else => {
            Raknet.Logger.WARN("Unhandled InventoryTransaction from {s}: {any}", .{
                player.username,
                packet.transaction_type,
            });
        },
    }
}

fn handleUseItem(
    network: *NetworkHandler,
    player: *Player,
    data: Protocol.InventoryTransactionData.UseItemTransactionData,
) !void {
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

    const inv_state = player.entity.getTraitState(InventoryTrait.InventoryTrait) orelse return;
    const held = InventoryTrait.getHeldItem(inv_state) orelse return;

    const identifier = held.item_type.identifier;
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
    var s = BinaryStream.init(network.allocator, null, null);
    defer s.deinit();
    const update = Protocol.UpdateBlockPacket{
        .position = pos,
        .network_block_id = network_id,
    };
    const serialized = try update.serialize(&s);
    dimension.broadcastBlockUpdateToViewersExcept(pos, player, serialized);
}

fn broadcastMotion(network: *NetworkHandler, entity: *const @import("../../entity/entity.zig").Entity) void {
    const allocator = network.conduit.allocator;
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const motion_packet = Protocol.SetActorMotionPacket{
        .runtime_entity_id = @bitCast(entity.runtime_id),
        .motion = entity.motion,
    };
    const serialized = motion_packet.serialize(&stream) catch return;

    (entity.dimension orelse return).broadcastToEntityViewers(entity, serialized);
}
