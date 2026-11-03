const std = @import("std");

const Command = @import("../command.zig").Command;
const CommandContext = @import("../context.zig").CommandContext;
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const Tecton = @import("../../tecton.zig").Tecton;
const abi = @import("../../plugins/abi.zig");
const PluginSnapshot = @import("../../plugins/runtime.zig").PluginSnapshot;

pub fn register(registry: *CommandRegistry, tecton: *Tecton) !void {
    const cmd = try Command.init(
        registry.allocator,
        "plugins",
        "List loaded plugins and their diagnostics",
        "tecton.command.plugins",
        &.{},
        @ptrCast(&handle),
    );

    cmd.setUserdata(tecton);
    try registry.registerCommand(cmd);
}

fn handle(raw: *anyopaque) void {
    const ctx: *CommandContext = @ptrCast(@alignCast(raw));
    const tecton: *Tecton = @ptrCast(@alignCast(ctx.command_userdata orelse return));
    const snapshots = tecton.plugin_runtime.snapshotPlugins(ctx.allocator) catch {
        ctx.sendOutput(false, "Unable to read plugin diagnostics");
        return;
    };
    defer ctx.allocator.free(snapshots);

    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    formatTable(&writer, snapshots) catch {};
    ctx.sendOutput(true, writer.buffered());
}

pub fn formatTable(writer: *std.Io.Writer, snapshots: []const PluginSnapshot) !void {
    try writer.print("NAME                 STATE     ABI   REASON             EVENTS TIMERS  HANDLES  COMMANDS\n", .{});
    for (snapshots) |snapshot| {
        var abi_buffer: [16]u8 = undefined;
        const abi_text = if (snapshot.abi_major == 0 and snapshot.abi_minor == 0)
            "-"
        else
            std.fmt.bufPrint(&abi_buffer, "{d}.{d}", .{ snapshot.abi_major, snapshot.abi_minor }) catch "-";

        const name = if (snapshot.name.len == 0) "<unnamed>" else snapshot.name;
        try writer.print("{s:<20} {s:<9} {s:<5} {s:<18} {d:>6} {d:>7} {d:>8} {d:>9}\n", .{
            name,
            @tagName(snapshot.state),
            abi_text,
            abi.loadReasonName(snapshot.load_reason),
            snapshot.events_dispatched,
            snapshot.tasks_run,
            snapshot.handles_owned,
            snapshot.commands_owned,
        });
    }
}

test "plugin diagnostics table keeps state, abi, reason and counters" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const snapshots = [_]PluginSnapshot{
        .{
            .name = "tecton-example",
            .state = .running,
            .previous_state = .starting,
            .abi_major = 2,
            .abi_minor = 0,
            .fingerprint = 1,
            .required_features = 0,
            .optional_features = 0,
            .load_reason = abi.load_ok,
            .load_detail = "",
            .events_dispatched = 128,
            .tasks_run = 1,
            .handles_owned = 4,
            .commands_owned = 3,
        },
        .{
            .name = "legacy-thing",
            .state = .failed,
            .previous_state = .loading,
            .abi_major = 0,
            .abi_minor = 0,
            .fingerprint = 0,
            .required_features = 0,
            .optional_features = 0,
            .load_reason = abi.load_legacy_abi,
            .load_detail = "tecton_plugin_get_descriptor",
            .events_dispatched = 0,
            .tasks_run = 0,
            .handles_owned = 0,
            .commands_owned = 0,
        },
    };

    try formatTable(&writer, &snapshots);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tecton-example") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "128") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "legacy_abi") != null);
}
