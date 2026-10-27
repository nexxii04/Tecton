const std = @import("std");
const log = @import("../core/log.zig");

pub fn formatJoinMessage(buf: []u8, username: []const u8, verified: bool) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "Player {s} joined ({s}).",
        .{ username, if (verified) "verified identity" else "offline identity, not verified" },
    );
}

pub fn formatChatMessage(buf: []u8, username: []const u8, message: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "<{s}> {s}", .{ username, message });
}

pub fn formatDisconnectMessage(buf: []u8, username: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "Player {s} left.", .{username});
}

pub fn logJoin(username: []const u8, verified: bool) void {
    var buf: [256]u8 = undefined;
    const msg = formatJoinMessage(&buf, username, verified) catch "Player joined.";
    log.info("{s}", .{msg});
}

pub fn logChat(username: []const u8, message: []const u8) void {
    var buf: [512]u8 = undefined;
    const msg = formatChatMessage(&buf, username, message) catch "Player chat message.";
    log.info("{s}", .{msg});
}

pub fn logDisconnect(username: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = formatDisconnectMessage(&buf, username) catch "Player left.";
    log.info("{s}", .{msg});
}

test "formats a verified join log message" {
    var buf: [128]u8 = undefined;
    const msg = try formatJoinMessage(&buf, "Steve", true);
    try std.testing.expectEqualStrings("Player Steve joined (verified identity).", msg);
}

test "formats an offline join log message" {
    var buf: [128]u8 = undefined;
    const msg = try formatJoinMessage(&buf, "Steve", false);
    try std.testing.expectEqualStrings("Player Steve joined (offline identity, not verified).", msg);
}

test "formats chat log message" {
    var buf: [128]u8 = undefined;
    const msg = try formatChatMessage(&buf, "Steve", "hello");
    try std.testing.expectEqualStrings("<Steve> hello", msg);
}

test "formats disconnect log message" {
    var buf: [128]u8 = undefined;
    const msg = try formatDisconnectMessage(&buf, "Steve");
    try std.testing.expectEqualStrings("Player Steve left.", msg);
}
