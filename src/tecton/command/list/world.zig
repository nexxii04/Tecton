const std = @import("std");

const Raknet = @import("Raknet");

const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const World = @import("../../world/world.zig").World;
const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const CommandContext = @import("../context.zig").CommandContext;
const WorldAdmin = @import("../context.zig").WorldAdmin;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub fn register(registry: *CommandRegistry, world_admin: WorldAdmin) !void {
    const world_enum_idx = try registerWorldEnum(registry, world_admin);
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

fn registerWorldEnum(registry: *CommandRegistry, world_admin: WorldAdmin) !u32 {
    var names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer if (names.capacity > 0) names.deinit(registry.allocator);

    try world_admin.collectWorldNames(registry.allocator, &names);

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

    const world = ctx.views.world_admin.get(world_name) orelse {
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
    const world_admin = ctx.views.world_admin;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world create <name>");
        return;
    }
    if (!isValidWorldName(name)) {
        ctx.sendOutput(false, "Invalid world name: use 1-32 letters, digits, '_' or '-'");
        return;
    }
    if (world_admin.has(name)) {
        ctx.sendOutput(false, "World already exists");
        return;
    }
    if (world_admin.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (world_admin.worldDirExists(name)) {
        ctx.sendOutput(false, "World already exists on disk; use /world load <name> instead");
        return;
    }

    const owned_name = world_admin.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!world_admin.beginOp(owned_name)) {
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    world_admin.queueCreate(
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        world_admin.endOp(owned_name);
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world creation");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Creating world '{s}'...", .{name}) catch "Creating world...";
    ctx.sendOutput(true, message);
}

fn handleLoad(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const world_admin = ctx.views.world_admin;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world load <name>");
        return;
    }
    if (!isValidWorldName(name)) {
        ctx.sendOutput(false, "Invalid world name: use 1-32 letters, digits, '_' or '-'");
        return;
    }
    if (world_admin.has(name)) {
        ctx.sendOutput(false, "World already loaded");
        return;
    }
    if (world_admin.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (!world_admin.worldDirExists(name)) {
        ctx.sendOutput(false, "World not found on disk");
        return;
    }

    const owned_name = world_admin.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!world_admin.beginOp(owned_name)) {
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    world_admin.queueLoad(
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        world_admin.endOp(owned_name);
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world load");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Loading world '{s}'...", .{name}) catch "Loading world...";
    ctx.sendOutput(true, message);
}

fn handleUnload(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const world_admin = ctx.views.world_admin;
    const name = std.mem.trim(u8, ctx.args, " ");

    if (name.len == 0) {
        ctx.sendOutput(false, "Usage: /world unload <name>");
        return;
    }

    const world = world_admin.get(name) orelse {
        ctx.sendOutput(false, "World not found");
        return;
    };
    if (world_admin.count() <= 1) {
        ctx.sendOutput(false, "Cannot unload the only world");
        return;
    }
    if (world_admin.opInFlight(name)) {
        ctx.sendOutput(false, "A world operation is already in progress for that name");
        return;
    }
    if (countPlayersInWorld(ctx, world) > 0) {
        ctx.sendOutput(false, "Cannot unload a world with players inside");
        return;
    }

    const owned_name = world_admin.allocator.dupe(u8, name) catch {
        ctx.sendOutput(false, "Out of memory");
        return;
    };
    if (!world_admin.beginOp(owned_name)) {
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Out of memory");
        return;
    }

    world_admin.detach(world);
    world.unloading = true;

    world_admin.queueUnload(
        world,
        owned_name,
        ctx.player,
        ctx.origin_type,
        ctx.uuid,
        ctx.request_id,
    ) catch {
        world.unloading = false;
        world_admin.adopt(world) catch |err| {
            Raknet.Logger.ERROR("Failed to restore world '{s}' after unload enqueue failure: {any}", .{ name, err });
        };
        world_admin.endOp(owned_name);
        world_admin.allocator.free(owned_name);
        ctx.sendOutput(false, "Failed to start world unload");
        return;
    };

    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Unloading world '{s}'...", .{name}) catch "Unloading world...";
    ctx.sendOutput(true, message);
}

fn countPlayersInWorld(ctx: *CommandContext, world: *World) usize {
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

fn resolveWorldDimension(world: *World, requested: ?[]const u8) ?*Dimension {
    if (requested) |name| return world.getDimension(name);
    if (world.getDimension("overworld")) |dimension| return dimension;
    var it = world.dimensions.valueIterator();
    const entry = it.next() orelse return null;
    return entry.*;
}

fn handleTp(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const world_admin = ctx.views.world_admin;
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

    const world = world_admin.get(world_token) orelse {
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

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const isValidWorldName = test_owner.isValidWorldName;
};

test "world name validation accepts safe names and rejects traversal" {
    try @import("world_test.zig").Suite(test_scope).case_000();
}
