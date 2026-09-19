const std = @import("std");
const conduit = @import("conduit");

fn tick(_: ?*anyopaque) void {}
fn prepare(_: ?*anyopaque) void {}
fn start(_: ?*anyopaque) void {}
fn shutdown(_: ?*anyopaque) void {}

test "external consumers can use the public vanilla API" {
    const options = conduit.ServerOptions{
        .paths = .{ .worlds = "test-worlds", .plugins = "test-plugins" },
        .enable_console = false,
        .discover_native_plugins = false,
        .auto_load_worlds = false,
        .create_default_world = false,
        .tick_callback = tick,
        .prepare_callback = prepare,
        .start_callback = start,
        .shutdown_callback = shutdown,
        .lifecycle_userdata = null,
    };

    _ = options;
    _ = conduit.Server;
    _ = conduit.Worlds.World;
    _ = conduit.Worlds.Dimension;
    _ = conduit.Players.Player;
    _ = conduit.Entities.Entity;
    _ = conduit.Items.ItemType;
    _ = conduit.Items.ItemStack;
    _ = conduit.Blocks.Block;
    _ = conduit.Blocks.BlockPermutation;
    _ = conduit.Registries.BlockType;
    _ = conduit.Registries.EntityType;
    _ = conduit.Command.CommandRegistry;

    try std.testing.expect(@hasDecl(conduit.Server, "initWithOptions"));
    try std.testing.expect(@hasDecl(conduit.Server, "prepare"));
    try std.testing.expect(@hasDecl(conduit.Server, "shutdown"));
}
