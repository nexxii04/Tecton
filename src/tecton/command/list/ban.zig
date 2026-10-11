const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");
const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const types = @import("../types.zig");

pub fn register(registry: *CommandRegistry) !void {
    const cmd = try Command.init(
        registry.allocator,
        "ban",
        "Ban or unban a player",
        "tecton.command.ban",
        &.{},
        @ptrCast(&handleBan),
    );
    try cmd.addOverload(&.{
        .{ .name = "player", .param_type = .Target, .optional = false },
        .{ .name = "reason", .param_type = .Message, .optional = true },
    });

    const unban_sub = try registry.allocator.create(SubCommand);
    unban_sub.* = .{
        .name = "remove",
        .aliases = &.{},
        .params = &.{
            .{ .name = "player", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handleUnban),
    };
    try cmd.registerSubCommand(unban_sub);

    const list_sub = try registry.allocator.create(SubCommand);
    list_sub.* = .{
        .name = "list",
        .aliases = &.{},
        .params = &.{},
        .handler = @ptrCast(&handleList),
    };
    try cmd.registerSubCommand(list_sub);

    try registry.registerCommand(cmd);
}

fn handleBan(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const trimmed = std.mem.trim(u8, ctx.args, " ");
    if (trimmed.len == 0) {
        ctx.sendOutput(false, "Usage: /ban <player> [reason]");
        return;
    }

    const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ');
    const target_name = if (space_idx) |idx| trimmed[0..idx] else trimmed;
    const reason = if (space_idx) |idx| std.mem.trim(u8, trimmed[idx + 1 ..], " ") else "Banned by an operator.";

    const ban_mgr = ctx.views.bans;

    if (ban_mgr.isBanned(target_name)) {
        ctx.sendOutput(false, "Player is already banned");
        return;
    }

    const source = if (ctx.player) |p| p.username else "Console";
    if (ctx.resolvePlayer(target_name)) |player| {
        ban_mgr.ban(player.uuid, player.username, source, reason) catch {
            ctx.sendOutput(false, "Failed to ban player");
            return;
        };
        Raknet.Logger.INFO("{s} banned {s}: {s}", .{ source, player.username, reason });

        var stream = BinaryStream.init(ctx.allocator, null, null);
        defer stream.deinit();
        var disconnect = Protocol.DisconnectPacket{
            .reason = .Kicked,
            .messages = .{
                .message = reason,
                .filtered_message = reason,
            },
        };
        const serialized = disconnect.serialize(&stream) catch return;
        ctx.network.sendImmediate(player.connection, serialized) catch {};
        player.connection.deactivate();
    } else {
        ban_mgr.ban("", target_name, source, reason) catch {
            ctx.sendOutput(false, "Failed to ban player");
            return;
        };
    }

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Banned {s}", .{target_name}) catch return;
    ctx.sendOutput(true, msg);
}

fn handleUnban(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const trimmed = std.mem.trim(u8, ctx.args, " ");
    if (trimmed.len == 0) {
        ctx.sendOutput(false, "Usage: /ban remove <player>");
        return;
    }

    const ban_mgr = ctx.views.bans;
    if (ban_mgr.unban(trimmed)) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unbanned {s}", .{trimmed}) catch return;
        ctx.sendOutput(true, msg);
    } else {
        ctx.sendOutput(false, "Player is not banned");
    }
}

fn handleList(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const ban_mgr = ctx.views.bans;

    if (ban_mgr.entryName(0) == null) {
        ctx.sendOutput(true, "No banned players");
        return;
    }

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const header = "Banned players: ";
    @memcpy(buf[pos .. pos + header.len], header);
    pos += header.len;

    var i: usize = 0;
    while (ban_mgr.entryName(i)) |name| : (i += 1) {
        if (i > 0) {
            if (pos + 2 < buf.len) {
                buf[pos] = ',';
                buf[pos + 1] = ' ';
                pos += 2;
            }
        }
        if (pos + name.len < buf.len) {
            @memcpy(buf[pos .. pos + name.len], name);
            pos += name.len;
        }
    }
    ctx.sendOutput(true, buf[0..pos]);
}
