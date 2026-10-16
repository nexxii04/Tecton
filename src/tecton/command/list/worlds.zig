const std = @import("std");
const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const Tecton = @import("../../tecton.zig").Tecton;

pub fn register(registry: *CommandRegistry, tecton: *Tecton) !void {
    const world_enum_idx = try registerWorldEnum(registry, tecton);

    const cmd = try Command.init(
        registry.allocator,
        "worlds",
        "List all registered worlds",
        "tecton.command.worlds",
        &.{},
        @ptrCast(&handle),
    );

    try cmd.addOverload(&.{
        .{ .name = "worldName", .param_type = .String, .optional = true, .enum_index = world_enum_idx },
    });

    try registry.registerCommand(cmd);
}

fn registerWorldEnum(registry: *CommandRegistry, tecton: *Tecton) !u32 {
    var names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer if (names.capacity > 0) names.deinit(registry.allocator);

    var it = tecton.worlds.keyIterator();
    while (it.next()) |key| {
        try names.append(registry.allocator, key.*);
    }

    const values = try registry.allocator.alloc([]const u8, names.items.len);
    @memcpy(values, names.items);

    return try registry.registerEnum(.{
        .name = "WorldName",
        .values = values,
        .owned = true,
    });
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.views.world_info;
    const trimmed = std.mem.trim(u8, ctx.args, " ");

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    if (trimmed.len == 0) {
        std.Io.Writer.print(&writer, "Worlds (§v{d}§r):", .{tecton.worlds.count()}) catch return;
        var it = tecton.worlds.valueIterator();
        while (it.next()) |world| {
            std.Io.Writer.print(&writer, "\n  §v{s}§r:", .{world.*.identifier}) catch return;
            var dim_it = world.*.dimensions.valueIterator();
            while (dim_it.next()) |dim| {
                std.Io.Writer.print(&writer, "\n    §b{s}§r (§7spawn: §a{d}§7,§a{d}§7,§a{d}§r)", .{
                    dim.*.identifier,
                    dim.*.spawn_position.x,
                    dim.*.spawn_position.y,
                    dim.*.spawn_position.z,
                }) catch return;
            }
        }
        ctx.sendOutput(true, writer.buffered());
        return;
    }

    const world = tecton.worlds.get(trimmed) orelse {
        ctx.sendOutput(false, "World not found");
        return;
    };

    const target_tps = tecton.targetTps();
    const current_mspt = tecton.current_mspt.*;
    const raknet_mspt = tecton.current_raknet_mspt.*;
    const game_mspt = tecton.current_game_mspt.*;
    const slow_pct = tecton.profiler.slowTickPct();
    const tps_ratio = if (target_tps > 0.0) tecton.current_tps.* / target_tps else 1.0;
    const tps_color: []const u8 = if (tps_ratio >= 0.975) "§a" else if (tps_ratio >= 0.75) "§e" else "§c";
    const slow_color: []const u8 = if (tecton.profiler.slow_ticks == 0) "§a" else if (slow_pct < 5.0) "§e" else "§c";

    std.Io.Writer.print(&writer, "§6World: §f{s}\n§7TPS: {s}{d:.1}§7/§f{d:.1} §7MSPT: §f{d:.2}ms §7RakNet: §f{d:.2}ms §7Game: §f{d:.2}ms §7SlowTicks: {s}{d} §7({d:.1}%)", .{
        world.identifier,
        tps_color,
        tecton.current_tps.*,
        target_tps,
        current_mspt,
        raknet_mspt,
        game_mspt,
        slow_color,
        tecton.profiler.slow_ticks,
        slow_pct,
    }) catch return;

    const snapshots = tecton.getPlayerSnapshots();
    var dim_it = world.dimensions.valueIterator();
    while (dim_it.next()) |dim| {
        var player_count: usize = 0;
        for (snapshots) |player| {
            if (player.entity.dimension == dim.*) player_count += 1;
        }
        std.Io.Writer.print(&writer, "\n §b{s} §8[§7{s}§8]\n  §8Spawn: §f{d},{d},{d} §8SimDist: §f{d}\n  §8Chunks: §f{d} §8Entities: §f{d} §8Players: §f{d}", .{
            dim.*.identifier,
            @tagName(dim.*.dimension_type),
            dim.*.spawn_position.x,
            dim.*.spawn_position.y,
            dim.*.spawn_position.z,
            dim.*.simulation_distance,
            dim.*.chunks.count(),
            dim.*.entities.count(),
            player_count,
        }) catch return;
    }
    ctx.sendOutput(true, writer.buffered());
}
