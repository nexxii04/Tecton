const std = @import("std");
const conduit = @import("conduit");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    var server = try conduit.Server.initWithOptions(init.io, allocator, try conduit.ServerProperties.load(init.io, allocator, "server.properties"), .{});
    defer server.deinit();

    try server.prepare();
    try server.start();
    defer server.shutdown() catch {};
    try server.run();
}
