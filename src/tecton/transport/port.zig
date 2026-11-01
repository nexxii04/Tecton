const std = @import("std");
const connection = @import("connection.zig");
const SendPriority = @import("priority.zig").SendPriority;

/// Delivery guarantee a payload needs. Only movement opts into `unreliable`; every other
/// frame keeps the ordered channel. An unreliable payload cannot be fragmented, so it must
/// fit the negotiated message size on its own.
pub const Channel = enum {
    reliable,
    unreliable,

    pub fn parse(value: []const u8) ?Channel {
        if (std.mem.eql(u8, value, "reliable")) return .reliable;
        if (std.mem.eql(u8, value, "unreliable")) return .unreliable;
        return null;
    }

    pub fn label(self: Channel) []const u8 {
        return switch (self) {
            .reliable => "reliable",
            .unreliable => "unreliable",
        };
    }
};

/// `flush` delivers what is already queued; `abort` drops it.
pub const CloseMode = enum { flush, abort };

pub const SendError = error{ Closed, Backpressure, PayloadTooLarge, UnknownConnection };

/// The whole contract between the game and a transport.
///
/// `sendBytes` receives one Bedrock frame, already framed and compressed: the port only
/// delivers it. Bytes are borrowed for the duration of the call.
pub const Port = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, conn: *connection.Connection, bytes: []const u8, channel: Channel, priority: SendPriority) SendError!void,
    close: *const fn (ctx: *anyopaque, conn: *connection.Connection, mode: CloseMode) void,
    max_payload: *const fn (ctx: *anyopaque, conn: *connection.Connection) usize,

    pub fn sendBytes(self: Port, conn: *connection.Connection, bytes: []const u8, channel: Channel, priority: SendPriority) SendError!void {
        return self.send(self.ctx, conn, bytes, channel, priority);
    }

    pub fn closeConn(self: Port, conn: *connection.Connection, mode: CloseMode) void {
        self.close(self.ctx, conn, mode);
    }

    pub fn maxPayload(self: Port, conn: *connection.Connection) usize {
        return self.max_payload(self.ctx, conn);
    }
};

test "the channel parses both guarantees and nothing else" {
    try std.testing.expectEqual(Channel.reliable, Channel.parse("reliable").?);
    try std.testing.expectEqual(Channel.unreliable, Channel.parse("unreliable").?);
    try std.testing.expect(Channel.parse("Reliable") == null);
    try std.testing.expect(Channel.parse("unreliable ") == null);
    try std.testing.expect(Channel.parse("") == null);
    try std.testing.expectEqualStrings("reliable", Channel.reliable.label());
    try std.testing.expectEqualStrings("unreliable", Channel.unreliable.label());
}
