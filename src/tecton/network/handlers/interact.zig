const Raknet = @import("Raknet");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const inventory = @import("../../entity/traits/inventory.zig");

pub fn handleInteract(
    tecton: *Tecton,
    _: *NetworkHandler,
    connection: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    const player = tecton.getPlayerByConnection(connection) orelse return;
    const packet = Protocol.InteractPacket.deserialize(stream) catch return;

    switch (packet.action) {
        .OpenInventory => {
            if (player.entity.getTraitState(inventory.InventoryTrait)) |state| {
                _ = state.container.show(player);
            }
        },
        else => {},
    }
}
