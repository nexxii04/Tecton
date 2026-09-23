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
    _ = conduit.ServerPaths;
    _ = conduit.ServerProperties;
    _ = conduit.CommandPermissionChecker;

    try std.testing.expect(@hasDecl(conduit.Server, "initWithOptions"));
    try std.testing.expect(@hasDecl(conduit.Server, "prepare"));
    try std.testing.expect(@hasDecl(conduit.Server, "shutdown"));
}

test "the public API is organized as module namespaces" {
    _ = conduit.world.World;
    _ = conduit.world.Dimension;
    _ = conduit.world.Chunk;
    _ = conduit.world.GameInstance;
    _ = conduit.world.block.Block;
    _ = conduit.world.block.BlockPermutation;
    _ = conduit.world.block.BlockType;
    _ = conduit.world.generator.TerrainGenerator;
    _ = conduit.world.provider.LevelDBProvider;
    _ = conduit.block.Block;
    _ = conduit.block.BlockPermutation;
    _ = conduit.entity.Entity;
    _ = conduit.entity.EntityType;
    _ = conduit.entity.EntityTypeRegistry;
    _ = conduit.entity.ECS;
    _ = conduit.entity.traits.EntityTrait;
    _ = conduit.player.Player;
    _ = conduit.player.PermissionManager;
    _ = conduit.items.ItemType;
    _ = conduit.items.ItemStack;
    _ = conduit.container.Container;
    _ = conduit.container.BlockContainer;
    _ = conduit.container.EntityContainer;
    _ = conduit.command.CommandRegistry;
    _ = conduit.command.CommandContext;
    _ = conduit.network.NetworkHandler;
    _ = conduit.tasks.TaskQueue;
    _ = conduit.tasks.ThreadedTaskQueue;
    _ = conduit.events.Events;
    _ = conduit.plugins.PluginRuntime;

    _ = conduit.protocol;
    _ = conduit.nbt;
    _ = conduit.binary_stream;
}
