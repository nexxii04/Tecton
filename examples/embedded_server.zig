const std = @import("std");
const tecton = @import("tecton");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var server = try tecton.Server.initWithOptions(init.io, allocator, try tecton.ServerProperties.load(init.io, allocator, "server.properties"), .{}, tecton.composition);
    defer server.deinit();

    try server.prepare();
    try server.start();
    defer server.shutdown() catch {};
    try server.run();
}
