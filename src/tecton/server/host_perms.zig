const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const buildAbilities = @import("../network/handlers/abilities.zig").buildAbilities;
const Tecton = @import("../tecton.zig").Tecton;

fn cast(ctx: *anyopaque) *Tecton {
    return @ptrCast(@alignCast(ctx));
}

pub fn commandPermission(ctx: *anyopaque, username: []const u8, xuid: []const u8, permission: []const u8) bool {
    if (permission.len == 0) return true;
    const tecton = cast(ctx);

    if (tecton.command_permission_checker) |checker| {
        return checker(tecton.command_permission_userdata, xuid, permission);
    }
    return tecton.permission_manager.hasPermission(username, permission);
}

pub fn setPermissionGroup(ctx: *anyopaque, name: []const u8, group: []const u8) anyerror!void {
    return cast(ctx).permission_manager.setPlayerGroup(name, group);
}

pub fn defaultPermissionGroup(ctx: *anyopaque) []const u8 {
    return cast(ctx).permission_manager.default_group;
}

pub fn isBanned(ctx: *anyopaque, name: []const u8) bool {
    return cast(ctx).ban_manager.isBanned(name);
}

pub fn addBan(ctx: *anyopaque, uuid: []const u8, name: []const u8, source: []const u8, reason: []const u8) anyerror!void {
    return cast(ctx).ban_manager.ban(uuid, name, source, reason);
}

pub fn removeBan(ctx: *anyopaque, name: []const u8) bool {
    return cast(ctx).ban_manager.unban(name);
}

pub fn banEntryName(ctx: *anyopaque, index: usize) ?[]const u8 {
    const entries = cast(ctx).ban_manager.entries.items;
    return if (index < entries.len) entries[index].name else null;
}

pub fn getPlayerGroup(ctx: *anyopaque, player_name: []const u8) []const u8 {
    return cast(ctx).permission_manager.getPlayerGroup(player_name);
}

pub fn refreshPlayerAbilities(ctx: *anyopaque, allocator: std.mem.Allocator, player_name: []const u8) void {
    const tecton = cast(ctx);
    const is_operator = std.mem.eql(u8, tecton.permission_manager.getPlayerGroup(player_name), "operator");
    for (tecton.getPlayerSnapshots()) |player| {
        if (!std.ascii.eqlIgnoreCase(player.username, player_name)) continue;
        if (player.pending_removal.load(.acquire)) return;
        var abilities = buildAbilities(allocator, player.entity.runtime_id, player.gamemode, is_operator) catch return;
        defer abilities.deinit();
        var stream = BinaryStream.init(allocator, null, null);
        defer stream.deinit();
        const serialized = abilities.serialize(&stream) catch return;
        player.network.sendPacket(player.connection, serialized) catch {};
        return;
    }
}
