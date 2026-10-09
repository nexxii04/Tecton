const Raknet = @import("Raknet");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handlePacketViolationWarning(
    tecton: *Tecton,
    _: *NetworkHandler,
    _: *Raknet.Connection,
    stream: *BinaryStream,
) !void {
    _ = tecton;
    const packet = Protocol.PacketViolationWarningPacket.deserialize(stream) catch return;
    Raknet.Logger.ERROR("PacketViolationWarning: type={d} severity={d} packetId=0x{x} context={s}", .{
        packet.violation_type,
        packet.severity,
        packet.packet_id,
        packet.context,
    });
}
