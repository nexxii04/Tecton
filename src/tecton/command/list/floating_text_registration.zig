const command = @import("../command.zig");
const Command = command.Command;
const SubCommand = command.SubCommand;
const permission = @import("floating_text_args.zig").PERMISSION;

pub fn register(registry: anytype, handlers: anytype) !void {
    const name_enum_idx = try registry.registerEnum(.{
        .name = "FloatingTextName",
        .values = &.{},
        .owned = false,
    });

    const cmd = try Command.init(
        registry.allocator,
        "floatingtext",
        "Create and remove floating text holograms (operators only)",
        permission,
        &.{"ft"},
        @ptrCast(handlers.handle),
    );

    const add_sub = try registry.allocator.create(SubCommand);
    add_sub.* = .{
        .name = "add",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
            .{ .name = "text", .param_type = .Message, .optional = false },
        },
        .handler = @ptrCast(handlers.add),
    };
    try cmd.registerSubCommand(add_sub);

    const edit_sub = try registry.allocator.create(SubCommand);
    edit_sub.* = .{
        .name = "edit",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false, .enum_index = name_enum_idx },
            .{ .name = "text", .param_type = .Message, .optional = false },
        },
        .handler = @ptrCast(handlers.edit),
    };
    try cmd.registerSubCommand(edit_sub);

    const remove_sub = try registry.allocator.create(SubCommand);
    remove_sub.* = .{
        .name = "remove",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false, .enum_index = name_enum_idx },
        },
        .handler = @ptrCast(handlers.remove),
    };
    try cmd.registerSubCommand(remove_sub);

    const list_sub = try registry.allocator.create(SubCommand);
    list_sub.* = .{
        .name = "list",
        .aliases = &.{},
        .params = &.{},
        .handler = @ptrCast(handlers.list),
    };
    try cmd.registerSubCommand(list_sub);

    const info_sub = try registry.allocator.create(SubCommand);
    info_sub.* = .{
        .name = "info",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false, .enum_index = name_enum_idx },
        },
        .handler = @ptrCast(handlers.info),
    };
    try cmd.registerSubCommand(info_sub);

    try registry.registerCommand(cmd);
}
