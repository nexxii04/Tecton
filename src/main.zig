const std = @import("std");
const builtin = @import("builtin");
const Conduit = @import("conduit").Conduit;

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

        var conduit = try Conduit.init(io, allocator);
        defer conduit.deinit();

        try conduit.start();

        while (conduit.raknet.running) {
            try io.sleep(.fromNanoseconds(std.time.ns_per_s / 20), .awake);
        }
    } else {
        const allocator = std.heap.c_allocator;

        var conduit = try Conduit.init(io, allocator);
        defer conduit.deinit();

        try conduit.start();

        while (conduit.raknet.running) {
            try io.sleep(.fromNanoseconds(std.time.ns_per_s / 20), .awake);
        }
    }
}
