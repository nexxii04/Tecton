const std = @import("std");

const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const MovementBroadcast = @import("../../network/movement-broadcast.zig");

pub fn register(registry: *CommandRegistry) !void {
    const cmd = try Command.init(
        registry.allocator,
        "movement",
        "Show the movement band and position of every online player",
        "tecton.command.movement",
        &.{},
        @ptrCast(&handle),
    );
    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const snapshots = tecton.getPlayerSnapshots();

    var viewers: std.ArrayList(MovementBroadcast.ViewerPoint) = .empty;
    defer viewers.deinit(ctx.allocator);
    for (snapshots) |player| {
        if (!player.spawned) continue;
        const dimension = player.entity.dimension orelse continue;
        viewers.append(ctx.allocator, .{
            .runtime_id = player.entity.runtime_id,
            .dimension = @intFromPtr(dimension),
            .x = player.entity.position.x,
            .z = player.entity.position.z,
        }) catch {};
    }

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    std.Io.Writer.print(
        &writer,
        "§7--- §bMovement bands§7: §f{d}/{d}/{d}/{d}§7 ticks at §f{d}/{d}/{d}§7+ blocks " ++
            "(§f{d}§7 spawned) ---§r\n",
        .{
            MovementBroadcast.BAND_INTERVALS[0],
            MovementBroadcast.BAND_INTERVALS[1],
            MovementBroadcast.BAND_INTERVALS[2],
            MovementBroadcast.BAND_INTERVALS[3],
            MovementBroadcast.BAND_DISTANCES[0],
            MovementBroadcast.BAND_DISTANCES[1],
            MovementBroadcast.BAND_DISTANCES[2],
            viewers.items.len,
        },
    ) catch return;

    for (snapshots) |player| {
        if (!player.spawned) continue;
        const dimension = player.entity.dimension orelse continue;

        const nearest = MovementBroadcast.nearestViewerBand(
            player.entity.runtime_id,
            @intFromPtr(dimension),
            player.entity.position.x,
            player.entity.position.z,
            viewers.items,
        );

        var band_buf: [4]u8 = undefined;
        const band_text = if (nearest) |viewer|
            std.fmt.bufPrint(&band_buf, "{d}", .{viewer.band}) catch "?"
        else
            "none";
        const distance = if (nearest) |viewer| viewer.distance else 0;

        std.Io.Writer.print(
            &writer,
            "§f{s}§7: band §f{s}§7 at §f{d:.1}§7 blocks, pos §f{d:.1} {d:.1} {d:.1}§7, " ++
                "sees §f{d}§7, view §f{d}§r\n",
            .{
                player.username,
                band_text,
                distance,
                player.entity.position.x,
                player.entity.position.y,
                player.entity.position.z,
                player.visible_players.count(),
                player.view_distance,
            },
        ) catch return;
    }

    ctx.sendOutput(true, writer.buffered());
}
