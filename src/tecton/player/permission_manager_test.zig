const std = @import("std");

pub fn test_existing_permissions(comptime PermissionManager: type) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\{
        \\  "groups": {
        \\    "member": ["tecton.command.about"],
        \\    "operator": ["*"]
        \\  },
        \\  "players": {
        \\    "ArchBaseline": "operator",
        \\    "ArchObserver": "member"
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "permissions.json", .data = content });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});

    var manager = PermissionManager.init(io, allocator, path, "member");
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 2), manager.groups.count());
    try std.testing.expectEqual(@as(usize, 2), manager.player_groups.count());
    try std.testing.expectEqualStrings("operator", manager.getPlayerGroup("ArchBaseline"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("ArchObserver"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("NewPlayer"));
    try std.testing.expect(manager.hasPermission("ArchBaseline", "tecton.command.give"));
    try std.testing.expect(manager.hasPermission("ArchObserver", "tecton.command.about"));
    try std.testing.expect(!manager.hasPermission("ArchObserver", "tecton.command.give"));

    const after = try tmp.dir.readFileAlloc(io, "permissions.json", allocator, .limited(1024 * 1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(content, after);
}
