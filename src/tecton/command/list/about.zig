const std = @import("std");
const builtin = @import("builtin");

const Protocol = @import("protocol");

const version = @import("../../version.zig").version;
const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub fn register(registry: *CommandRegistry) !void {
    const cmd = try Command.init(
        registry.allocator,
        "about",
        "Show server information",
        "",
        &.{},
        @ptrCast(&handle),
    );
    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton = ctx.tecton;
    const snapshots = tecton.getPlayerSnapshots();

    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    std.Io.Writer.print(
        &writer,
        "§7--------- §bTecton §7---------§r\n" ++
            "§fA Minecraft Bedrock server written in §6Zig§r\n" ++
            "§7Version: §a" ++ version ++ "§r\n" ++
            "§7Client: §f" ++ Protocol.MINECRAFT_VERSION ++ " §8(protocol §f{d}§8)§r\n" ++
            "§7License: §fMIT §7GitHub: §bhttps://github.com/nexxii04/Tecton§r\n" ++
            "§7Zig: §f" ++ builtin.zig_version_string ++ " §7Build: §f" ++ @tagName(builtin.mode) ++
            " §7Platform: §f" ++ @tagName(builtin.os.tag) ++ " (" ++ @tagName(builtin.cpu.arch) ++ ")§r\n" ++
            "§7Players: §f{d}§7/§f{d}",
        .{ Protocol.PROTOCOL, snapshots.len, tecton.config.max_players },
    ) catch return;

    ctx.sendOutput(true, writer.buffered());
}
