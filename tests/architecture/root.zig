test "internal module roots expose their existing types" {
    _ = @import("tecton/core/root.zig").ServerProperties;
    _ = @import("tecton/auth/root.zig").AuthService;
    _ = @import("tecton/transport/root.zig").NetworkHandler;
    _ = @import("tecton/tasks/root.zig").ThreadedTaskQueue;
    _ = @import("tecton/server/root.zig").ServerOptions;
    _ = @import("tecton/console/root.zig").console;
    _ = @import("tecton/command/list/root.zig").about;
    _ = @import("tecton/network/handlers/root.zig").request_network_settings;
    _ = @import("tecton/world/block/traits/root.zig").BlockTrait;
    _ = @import("tecton/world/chunk/root.zig").Chunk;
    _ = @import("tecton/world/chunk/storage/root.zig").BlockStorage;
    _ = @import("tecton/world/dimension/root.zig").Dimension;
}

test "R4 leaf roots preserve public type identity" {
    const std = @import("std");
    try std.testing.expect(@import("tecton/network/root.zig").NetworkHandler == @import("tecton/transport/root.zig").NetworkHandler);
    try std.testing.expect(@import("tecton/transport/root.zig").SendPriority == @import("tecton/network/root.zig").SendPriority);
    try std.testing.expect(@import("tecton/core/root.zig").ServerProperties == @import("tecton/core/config.zig").ServerProperties);
    try std.testing.expect(@import("tecton/tasks/root.zig").ThreadedTaskQueue == @import("tecton/tasks/threaded_tasks.zig").ThreadedTaskQueue);
    try std.testing.expect(@import("tecton/auth/root.zig").Verified == @import("tecton/auth/identity.zig").Verified);
}
