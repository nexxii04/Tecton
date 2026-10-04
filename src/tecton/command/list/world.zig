const std = @import("std");

const Raknet = @import("Raknet");

const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const WorldLifecycle = @import("../../world/world-lifecycle.zig");
const World = @import("../../world/world.zig").World;
const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub fn register(registry: *CommandRegistry, tecton: *Tecton) !void {
    const world_enum_idx = try registerWorldEnum(registry, tecton);
    const dim_enum_idx = try registry.registerEnum(.{
        .name = "DimensionName",
        .values = &.{ "overworld", "nether", "end" },
    });

    const cmd = try Command.init(
        registry.allocator,
        "world",
        "Create, load and unload worlds; teleport players between them",
        "tecton.command.world",
        &.{},
        @ptrCast(&handle),
    );

    try cmd.addOverload(&.{
        .{ .name = "worldName", .param_type = .String, .optional = false, .enum_index = world_enum_idx },
    });
    try cmd.addOverload(&.{
        .{ .name = "worldName", .param_type = .String, .optional = false, .enum_index = world_enum_idx },
        .{ .name = "dimension", .param_type = .String, .optional = false, .enum_index = dim_enum_idx },
    });

    const create_sub = try registry.allocator.create(SubCommand);
    create_sub.* = .{
        .name = "create",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handleCreate),
    };
    try cmd.registerSubCommand(create_sub);

    const load_sub = try registry.allocator.create(SubCommand);
    load_sub.* = .{
        .name = "load",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handleLoad),
    };
    try cmd.registerSubCommand(load_sub);

    const unload_sub = try registry.allocator.create(SubCommand);
    unload_sub.* = .{
        .name = "unload",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handleUnload),
    };
    try cmd.registerSubCommand(unload_sub);

    const tp_sub = try registry.allocator.create(SubCommand);
    tp_sub.* = .{
        .name = "tp",
        .aliases = &.{},
        .params = &.{
            .{ .name = "player", .param_type = .Target, .optional = false },
            .{ .name = "world", .param_type = .String, .optional = false },
            .{ .name = "dimension", .param_type = .String, .optional = true },
        },
        .handler = @ptrCast(&handleTp),
    };
    try cmd.registerSubCommand(tp_sub);

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
        .name = "TransferWorld",
        .values = values,
        .owned = true,
    });
}

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

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const trimmed = std.mem.trim(u8, ctx.args, " ");

    if (trimmed.len == 0) {
        ctx.sendOutput(false, "Usage: /world <name> [dimension] | /world create <name> | " ++
            "/world load <name> | /world unload <name> | /world tp <player> <world> [dimension]");
        return;
    }

    var iter = std.mem.splitScalar(u8, trimmed, ' ');
    const world_name = iter.next() orelse return;
    const dim_name = iter.next() orelse "overworld";

    const world = ctx.tecton.worlds.get(world_name) orelse {
        ctx.sendOutput(false, "World not found");
        return;
    };

    const dimension = world.getDimension(dim_name) orelse {
        ctx.sendOutput(false, "Dimension not found in that world");
        return;
    };

    const player = ctx.player orelse {
        ctx.sendOutput(false, "This command can only be used by a player");
        return;
    };

    if (player.entity.dimension == dimension) {
        ctx.sendOutput(false, "Already in that world/dimension");
        return;
    }

    player.transferToDimension(dimension);
    ctx.sendOutput(true, "Transferring...");
}

fn handleCreate(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world create <name>");
        return;
    }
    if (!isValidWorldName(name)) {
        ctx.sendOutput(false, "Invalid world name: use 1-32 letters, digits, '_' or '-'");
        return;
    }
    if (tecton.worlds.has(name)) {
        ctx.sendOutput(false, "World already exists");
        return;
    }
    if (tecton.worlds.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (worldDirectoryExists(tecton, name)) {
        ctx.sendOutput(false, "World already exists on disk; use /world load <name> instead");
        return;
    }

    const owned_name = tecton.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!tecton.worlds.beginOp(owned_name)) {
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    WorldLifecycle.queueCreate(
        tecton,
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        tecton.worlds.endOp(owned_name);
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world creation");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Creating world '{s}'...", .{name}) catch "Creating world...";
    ctx.sendOutput(true, message);
}

fn handleLoad(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world load <name>");
        return;
    }
    if (!isValidWorldName(name)) {
        ctx.sendOutput(false, "Invalid world name: use 1-32 letters, digits, '_' or '-'");
        return;
    }
    if (tecton.worlds.has(name)) {
        ctx.sendOutput(false, "World already loaded");
        return;
    }
    if (tecton.worlds.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (!worldDirectoryExists(tecton, name)) {
        ctx.sendOutput(false, "World not found on disk");
        return;
    }

    const owned_name = tecton.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!tecton.worlds.beginOp(owned_name)) {
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    WorldLifecycle.queueLoad(
        tecton,
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        tecton.worlds.endOp(owned_name);
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world load");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Loading world '{s}'...", .{name}) catch "Loading world...";
    ctx.sendOutput(true, message);
}

fn worldDirectoryExists(tecton: *Tecton, name: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tecton.paths.worlds, name }) catch return false;
    if (std.Io.Dir.cwd().openDir(tecton.io, path, .{})) |dir_val| {
        var dir = dir_val;
        dir.close(tecton.io);
        return true;
    } else |_| {
        return false;
    }
}

fn handleUnload(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world unload <name>");
        return;
    }

    const world = tecton.worlds.get(name) orelse {
        ctx.sendOutput(false, "World not found");
        return;
    };
    if (tecton.worlds.count() <= 1) {
        ctx.sendOutput(false, "Cannot unload the only world");
        return;
    }
    if (tecton.worlds.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (countPlayersInWorld(tecton, world) > 0) {
        ctx.sendOutput(false, "Cannot unload a world with players inside");
        return;
    }

    const owned_name = tecton.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!tecton.worlds.beginOp(owned_name)) {
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    tecton.worlds.detach(world);
    world.unloading = true;

    WorldLifecycle.queueUnload(
        tecton,
        world,
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        world.unloading = false;
        tecton.worlds.adopt(world) catch |err| {
            Raknet.Logger.ERROR("Failed to restore world '{s}' after unload enqueue failure: {any}", .{ name, err });
        };
        tecton.worlds.endOp(owned_name);
        tecton.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world unload");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Unloading world '{s}'...", .{name}) catch "Unloading world...";
    ctx.sendOutput(true, message);
}

fn countPlayersInWorld(tecton: *Tecton, world: *World) usize {
    var count: usize = 0;
    const snapshots = tecton.getPlayerSnapshots();
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

fn resolveWorldDimension(world: *World, requested: ?[]const u8) ?*Dimension {
    if (requested) |name| return world.getDimension(name);
    if (world.getDimension("overworld")) |dimension| return dimension;
    var it = world.dimensions.valueIterator();
    const entry = it.next() orelse return null;
    return entry.*;
}

fn handleTp(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const usage = "Usage: /world tp <player> <world> [dimension]";
    const trimmed = std.mem.trim(u8, ctx.args, " ");

    var iter = std.mem.splitScalar(u8, trimmed, ' ');
    const target_token = iter.next() orelse {
        ctx.sendOutput(false, usage);
        return;
    };
    const world_token = iter.next() orelse {
        ctx.sendOutput(false, usage);
        return;
    };
    const dimension_token = iter.next();
    if (iter.next() != null) {
        ctx.sendOutput(false, usage);
        return;
    }

    const world = tecton.worlds.get(world_token) orelse {
        ctx.sendOutput(false, "World not found");
        return;
    };
    const dimension = resolveWorldDimension(world, dimension_token) orelse {
        ctx.sendOutput(false, "Dimension not found in that world");
        return;
    };

    const targets = ctx.resolvePlayers(target_token) orelse {
        ctx.sendOutput(false, "Player not found");
        return;
    };

    var moved: usize = 0;
    var moved_name: []const u8 = "";
    for (targets) |target| {
        if (target.pending_dimension != null) continue;
        if (target.entity.dimension == dimension) continue;
        target.transferToDimension(dimension);
        moved += 1;
        moved_name = target.username;
    }

    if (moved == 0) {
        ctx.sendOutput(false, "No players moved: already in that world/dimension");
        return;
    }

    var buf: [192]u8 = undefined;
    if (moved == 1) {
        const message = std.fmt.bufPrint(&buf, "Teleported {s} to {s}/{s}", .{ moved_name, world.identifier, dimension.identifier }) catch "Teleported player";
        ctx.sendOutput(true, message);
    } else {
        const message = std.fmt.bufPrint(&buf, "Teleported {d} players to {s}/{s}", .{ moved, world.identifier, dimension.identifier }) catch "Teleported players";
        ctx.sendOutput(true, message);
    }
}

test "world name validation accepts safe names and rejects traversal" {
    try std.testing.expect(isValidWorldName("world"));
    try std.testing.expect(isValidWorldName("World_2-test"));
    try std.testing.expect(isValidWorldName("a"));
    try std.testing.expect(isValidWorldName("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"));

    try std.testing.expect(!isValidWorldName(""));
    try std.testing.expect(!isValidWorldName("."));
    try std.testing.expect(!isValidWorldName(".."));
    try std.testing.expect(!isValidWorldName("../etc"));
    try std.testing.expect(!isValidWorldName("a/b"));
    try std.testing.expect(!isValidWorldName("a b"));
    try std.testing.expect(!isValidWorldName("world!"));
    try std.testing.expect(!isValidWorldName("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"));
}
