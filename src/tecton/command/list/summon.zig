const std = @import("std");
const Protocol = @import("protocol");
const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const types = @import("../types.zig");
const EntityTypeRegistry = @import("../../entity/entity_type_registry.zig");
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const entities = @import("../../world/dimension/entities.zig");

pub fn register(registry: *CommandRegistry) !void {
    const entity_enum_idx = try registerEntityEnum(registry);

    const cmd = try Command.init(
        registry.allocator,
        "summon",
        "Summon an entity",
        "tecton.command.summon",
        &.{},
        @ptrCast(&handle),
    );

    const params = try registry.allocator.alloc(types.CommandParameter, 6);
    params[0] = .{
        .name = "entityType",
        .param_type = .String,
        .optional = false,
        .enum_index = entity_enum_idx,
    };
    params[1] = .{ .name = "x", .param_type = .Float, .optional = true };
    params[2] = .{ .name = "y", .param_type = .Float, .optional = true };
    params[3] = .{ .name = "z", .param_type = .Float, .optional = true };
    params[4] = .{
        .name = "nameTag",
        .param_type = .String,
        .optional = true,
    };
    params[5] = .{
        .name = "alwaysVisible",
        .param_type = .String,
        .optional = true,
    };
    try cmd.addOverload(params);
    registry.allocator.free(params);
    try registry.registerCommand(cmd);
}

fn registerEntityEnum(registry: *CommandRegistry) !u32 {
    const reg = EntityTypeRegistry.EntityTypeRegistry.getRegistry() orelse return error.NoEntityRegistry;
    var names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer if (names.capacity > 0) names.deinit(registry.allocator);

    var it = reg.types.keyIterator();
    while (it.next()) |key| {
        const id = key.*;
        if (std.mem.eql(u8, id, "minecraft:player")) continue;
        const short = if (std.mem.startsWith(u8, id, "minecraft:")) id[10..] else id;
        try names.append(registry.allocator, short);
    }

    const values = try registry.allocator.alloc([]const u8, names.items.len);
    @memcpy(values, names.items);

    return try registry.registerEnum(.{
        .name = "EntityType",
        .values = values,
        .owned = true,
    });
}

const Usage = "Usage: /summon <entityType> [x y z] [nameTag] [alwaysVisible]";

fn resolveDimension(ctx: *CommandContext) ?*Dimension {
    if (ctx.player) |player| {
        if (player.entity.dimension) |dimension| return dimension;
    }

    var world_it = ctx.tecton.worlds.valueIterator();
    while (world_it.next()) |world| {
        if (world.*.getDimension("overworld")) |dimension| return dimension;
    }

    var fallback_it = ctx.tecton.worlds.valueIterator();
    while (fallback_it.next()) |world| {
        var dimension_it = world.*.dimensions.valueIterator();
        if (dimension_it.next()) |dimension| return dimension.*;
    }
    return null;
}

const Coordinates = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn parseCoordinates(tokens: []const []const u8) ?Coordinates {
    const x = std.fmt.parseFloat(f32, tokens[0]) catch return null;
    const y = std.fmt.parseFloat(f32, tokens[1]) catch return null;
    const z = std.fmt.parseFloat(f32, tokens[2]) catch return null;
    return .{ .x = x, .y = y, .z = z };
}

const Arguments = struct {
    entity_name: []const u8,
    coordinates: ?Coordinates = null,
    name_tag: ?[]const u8 = null,
    always_visible: bool = false,
};

fn parseArguments(args: []const u8) ?Arguments {
    var tokens: [6][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, args, ' ');
    while (iter.next()) |token| {
        if (count == tokens.len) break;
        tokens[count] = token;
        count += 1;
    }
    if (count == 0) return null;

    var index: usize = 1;
    var coordinates: ?Coordinates = null;
    if (count >= index + 3) {
        coordinates = parseCoordinates(tokens[index..][0..3]);
        if (coordinates != null) index += 3;
    }

    return .{
        .entity_name = tokens[0],
        .coordinates = coordinates,
        .name_tag = if (index < count) tokens[index] else null,
        .always_visible = if (index + 1 < count)
            std.mem.eql(u8, tokens[index + 1], "true") or std.mem.eql(u8, tokens[index + 1], "1")
        else
            false,
    };
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const parsed = parseArguments(ctx.args) orelse {
        ctx.sendOutput(false, Usage);
        return;
    };
    const entity_name = parsed.entity_name;
    const coordinates = parsed.coordinates;
    const name_tag = parsed.name_tag;
    const always_visible = parsed.always_visible;

    var identifier_buf: [128]u8 = undefined;
    const identifier = if (std.mem.indexOf(u8, entity_name, ":") != null)
        entity_name
    else blk: {
        const written = std.fmt.bufPrint(&identifier_buf, "minecraft:{s}", .{entity_name}) catch {
            ctx.sendOutput(false, "Entity name too long");
            return;
        };
        break :blk written;
    };

    const entity_type = EntityTypeRegistry.EntityTypeRegistry.get(identifier) orelse {
        ctx.sendOutput(false, "Unknown entity type");
        return;
    };

    const dimension = resolveDimension(ctx) orelse {
        ctx.sendOutput(false, "This command can only be used by a player");
        return;
    };

    const spawn_pos = if (coordinates) |c|
        Protocol.Vector3f.init(c.x, c.y, c.z)
    else if (ctx.player) |player| blk: {
        const pos = player.entity.position;
        break :blk Protocol.Vector3f.init(pos.x, pos.y - 1.62, pos.z);
    } else {
        ctx.sendOutput(false, "This command can only be used by a player without coordinates");
        return;
    };

    if (name_tag) |tag| {
        _ = entities.spawnEntityWithOptions(dimension, entity_type, spawn_pos, tag, always_visible) catch {
            ctx.sendOutput(false, "Failed to summon entity");
            return;
        };
    } else {
        _ = entities.spawnEntity(dimension, entity_type, spawn_pos) catch {
            ctx.sendOutput(false, "Failed to summon entity");
            return;
        };
    }

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Summoned {s}", .{entity_name}) catch return;
    ctx.sendOutput(true, msg);
}

const testing = std.testing;

test "the argument forms keep working" {
    const bare = parseArguments("zombie") orelse return error.MissingArguments;
    try testing.expectEqualStrings("zombie", bare.entity_name);
    try testing.expectEqual(@as(?Coordinates, null), bare.coordinates);
    try testing.expectEqual(@as(?[]const u8, null), bare.name_tag);

    const tagged = parseArguments("zombie  Guard") orelse return error.MissingArguments;
    try testing.expectEqualStrings("Guard", tagged.name_tag.?);
    try testing.expectEqual(@as(?Coordinates, null), tagged.coordinates);

    const placed = parseArguments("minecraft:zombie 2 -58 0") orelse return error.MissingArguments;
    try testing.expectEqualStrings("minecraft:zombie", placed.entity_name);
    try testing.expectEqual(@as(f32, 2), placed.coordinates.?.x);
    try testing.expectEqual(@as(f32, -58), placed.coordinates.?.y);
    try testing.expectEqual(@as(f32, 0), placed.coordinates.?.z);
    try testing.expectEqual(@as(?[]const u8, null), placed.name_tag);
    try testing.expect(!placed.always_visible);

    const all = parseArguments("zombie 2 -58 0 Guard true") orelse return error.MissingArguments;
    try testing.expectEqual(@as(f32, -58), all.coordinates.?.y);
    try testing.expectEqualStrings("Guard", all.name_tag.?);
    try testing.expect(all.always_visible);

    const numeric_tag = parseArguments("zombie 12 0") orelse return error.MissingArguments;
    try testing.expectEqualStrings("12", numeric_tag.name_tag.?);
    try testing.expectEqual(@as(?Coordinates, null), numeric_tag.coordinates);

    try testing.expect(parseArguments("   ") == null);
    try testing.expect(parseArguments("") == null);
}
