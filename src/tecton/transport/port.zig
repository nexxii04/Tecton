const connection = @import("connection.zig");
const SendPriority = @import("priority.zig").SendPriority;

/// Delivery guarantee a payload needs. In v1 every port maps this to its only ordered channel.
pub const Channel = enum { reliable, unreliable };

/// `flush` delivers what is already queued; `abort` drops it.
pub const CloseMode = enum { flush, abort };

pub const SendError = error{ Closed, Backpressure, PayloadTooLarge, UnknownConnection };

/// The whole contract between the game and a transport.
///
/// `sendBytes` receives one Bedrock frame, already framed and compressed: the port only
/// delivers it. Bytes are borrowed for the duration of the call.
pub const Port = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, conn: *connection.Connection, bytes: []const u8, priority: SendPriority) SendError!void,
    close: *const fn (ctx: *anyopaque, conn: *connection.Connection, mode: CloseMode) void,
    max_payload: *const fn (ctx: *anyopaque, conn: *connection.Connection) usize,

    pub fn sendBytes(self: Port, conn: *connection.Connection, bytes: []const u8, priority: SendPriority) SendError!void {
        return self.send(self.ctx, conn, bytes, priority);
    }

    pub fn closeConn(self: Port, conn: *connection.Connection, mode: CloseMode) void {
        self.close(self.ctx, conn, mode);
    }

    pub fn maxPayload(self: Port, conn: *connection.Connection) usize {
        return self.max_payload(self.ctx, conn);
    }
};
