const Raknet = @import("Raknet");

pub const Host = struct {
    ctx: *anyopaque,
    dispatch: *const fn (ctx: *anyopaque, conn: *Raknet.Connection, packets: []const []const u8) void,
    disconnected: *const fn (ctx: *anyopaque, conn: *Raknet.Connection) void,
};
