const std = @import("std");
const builtin = @import("builtin");
const Server = @import("tecton").Server;
const defaultOptions = @import("tecton").defaultOptions;
const pool_allocator = @import("tecton").pool_allocator;

const winmm = if (builtin.os.tag == .windows) struct {
    extern "winmm" fn timeBeginPeriod(uPeriod: c_uint) callconv(.winapi) c_uint;
    extern "winmm" fn timeEndPeriod(uPeriod: c_uint) callconv(.winapi) c_uint;
} else struct {};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    if (builtin.os.tag == .windows) {
        _ = winmm.timeBeginPeriod(1);
    }
    const is_debug = @import("builtin").mode == .Debug;

    if (is_debug) {
        var gpa = std.heap.DebugAllocator(.{}){};
        const allocator = gpa.allocator();
        defer {
            const leaked = gpa.deinit();
            if (leaked == .leak) {
                std.debug.print("Memory leak detected!\n", .{});
            } else {
                std.debug.print("No memory leak detected!\n", .{});
            }
        }

        var server = try Server.init(defaultOptions(io, allocator));
        defer server.deinit();

        try server.start();
        try server.run();
    } else {
        // The shared pool recycles frees across threads instead of stranding them on the freeing thread.
        const allocator = pool_allocator.allocator();

        var server = try Server.init(defaultOptions(io, allocator));
        defer server.deinit();

        try server.start();
        try server.run();
    }
}
