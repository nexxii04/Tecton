const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const inventory = @import("../../entity/traits/inventory.zig");
const NetworkHandler = @import("../network-handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;

pub fn handlePlayerHotbar(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const selected_slot = try readSelection(stream);

    const player = tecton.getPlayerByConnection(connection) orelse return;
    if (selected_slot > 8) return;

    const state = player.entity.getTraitState(inventory.InventoryTrait) orelse return;
    inventory.selectHeldSlot(state, selected_slot);

    inventory.broadcastHeldItem(network, player, state, selected_slot, selected_slot);
}

pub fn readSelection(stream: *BinaryStream) !u8 {
    _ = try stream.readVarInt();
    const selected_slot = try stream.readUint8();
    _ = try stream.readUint8();
    _ = try stream.readUint8();
    return selected_slot;
}

const testing = std.testing;

test "the selection follows the measured wire layout" {
    const bytes = [_]u8{ 0x30, 0x03, 0x00, 0x01 };
    var stream = BinaryStream.init(testing.allocator, &bytes, null);
    defer stream.deinit();

    try testing.expectEqual(@as(u8, 3), try readSelection(&stream));
    try testing.expectEqual(bytes.len, stream.offset);
}
