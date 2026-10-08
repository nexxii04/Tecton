const std = @import("std");

const Protocol = @import("protocol");

const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const FloatingTextManager = @import("../../entity/floating_text.zig").FloatingTextManager;
const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub const PERMISSION: []const u8 = "tecton.command.floatingtext";
pub const MAX_NAME_LENGTH: usize = 32;
pub const MAX_TEXT_LENGTH: usize = 1024;

pub const AddArgs = struct {
    name: []const u8,
    text: []const u8,
};

pub const NameError = error{
    MissingName,
    InvalidName,
    NameTooLong,
};

pub const AddArgsError = NameError || error{
    MissingText,
    TextTooLong,
};

pub const TextError = error{
    EmptyText,
    InvalidText,
};

pub fn hasValidNameCharacters(name: []const u8) bool {
    for (name) |byte| {
        const is_alpha = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
        const is_digit = byte >= '0' and byte <= '9';
        if (!is_alpha and !is_digit and byte != '_' and byte != '-' and byte != '.') return false;
    }
    return true;
}

pub fn validateText(text: []const u8) TextError!void {
    var has_content = false;
    for (text) |byte| {
        if (byte == 0x7f) return error.InvalidText;
        if (byte < 0x20) {
            if (byte != '\n') return error.InvalidText;
            continue;
        }
        if (byte != ' ') has_content = true;
    }
    if (!has_content) return error.EmptyText;
}

pub fn parseAddArgs(args: []const u8) AddArgsError!AddArgs {
    const trimmed = std.mem.trimStart(u8, args, " ");
    const name_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.MissingName;
    const name = trimmed[0..name_end];
    const text = std.mem.trim(u8, trimmed[name_end + 1 ..], " ");

    if (name.len == 0) return error.MissingName;
    if (name.len > MAX_NAME_LENGTH) return error.NameTooLong;
    if (!hasValidNameCharacters(name)) return error.InvalidName;
    if (text.len == 0) return error.MissingText;
    if (text.len > MAX_TEXT_LENGTH) return error.TextTooLong;

    return .{ .name = name, .text = text };
}

pub fn parseRemoveArgs(args: []const u8) NameError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " ");
    const name_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const name = trimmed[0..name_end];

    if (name.len == 0) return error.MissingName;
    if (name.len > MAX_NAME_LENGTH) return error.NameTooLong;
    if (!hasValidNameCharacters(name)) return error.InvalidName;

    return name;
}

pub fn register(registry: *CommandRegistry) !void {
    const name_enum_idx = try registry.registerEnum(.{
        .name = "FloatingTextName",
        .values = &.{},
        .owned = false,
    });

    const cmd = try Command.init(
        registry.allocator,
        "floatingtext",
        "Create and remove floating text holograms (operators only)",
        PERMISSION,
        &.{"ft"},
        @ptrCast(&handle),
    );

    const add_sub = try registry.allocator.create(SubCommand);
    add_sub.* = .{
        .name = "add",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
            .{ .name = "text", .param_type = .Message, .optional = false },
        },
        .handler = @ptrCast(&handleAdd),
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
        .handler = @ptrCast(&handleEdit),
    };
    try cmd.registerSubCommand(edit_sub);

    const remove_sub = try registry.allocator.create(SubCommand);
    remove_sub.* = .{
        .name = "remove",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false, .enum_index = name_enum_idx },
        },
        .handler = @ptrCast(&handleRemove),
    };
    try cmd.registerSubCommand(remove_sub);

    const list_sub = try registry.allocator.create(SubCommand);
    list_sub.* = .{
        .name = "list",
        .aliases = &.{},
        .params = &.{},
        .handler = @ptrCast(&handleList),
    };
    try cmd.registerSubCommand(list_sub);

    const info_sub = try registry.allocator.create(SubCommand);
    info_sub.* = .{
        .name = "info",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false, .enum_index = name_enum_idx },
        },
        .handler = @ptrCast(&handleInfo),
    };
    try cmd.registerSubCommand(info_sub);

    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    ctx.sendOutput(false, "Usage: /floatingtext add <name> <text> | /floatingtext edit <name> <text> | " ++
        "/floatingtext remove <name> | /floatingtext list | /floatingtext info <name>");
}

fn handleAdd(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const player = ctx.player orelse {
        ctx.sendOutput(false, "This command can only be used by a player");
        return;
    };
    const dimension = player.entity.dimension orelse {
        ctx.sendOutput(false, "Player is not in a dimension");
        return;
    };
    const manager = dimension.floating_texts orelse {
        ctx.sendOutput(false, "Floating text is not available in this dimension");
        return;
    };

    const parsed = parseAddArgs(ctx.args) catch |err| {
        sendTextArgsError(ctx, err, "Usage: /floatingtext add <name> <text>");
        return;
    };

    const text = Protocol.FloatingText.decodeEscapes(ctx.allocator, parsed.text) catch {
        ctx.sendOutput(false, "Failed to create floating text");
        return;
    };
    defer ctx.allocator.free(text);

    validateText(text) catch |err| {
        sendTextError(ctx, err);
        return;
    };

    _ = manager.add(parsed.name, text, player.entity.position) catch |err| {
        switch (err) {
            error.FloatingTextAlreadyExists => ctx.sendOutput(false, "A floating text with that name already exists"),
            error.FloatingTextLimitReached => ctx.sendOutput(false, "This dimension reached the floating text limit"),
            else => ctx.sendOutput(false, "Failed to create floating text"),
        }
        return;
    };
    ctx.tecton.refreshFloatingTextCommandEnums();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' created", .{parsed.name}) catch return;
    ctx.sendOutput(true, msg);
}

fn sendTextArgsError(ctx: *CommandContext, err: AddArgsError, usage: []const u8) void {
    switch (err) {
        error.MissingName => ctx.sendOutput(false, usage),
        error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
        error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
        error.MissingText => ctx.sendOutput(false, "Floating text cannot be empty"),
        error.TextTooLong => ctx.sendOutput(false, "Floating text is too long"),
    }
}

fn sendTextError(ctx: *CommandContext, err: TextError) void {
    switch (err) {
        error.EmptyText => ctx.sendOutput(false, "Floating text cannot be empty"),
        error.InvalidText => ctx.sendOutput(false, "Floating text contains invalid characters"),
    }
}

fn handleEdit(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const parsed = parseAddArgs(ctx.args) catch |err| {
        sendTextArgsError(ctx, err, "Usage: /floatingtext edit <name> <text>");
        return;
    };

    const text = Protocol.FloatingText.decodeEscapes(ctx.allocator, parsed.text) catch {
        ctx.sendOutput(false, "Failed to update floating text");
        return;
    };
    defer ctx.allocator.free(text);

    validateText(text) catch |err| {
        sendTextError(ctx, err);
        return;
    };

    const manager = findManager(ctx.tecton, ctx.player, parsed.name) orelse {
        reportNotFound(ctx, parsed.name);
        return;
    };

    _ = manager.edit(parsed.name, text) catch {
        ctx.sendOutput(false, "Failed to update floating text");
        return;
    };

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' updated", .{parsed.name}) catch return;
    ctx.sendOutput(true, msg);
}

fn reportNotFound(ctx: *CommandContext, name: []const u8) void {
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' not found", .{name}) catch return;
    ctx.sendOutput(false, msg);
}

fn sendNameError(ctx: *CommandContext, err: NameError, usage: []const u8) void {
    switch (err) {
        error.MissingName => ctx.sendOutput(false, usage),
        error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
        error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
    }
}

fn handleList(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    if (ctx.player) |player| {
        const dimension = player.entity.dimension orelse {
            ctx.sendOutput(false, "Player is not in a dimension");
            return;
        };
        std.Io.Writer.print(&out.writer, "Floating texts in §b{s}§7:", .{dimension.identifier}) catch return;
        writeDimensionHolograms(&out.writer, dimension) catch return;
        ctx.sendOutput(true, out.written());
        return;
    }

    const tecton = ctx.tecton;
    std.Io.Writer.writeAll(&out.writer, "Floating texts:") catch return;
    var world_it = tecton.worlds.valueIterator();
    while (world_it.next()) |world| {
        var dimension_it = world.*.dimensions.valueIterator();
        while (dimension_it.next()) |dimension| {
            const manager = dimension.*.floating_texts orelse continue;
            if (manager.items().len == 0) continue;
            std.Io.Writer.print(&out.writer, "\n§f{s} §8[§7{s}§8]§7:", .{ world.*.identifier, dimension.*.identifier }) catch return;
            writeDimensionHolograms(&out.writer, dimension.*) catch return;
        }
    }
    ctx.sendOutput(true, out.written());
}

fn handleInfo(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        sendNameError(ctx, err, "Usage: /floatingtext info <name>");
        return;
    };

    const manager = findManager(ctx.tecton, ctx.player, name) orelse {
        reportNotFound(ctx, name);
        return;
    };
    const hologram = manager.find(name) orelse {
        reportNotFound(ctx, name);
        return;
    };

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    std.Io.Writer.print(
        &out.writer,
        "§6Floating text §f{s}\n§7World: §f{s} §8[§7{s}§8]\n§7Position: §a{d:.1}§7,§a{d:.1}§7,§a{d:.1}\n§7Runtime Id: §f{d} §7Viewers: §f{d}\n§7Text:\n§f{s}",
        .{
            hologram.name,
            hologram.dimension.world.identifier,
            hologram.dimension.identifier,
            hologram.position.x,
            hologram.position.y,
            hologram.position.z,
            hologram.runtime_id,
            hologram.viewers.count(),
            hologram.text,
        },
    ) catch return;

    ctx.sendOutput(true, out.written());
}

fn writeDimensionHolograms(writer: *std.Io.Writer, dimension: *const Dimension) !void {
    const manager = dimension.floating_texts orelse {
        try std.Io.Writer.writeAll(writer, " §7(none)");
        return;
    };
    if (manager.items().len == 0) {
        try std.Io.Writer.writeAll(writer, " §7(none)");
        return;
    }
    for (manager.items()) |hologram| {
        try writeHologramLine(writer, hologram.name, hologram.position, hologram.viewers.count());
    }
}

fn writeHologramLine(writer: *std.Io.Writer, name: []const u8, position: Protocol.Vector3f, viewers: usize) !void {
    try std.Io.Writer.print(writer, "\n  §b{s}§r §8- §a{d:.1}§7,§a{d:.1}§7,§a{d:.1}§r §8(§7viewers: §f{d}§8)", .{
        name,
        position.x,
        position.y,
        position.z,
        viewers,
    });
}

fn handleRemove(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        sendNameError(ctx, err, "Usage: /floatingtext remove <name>");
        return;
    };

    const tecton = ctx.tecton;
    const manager = findManager(tecton, ctx.player, name) orelse {
        reportNotFound(ctx, name);
        return;
    };

    manager.remove(name) catch {
        ctx.sendOutput(false, "Failed to remove floating text");
        return;
    };
    tecton.refreshFloatingTextCommandEnums();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' removed", .{name}) catch return;
    ctx.sendOutput(true, msg);
}

fn findManager(tecton: *Tecton, player: ?*Player, name: []const u8) ?*FloatingTextManager {
    if (player) |p| {
        if (p.entity.dimension) |dimension| {
            if (dimension.floating_texts) |manager| {
                if (manager.find(name) != null) return manager;
            }
        }
    }

    var world_it = tecton.worlds.valueIterator();
    while (world_it.next()) |world| {
        var dimension_it = world.*.dimensions.valueIterator();
        while (dimension_it.next()) |dimension| {
            if (dimension.*.floating_texts) |manager| {
                if (manager.find(name) != null) return manager;
            }
        }
    }
    return null;
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const CommandRegistry = test_owner.CommandRegistry;
    pub const MAX_NAME_LENGTH = test_owner.MAX_NAME_LENGTH;
    pub const MAX_TEXT_LENGTH = test_owner.MAX_TEXT_LENGTH;
    pub const hasValidNameCharacters = test_owner.hasValidNameCharacters;
    pub const validateText = test_owner.validateText;
    pub const parseAddArgs = test_owner.parseAddArgs;
    pub const parseRemoveArgs = test_owner.parseRemoveArgs;
    pub const register = test_owner.register;
    pub const writeHologramLine = test_owner.writeHologramLine;
};

test "parseAddArgs keeps free text with spaces and color codes" {
    try @import("floating_text_test.zig").Suite(test_scope).case_000();
}

test "parseAddArgs rejects missing and oversized pieces" {
    try @import("floating_text_test.zig").Suite(test_scope).case_001();
}

test "parseAddArgs rejects names with unsafe characters" {
    try @import("floating_text_test.zig").Suite(test_scope).case_002();
}

test "parseRemoveArgs reads a single name" {
    try @import("floating_text_test.zig").Suite(test_scope).case_003();
}

test "validateText accepts line breaks and color codes only" {
    try @import("floating_text_test.zig").Suite(test_scope).case_004();
}

test "escaped line breaks become real nametag lines" {
    try @import("floating_text_test.zig").Suite(test_scope).case_005();
}

test "register wires the hologram name enum into the name arguments" {
    try @import("floating_text_test.zig").Suite(test_scope).case_006();
}

test "listing line reports name, position and viewers" {
    try @import("floating_text_test.zig").Suite(test_scope).case_007();
}

test "edit rejects text that decodes into blank lines" {
    try @import("floating_text_test.zig").Suite(test_scope).case_008();
}
