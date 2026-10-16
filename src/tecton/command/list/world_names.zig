const std = @import("std");

const CommandContext = @import("../context.zig").CommandContext;
const world_root = @import("../../world/root.zig");
const World = world_root.World;
const Dimension = world_root.Dimension;

pub fn isValidWorldName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |char| {
        const is_alpha = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
        const is_digit = char >= '0' and char <= '9';
        if (!is_alpha and !is_digit and char != '_' and char != '-') return false;
    }
    return true;
}

pub fn countPlayersInWorld(ctx: *CommandContext, world: *World) usize {
    var count: usize = 0;
    const snapshots = ctx.views.selection.getPlayerSnapshots();
    for (snapshots) |player| {
        if (player.entity.dimension) |dim| {
            if (dim.world == world) {
                count += 1;
                continue;
            }
        }
        if (player.pending_dimension) |dim| {
            if (dim.world == world) count += 1;
        }
    }
    return count;
}

pub fn resolveWorldDimension(world: *World, requested: ?[]const u8) ?*Dimension {
    if (requested) |name| return world.getDimension(name);
    if (world.getDimension("overworld")) |dimension| return dimension;
    var it = world.dimensions.valueIterator();
    const entry = it.next() orelse return null;
    return entry.*;
}
