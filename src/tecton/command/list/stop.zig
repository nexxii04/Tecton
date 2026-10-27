const log = @import("../../core/log.zig");
const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;

pub fn register(registry: *CommandRegistry) !void {
    const cmd = try Command.init(
        registry.allocator,
        "stop",
        "Stop the server",
        "tecton.command.stop",
        &.{},
        @ptrCast(&handle),
    );
    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    if (ctx.player) |p| {
        ctx.sendOutput(true, "\xc2\xa7cStopping server...");
        log.info("Server stop requested by {s}", .{p.username});
    } else {
        log.info("Server stop requested by Console", .{});
    }
    const view = ctx.views.shutdown;
    view.shutdown(view.ctx) catch |err| log.err("Server shutdown failed: {s}", .{@errorName(err)});
}
