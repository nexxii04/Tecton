const std = @import("std");
const builtin = @import("builtin");

var shutdown_requested: std.atomic.Value(bool) = .init(false);

pub fn isShutdownRequested() bool {
    return shutdown_requested.load(.acquire);
}

pub fn install() void {
    switch (builtin.os.tag) {
        .windows => installWindows(),
        else => installPosix(),
    }
}

fn installPosix() void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    if (shutdown_requested.swap(true, .seq_cst)) {
        var dfl = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &dfl, null);
        std.posix.raise(sig) catch {};
    }
}

const windows = if (builtin.os.tag == .windows) struct {
    const w32 = std.os.windows;
    const HandlerRoutine = *const fn (u32) callconv(.winapi) w32.BOOL;
    const CTRL_C_EVENT: u32 = 0;
    const CTRL_CLOSE_EVENT: u32 = 2;

    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: w32.BOOL) callconv(.winapi) w32.BOOL;
} else struct {};

fn installWindows() void {
    if (builtin.os.tag != .windows) return;
    _ = windows.SetConsoleCtrlHandler(ctrlHandler, 1);
}

fn ctrlHandler(ctrl_type: u32) callconv(.winapi) std.os.windows.BOOL {
    if (shutdown_requested.swap(true, .seq_cst)) return 0;
    _ = ctrl_type;
    return 1;
}

test "first shutdown signal sets the shutdown flag" {
    if (comptime builtin.os.tag == .windows) return;
    shutdown_requested.store(false, .seq_cst);
    onSignal(.INT);
    try std.testing.expect(isShutdownRequested());
    shutdown_requested.store(false, .seq_cst);
}
