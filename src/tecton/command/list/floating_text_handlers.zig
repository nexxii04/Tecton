const std = @import("std");

const Protocol = @import("protocol");

const world_root = @import("../../world/root.zig");
const Dimension = world_root.Dimension;
const entity_root = @import("../../entity/root.zig");
const FloatingTextManager = entity_root.FloatingTextManager;
const CommandContext = @import("../context.zig").CommandContext;
const text_args = @import("floating_text_args.zig");
const output = @import("floating_text_output.zig");

const parseAddArgs = text_args.parse_add_args;
const parseRemoveArgs = text_args.parse_remove_args;
const validateText = text_args.validate_text;
const writeHologramLine = text_args.write_hologram_line;

pub const writeDimensionHolograms = writeDimensionHologramsInner;

pub fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    ctx.sendOutput(false, "Usage: /floatingtext add <name> <text> | /floatingtext edit <name> <text> | " ++
        "/floatingtext remove <name> | /floatingtext list | /floatingtext info <name>");
}

pub fn handleAdd(raw: *anyopaque) void {
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
    ctx.views.floating_text.refreshCommandEnums();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' created", .{parsed.name}) catch return;
    ctx.sendOutput(true, msg);
}

pub fn handleEdit(raw: *anyopaque) void {
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

    const manager = findManager(ctx, parsed.name) orelse {
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

pub fn handleList(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();

    if (ctx.player) |player| {
        const dimension = player.entity.dimension orelse {
            ctx.sendOutput(false, "Player is not in a dimension");
            return;
        };
        std.Io.Writer.print(&out.writer, "Floating texts in §b{s}§7:", .{dimension.identifier}) catch return;
        writeDimensionHologramsInner(&out.writer, dimension) catch return;
        ctx.sendOutput(true, out.written());
        return;
    }

    const worlds = ctx.views.floating_text.worlds;
    std.Io.Writer.writeAll(&out.writer, "Floating texts:") catch return;
    var world_it = worlds.valueIterator();
    while (world_it.next()) |world| {
        var dimension_it = world.*.dimensions.valueIterator();
        while (dimension_it.next()) |dimension| {
            const manager = dimension.*.floating_texts orelse continue;
            if (manager.items().len == 0) continue;
            std.Io.Writer.print(&out.writer, "\n§f{s} §8[§7{s}§8]§7:", .{ world.*.identifier, dimension.*.identifier }) catch return;
            writeDimensionHologramsInner(&out.writer, dimension.*) catch return;
        }
    }
    ctx.sendOutput(true, out.written());
}

pub fn handleInfo(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        output.send_name_error(ctx, err, "Usage: /floatingtext info <name>");
        return;
    };

    const manager = findManager(ctx, name) orelse {
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

fn writeDimensionHologramsInner(writer: *std.Io.Writer, dimension: *const Dimension) !void {
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

pub fn handleRemove(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));

    const name = parseRemoveArgs(ctx.args) catch |err| {
        output.send_name_error(ctx, err, "Usage: /floatingtext remove <name>");
        return;
    };

    const manager = findManager(ctx, name) orelse {
        output.report_not_found(ctx, name);
        return;
    };

    manager.remove(name) catch {
        ctx.sendOutput(false, "Failed to remove floating text");
        return;
    };
    ctx.views.floating_text.refreshCommandEnums();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' removed", .{name}) catch return;
    ctx.sendOutput(true, msg);
}

pub fn findManager(ctx: *CommandContext, name: []const u8) ?*FloatingTextManager {
    if (ctx.player) |p| {
        if (p.entity.dimension) |dimension| {
            if (dimension.floating_texts) |manager| {
                if (manager.find(name) != null) return manager;
            }
        }
    }

    var world_it = ctx.views.floating_text.worlds.valueIterator();
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
