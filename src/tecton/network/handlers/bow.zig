const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const inventory = @import("../../entity/traits/inventory.zig");
const InventoryTrait = inventory.InventoryTrait;
const Container = @import("../../container/container.zig").Container;
const EnchantmentEffects = @import("../../items/enchantments/effects.zig");
const Bow = @import("../../items/bow.zig");
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const entities = @import("../../world/dimension/entities.zig");
const broadcast = @import("../../world/dimension/broadcast.zig");
const Tecton = @import("../../tecton.zig").Tecton;

pub fn findArrow(container: *const Container) ?u32 {
    var slot: u32 = 0;
    while (slot < container.getSize()) : (slot += 1) {
        const stack = container.getItem(slot) orelse continue;
        if (std.mem.eql(u8, stack.item_type.identifier, Bow.ARROW_IDENTIFIER)) return slot;
    }
    return null;
}

pub fn drawTicks(started: u64, now: u64) u64 {
    if (started == 0 or started > now) return 0;
    return now - started;
}

pub fn isHoldingBow(player: *Player) bool {
    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return false;
    const held = inventory.getHeldItem(inv_state) orelse return false;
    return Bow.isBow(held.item_type.identifier);
}

pub fn startDraw(tecton: *Tecton, player: *Player) void {
    if (!isHoldingBow(player)) return;
    player.item_use_started_tick = tecton.tick_count;
}

pub fn cancelDraw(player: *Player) void {
    player.item_use_started_tick = 0;
}

pub fn arrowSpend(survival: bool, infinite: bool) bool {
    return survival and !infinite;
}

pub fn release(tecton: *Tecton, player: *Player) bool {
    const started = player.item_use_started_tick;
    player.item_use_started_tick = 0;

    const dimension = player.entity.dimension orelse return false;
    const inv_state = player.entity.getTraitState(InventoryTrait) orelse return false;

    const held = inventory.getHeldItem(inv_state) orelse return false;
    if (!Bow.isBow(held.item_type.identifier)) return false;

    const drawn = drawTicks(started, tecton.tick_count);
    if (!Bow.canShoot(drawn)) return false;

    const survival = player.gamemode != .Creative;
    const infinite = EnchantmentEffects.infiniteArrows(held);
    const paid = arrowSpend(survival, infinite);

    var arrow_slot: ?u32 = null;
    if (survival) {
        const available = findArrow(&inv_state.container.base) orelse return false;
        if (paid) arrow_slot = available;
    }

    const speed = Bow.launchSpeed(Bow.chargeAfter(drawn));
    const impact = EnchantmentEffects.arrowImpact(held, Bow.damageFor(speed));
    const critical = Bow.isCritical(drawn);
    const damage = if (critical) Bow.criticalDamage(impact.damage) else impact.damage;
    const spawn_position = Protocol.Vector3f.init(
        player.entity.position.x,
        player.entity.position.y,
        player.entity.position.z,
    );

    const arrow = entities.spawnArrow(dimension, spawn_position, player.entity.rotation, .{
        .owner_runtime_id = player.entity.runtime_id,
        .speed = speed,
        .damage = damage,
        .knockback = impact.knockback,
        .burn_ticks = impact.burn_ticks,
        .pickup_identifier = Bow.ARROW_IDENTIFIER,
        .pickup_allowed = paid,
        .is_critical = critical,
    }) catch return false;

    if (arrow_slot) |slot| inv_state.container.base.removeItem(slot, 1);

    if (survival) {
        if (inv_state.container.base.getItemMut(inv_state.selected_slot)) |bow_stack| {
            var entropy: std.Random.IoSource = .{ .io = tecton.io };
            if (EnchantmentEffects.wearTool(bow_stack, 1, entropy.interface()) > 0) {
                inv_state.container.updateSlot(inv_state.selected_slot);
            }
        }
    }

    playShoot(dimension, arrow.position);
    return true;
}

fn playShoot(dimension: *Dimension, position: Protocol.Vector3f) void {
    const allocator = dimension.world.tecton.allocator;

    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();

    const packet = Protocol.LevelSoundEventPacket{
        .event = .shoot,
        .position = position,
        .data = 0,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const serialized = packet.serialize(&stream) catch return;

    broadcast.broadcastToNearby(dimension, position, broadcast.SOUND_BROADCAST_RADIUS, serialized);
}

const testing = std.testing;
const test_helpers = @import("../../items/enchantments/testing.zig");
const ItemStack = @import("../../items/item_stack.zig").ItemStack;

test "the first stack of arrows is the one the shot spends" {
    const allocator = testing.allocator;
    const arrows = try test_helpers.itemType(allocator, Bow.ARROW_IDENTIFIER, &.{}, true);
    defer arrows.deinit();
    const stones = try test_helpers.itemType(allocator, "minecraft:stone", &.{}, true);
    defer stones.deinit();

    var container = try Container.init(allocator, .Inventory, 36);
    defer container.deinit();

    try testing.expect(findArrow(&container) == null);

    container.setItem(4, ItemStack.init(allocator, stones, .{ .stack_size = 3 }));
    try testing.expect(findArrow(&container) == null);

    container.setItem(9, ItemStack.init(allocator, arrows, .{ .stack_size = 5 }));
    try testing.expectEqual(@as(u32, 9), findArrow(&container).?);

    container.setItem(2, ItemStack.init(allocator, arrows, .{ .stack_size = 1 }));
    try testing.expectEqual(@as(u32, 2), findArrow(&container).?);
}

test "infinity is the only bow that keeps its arrow" {
    try testing.expect(arrowSpend(true, false));
    try testing.expect(!arrowSpend(true, true));
    try testing.expect(!arrowSpend(false, false));
    try testing.expect(!arrowSpend(false, true));
}

test "a draw counts from the tick the bow was used" {
    try testing.expectEqual(@as(u64, 0), drawTicks(0, 500));
    try testing.expectEqual(@as(u64, 0), drawTicks(600, 500));
    try testing.expectEqual(@as(u64, 0), drawTicks(500, 500));
    try testing.expectEqual(@as(u64, 7), drawTicks(500, 507));
    try testing.expect(Bow.canShoot(drawTicks(500, 503)));
    try testing.expect(!Bow.canShoot(drawTicks(500, 502)));
}
