const std = @import("std");

test "server host adapters stay decoupled from each other and from view composition" {
    const adapters = .{
        @embedFile("host_players.zig"),
        @embedFile("host_perms.zig"),
        @embedFile("host_worlds.zig"),
        @embedFile("host_shutdown.zig"),
    };
    inline for (adapters) |content| {
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"host_") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "@import(\"./host_") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "ServerHost") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "commandViews") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "CommandViews") == null);
    }
}
