const std = @import("std");

const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const WorldAdmin = @import("../context.zig").WorldAdmin;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const handlers = @import("world_handlers.zig");
const world_names = @import("world_names.zig");

pub const isValidWorldName = world_names.isValidWorldName;

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
        @ptrCast(&handlers.handle),
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
        .handler = @ptrCast(&handlers.handleCreate),
    };
    try cmd.registerSubCommand(create_sub);

    const load_sub = try registry.allocator.create(SubCommand);
    load_sub.* = .{
        .name = "load",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handlers.handleLoad),
    };
    try cmd.registerSubCommand(load_sub);

    const unload_sub = try registry.allocator.create(SubCommand);
    unload_sub.* = .{
        .name = "unload",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handlers.handleUnload),
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
        .handler = @ptrCast(&handlers.handleTp),
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

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const isValidWorldName = test_owner.isValidWorldName;
};

test "world name validation accepts safe names and rejects traversal" {
    try @import("world_test.zig").Suite(test_scope).case_000();
}
