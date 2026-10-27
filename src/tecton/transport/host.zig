const connection = @import("connection.zig");

pub const Host = struct {
    ctx: *anyopaque,
    dispatch: *const fn (ctx: *anyopaque, conn: *connection.Connection, packets: []const []const u8) void,
};
