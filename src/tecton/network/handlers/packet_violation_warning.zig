const log = @import("../../core/log.zig");
const transport = @import("../../transport/root.zig");
const NetworkHandler = @import("../../transport/network_handler.zig").NetworkHandler;
const Tecton = @import("../../tecton.zig").Tecton;
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub fn handlePacketViolationWarning(
    tecton: *Tecton,
    _: *NetworkHandler,
    _: *transport.Connection,
    stream: *BinaryStream,
) !void {
    _ = tecton;
    const packet = Protocol.PacketViolationWarningPacket.deserialize(stream) catch return;
    log.err("PacketViolationWarning: type={d} severity={d} packetId=0x{x} context={s}", .{
        packet.violation_type,
        packet.severity,
        packet.packet_id,
        packet.context,
    });
}
