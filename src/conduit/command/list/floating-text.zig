const std = @import("std");

const Protocol = @import("protocol");

const Conduit = @import("../../conduit.zig").Conduit;
const Player = @import("../../player/player.zig").Player;
const FloatingTextManager = @import("../../entity/floating-text.zig").FloatingTextManager;
const Command = @import("../command.zig").Command;
const SubCommand = @import("../command.zig").SubCommand;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub const PERMISSION: []const u8 = "conduit.command.floatingtext";
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

    const remove_sub = try registry.allocator.create(SubCommand);
    remove_sub.* = .{
        .name = "remove",
        .aliases = &.{},
        .params = &.{
            .{ .name = "name", .param_type = .String, .optional = false },
        },
        .handler = @ptrCast(&handleRemove),
    };
    try cmd.registerSubCommand(remove_sub);

    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    ctx.sendOutput(false, "Usage: /floatingtext add <name> <text> | /floatingtext remove <name>");
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
        sendAddError(ctx, err);
        return;
    };

    const text = Protocol.FloatingText.decodeEscapes(ctx.allocator, parsed.text) catch {
        ctx.sendOutput(false, "Failed to create floating text");
        return;
    };
    defer ctx.allocator.free(text);

    validateText(text) catch |err| {
        switch (err) {
            error.EmptyText => ctx.sendOutput(false, "Floating text cannot be empty"),
            error.InvalidText => ctx.sendOutput(false, "Floating text contains invalid characters"),
        }
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

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' created", .{parsed.name}) catch return;
    ctx.sendOutput(true, msg);
}

fn sendAddError(ctx: *CommandContext, err: AddArgsError) void {
    switch (err) {
        error.MissingName => ctx.sendOutput(false, "Usage: /floatingtext add <name> <text>"),
        error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
        error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
        error.MissingText => ctx.sendOutput(false, "Floating text cannot be empty"),
        error.TextTooLong => ctx.sendOutput(false, "Floating text is too long"),
    }
}

fn handleRemove(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        switch (err) {
            error.MissingName => ctx.sendOutput(false, "Usage: /floatingtext remove <name>"),
            error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
            error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
        }
        return;
    };

    const conduit = ctx.network.conduit;
    const manager = findManager(conduit, ctx.player, name) orelse {
        var not_found_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&not_found_buf, "Floating text '{s}' not found", .{name}) catch return;
        ctx.sendOutput(false, msg);
        return;
    };

    manager.remove(name) catch {
        ctx.sendOutput(false, "Failed to remove floating text");
        return;
    };

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' removed", .{name}) catch return;
    ctx.sendOutput(true, msg);
}

fn findManager(conduit: *Conduit, player: ?*Player, name: []const u8) ?*FloatingTextManager {
    if (player) |p| {
        if (p.entity.dimension) |dimension| {
            if (dimension.floating_texts) |manager| {
                if (manager.find(name) != null) return manager;
            }
        }
    }

    var world_it = conduit.worlds.valueIterator();
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

test "parseAddArgs keeps free text with spaces and color codes" {
    const parsed = try parseAddArgs("  shop  \xc2\xa77Tienda    abierta  ");
    try std.testing.expectEqualStrings("shop", parsed.name);
    try std.testing.expectEqualStrings("\xc2\xa77Tienda    abierta", parsed.text);
}

test "parseAddArgs rejects missing and oversized pieces" {
    try std.testing.expectError(error.MissingName, parseAddArgs(""));
    try std.testing.expectError(error.MissingName, parseAddArgs("onlyname"));
    try std.testing.expectError(error.MissingText, parseAddArgs("shop   "));
    const long_name = "x" ** (MAX_NAME_LENGTH + 1);
    try std.testing.expectError(error.NameTooLong, parseAddArgs(long_name ++ " text"));
    const long_text = "y" ** (MAX_TEXT_LENGTH + 1);
    try std.testing.expectError(error.TextTooLong, parseAddArgs("shop " ++ long_text));
}

test "parseAddArgs rejects names with unsafe characters" {
    try std.testing.expectError(error.InvalidName, parseAddArgs("ba\xc2\xa7d text"));
    try std.testing.expectError(error.InvalidName, parseAddArgs("bad/name text"));
    try std.testing.expectError(error.InvalidName, parseAddArgs("\x1btext more"));
    try std.testing.expect(hasValidNameCharacters("shop_1.2-a"));
}

test "parseRemoveArgs reads a single name" {
    try std.testing.expectEqualStrings("shop", try parseRemoveArgs("  shop  "));
    try std.testing.expectError(error.MissingName, parseRemoveArgs("   "));
    const long_name = "x" ** (MAX_NAME_LENGTH + 1);
    try std.testing.expectError(error.NameTooLong, parseRemoveArgs(long_name));
    try std.testing.expectError(error.InvalidName, parseRemoveArgs("bad/name"));
}

test "validateText accepts line breaks and color codes only" {
    try validateText("Hola\n\xc2\xa77mundo");
    try std.testing.expectError(error.EmptyText, validateText("\n   \n"));
    try std.testing.expectError(error.InvalidText, validateText("Hola\tMundo"));
    try std.testing.expectError(error.InvalidText, validateText("Hola\x1bMundo"));
    try std.testing.expectError(error.InvalidText, validateText("Hola\x7fMundo"));
}

test "escaped line breaks become real nametag lines" {
    const allocator = std.testing.allocator;

    const decoded = try Protocol.FloatingText.decodeEscapes(allocator, "Linea 1\\nLinea 2");
    defer allocator.free(decoded);
    try validateText(decoded);

    const name_tag = try Protocol.FloatingText.composeNameTag(allocator, "", decoded);
    defer allocator.free(name_tag);
    try std.testing.expectEqualStrings("Linea 1\nLinea 2", name_tag);
}
