const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const types = @import("../types.zig");

pub fn register(registry: *CommandRegistry) !void {
    const enum_idx = try registry.registerEnum(.{
        .name = "WeatherType",
        .values = &.{ "clear", "rain", "thunder" },
    });

    const cmd = try Command.init(
        registry.allocator,
        "weather",
        "Set the weather",
        "conduit.command.weather",
        &.{},
        @ptrCast(&handle),
    );
    try cmd.addOverload(&.{
        .{ .name = "type", .param_type = .String, .optional = false, .enum_index = enum_idx },
    });
    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const trimmed = std.mem.trim(u8, ctx.args, " ");
    if (trimmed.len == 0) {
        ctx.sendOutput(false, "Usage: /weather <clear|rain|thunder>");
        return;
    }

    const zero = Protocol.Vector3f.init(0, 0, 0);

    if (std.mem.eql(u8, trimmed, "clear")) {
        broadcastLevelEvent(ctx, .StopRain, zero, 0);
        broadcastLevelEvent(ctx, .StopThunder, zero, 0);
        ctx.sendOutput(true, "Set weather to clear");
    } else if (std.mem.eql(u8, trimmed, "rain")) {
        broadcastLevelEvent(ctx, .StopThunder, zero, 0);
        broadcastLevelEvent(ctx, .StartRain, zero, 65535);
        ctx.sendOutput(true, "Set weather to rain");
    } else if (std.mem.eql(u8, trimmed, "thunder")) {
        broadcastLevelEvent(ctx, .StartRain, zero, 65535);
        broadcastLevelEvent(ctx, .StartThunder, zero, 65535);
        ctx.sendOutput(true, "Set weather to thunder");
    } else {
        ctx.sendOutput(false, "Unknown weather type. Use: clear, rain, thunder");
    }
}

fn broadcastLevelEvent(ctx: *CommandContext, event: Protocol.LevelEvent, position: Protocol.Vector3f, data: i32) void {
    const dimension = resolveWeatherDimension(ctx) orelse return;

    var stream = BinaryStream.init(ctx.allocator, null, null);
    defer stream.deinit();
    const pkt = Protocol.LevelEventPacket{
        .event = event,
        .position = position,
        .data = data,
    };
    const serialized = pkt.serialize(&stream) catch return;
    dimension.broadcastToViewers(serialized);
}

fn resolveWeatherDimension(ctx: *CommandContext) ?*Dimension {
    if (ctx.player) |player| return player.entity.dimension;

    const conduit = ctx.network.conduit;
    if (conduit.getWorld("world")) |world| {
        if (world.getDimension("overworld")) |dimension| return dimension;
    }
    var worlds_it = conduit.worlds.valueIterator();
    const world_entry = worlds_it.next() orelse return null;
    var dims_it = world_entry.*.dimensions.valueIterator();
    const dim_entry = dims_it.next() orelse return null;
    return dim_entry.*;
}
