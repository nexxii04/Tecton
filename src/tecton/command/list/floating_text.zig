const std = @import("std");

const Protocol = @import("protocol");

const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const Dimension = @import("../../world/dimension/dimension.zig").Dimension;
const FloatingTextManager = @import("../../entity/floating_text.zig").FloatingTextManager;
const registration = @import("floating_text_registration.zig");
const output = @import("floating_text_output.zig");
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

const text_args = @import("floating_text_args.zig");
pub const PERMISSION = text_args.PERMISSION;
pub const MAX_NAME_LENGTH = text_args.MAX_NAME_LENGTH;
pub const MAX_TEXT_LENGTH = text_args.MAX_TEXT_LENGTH;
pub const AddArgs = text_args.AddArgs;
pub const NameError = text_args.NameError;
pub const AddArgsError = text_args.AddArgsError;
pub const TextError = text_args.TextError;
pub const hasValidNameCharacters = text_args.has_valid_name_characters;
pub const validateText = text_args.validate_text;
pub const parseAddArgs = text_args.parse_add_args;
pub const parseRemoveArgs = text_args.parse_remove_args;
const writeHologramLine = text_args.write_hologram_line;

pub fn register(registry: *CommandRegistry) !void {
    try registration.register(registry, .{
        .handle = &handle,
        .add = &handleAdd,
        .edit = &handleEdit,
        .remove = &handleRemove,
        .list = &handleList,
        .info = &handleInfo,
    });
}

pub fn bind(registry: *CommandRegistry, tecton: *Tecton) void {
    registry.findCommand("floatingtext").?.setUserdata(tecton);
}

fn commandServer(ctx: *CommandContext) *Tecton {
    return @ptrCast(@alignCast(ctx.command_userdata.?));
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
        output.send_text_args_error(ctx, err, "Usage: /floatingtext add <name> <text>");
        return;
    };

    const text = Protocol.FloatingText.decodeEscapes(ctx.allocator, parsed.text) catch {
        ctx.sendOutput(false, "Failed to create floating text");
        return;
    };
    defer ctx.allocator.free(text);

    validateText(text) catch |err| {
        output.send_text_error(ctx, err);
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
    commandServer(ctx).refreshFloatingTextCommandEnums();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' created", .{parsed.name}) catch return;
    ctx.sendOutput(true, msg);
}

fn handleEdit(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const parsed = parseAddArgs(ctx.args) catch |err| {
        output.send_text_args_error(ctx, err, "Usage: /floatingtext edit <name> <text>");
        return;
    };

    const text = Protocol.FloatingText.decodeEscapes(ctx.allocator, parsed.text) catch {
        ctx.sendOutput(false, "Failed to update floating text");
        return;
    };
    defer ctx.allocator.free(text);

    validateText(text) catch |err| {
        output.send_text_error(ctx, err);
        return;
    };

    const manager = findManager(commandServer(ctx), ctx.player, parsed.name) orelse {
        output.report_not_found(ctx, parsed.name);
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

    const tecton = commandServer(ctx);
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
        output.send_name_error(ctx, err, "Usage: /floatingtext info <name>");
        return;
    };

    const manager = findManager(commandServer(ctx), ctx.player, name) orelse {
        output.report_not_found(ctx, name);
        return;
    };
    const hologram = manager.find(name) orelse {
        output.report_not_found(ctx, name);
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

fn handleRemove(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        output.send_name_error(ctx, err, "Usage: /floatingtext remove <name>");
        return;
    };

    const tecton = commandServer(ctx);
    const manager = findManager(tecton, ctx.player, name) orelse {
        output.report_not_found(ctx, name);
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
    pub const output = test_owner.output;
    pub const handle = test_owner.handle;
    pub const handle_add = test_owner.handleAdd;
    pub const handle_edit = test_owner.handleEdit;
    pub const handle_remove = test_owner.handleRemove;
    pub const handle_list = test_owner.handleList;
    pub const handle_info = test_owner.handleInfo;
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

test "floating text diagnostics retain their exact output" {
    try @import("floating_text_test.zig").Suite(test_scope).case_009();
}
