const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const transport = @import("../../transport/root.zig");

const inventory = @import("../../entity/traits/inventory.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;

pub fn handleMobEquipment(
    tecton: *Tecton,
    network: *NetworkHandler,
    connection: *transport.Connection,
    stream: *BinaryStream,
) !void {
    _ = try stream.readVarInt();
    _ = try stream.readVarLong();
    Protocol.NetworkItemStackDescriptor.skipShort(stream) catch {};
    const slot = try stream.readUint8();
    const selected_slot = try stream.readUint8();
    _ = try stream.readInt8();

    const player = tecton.getPlayerByConnection(connection) orelse return;

    const state = player.entity.getTraitState(inventory.InventoryTrait) orelse return;
    inventory.selectHeldSlot(state, selected_slot);
    inventory.broadcastHeldItem(network, player, state, slot, selected_slot);
}
