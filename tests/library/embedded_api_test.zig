const std = @import("std");
const tecton = @import("tecton");

fn tick(_: ?*anyopaque) void {}
fn prepare(_: ?*anyopaque) void {}
fn start(_: ?*anyopaque) void {}
fn shutdown(_: ?*anyopaque) void {}

test "external consumers can use the public vanilla API" {
    const options = tecton.ServerOptions{
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
    _ = tecton.Server;
    _ = tecton.ServerPaths;
    _ = tecton.ServerProperties;
    _ = tecton.CommandPermissionChecker;

    try std.testing.expect(@hasDecl(tecton.Server, "initWithOptions"));
    try std.testing.expect(@hasDecl(tecton.Server, "prepare"));
    try std.testing.expect(@hasDecl(tecton.Server, "shutdown"));
}

// La feature de encantamientos debe funcionar sin servidor: carga la tabla
// vanilla y pasa por almacén, NBT, descriptor de red y efecto de daño.
test "an embedded consumer enchants an item without starting a server" {
    const allocator = std.testing.allocator;
    const enchantments = tecton.items.enchantments;

    const source_tags = [_][]const u8{ "minecraft:is_sword", "minecraft:is_tool", "minecraft:diamond_tier" };
    const tags = try allocator.alloc([]const u8, source_tags.len);
    for (source_tags, 0..) |tag, index| tags[index] = try allocator.dupe(u8, tag);

    const item_type = try tecton.items.ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:embedded_sword"),
        1,
        1,
        false,
        tags,
        false,
        0,
        .{ .Compound = tecton.nbt.CompoundTag.init(allocator, null) },
    );
    defer item_type.deinit();

    var stack = tecton.items.ItemStack.init(allocator, item_type, .{});
    defer stack.deinit();

    try std.testing.expect(enchantments.getRegistry() != null);

    try std.testing.expect(enchantments.ops.enchantName(&stack, "sharpness", 5, .{}) == .applied);
    try std.testing.expectEqual(@as(u8, 5), enchantments.ops.level(&stack, enchantments.compat.SHARPNESS).?);
    try std.testing.expect(enchantments.ops.enchantName(&stack, "nope", 1, .{}) == .rejected);

    // El efecto de gameplay y el descriptor que lee el cliente salen del mismo dato.
    try std.testing.expectEqual(@as(f32, 13.25), enchantments.effects.attackDamage(&stack, "minecraft:zombie"));
    try std.testing.expect(stack.toNetworkStack().extras.?.nbt.?.get(enchantments.nbt.KEY) != null);

    try std.testing.expect(enchantments.ops.remove(&stack, enchantments.compat.SHARPNESS, .{}) == .removed);
    // Nada que pintar: sin user data, o sin `ench` dentro.
    const after = stack.toNetworkStack();
    if (after.extras) |extras| {
        try std.testing.expect(extras.nbt.?.get(enchantments.nbt.KEY) == null);
    }
}

test "the public API is organized as module namespaces" {
    _ = tecton.world.World;
    _ = tecton.world.Dimension;
    _ = tecton.world.Chunk;
    _ = tecton.world.GameInstance;
    _ = tecton.world.block.Block;
    _ = tecton.world.block.BlockPermutation;
    _ = tecton.world.block.BlockType;
    _ = tecton.world.generator.TerrainGenerator;
    _ = tecton.world.provider.LevelDBProvider;
    _ = tecton.block.Block;
    _ = tecton.block.BlockPermutation;
    _ = tecton.entity.Entity;
    _ = tecton.entity.EntityType;
    _ = tecton.entity.EntityTypeRegistry;
    _ = tecton.entity.ECS;
    _ = tecton.entity.traits.EntityTrait;
    _ = tecton.player.Player;
    _ = tecton.player.PermissionManager;
    _ = tecton.items.ItemType;
    _ = tecton.items.ItemStack;
    _ = tecton.container.Container;
    _ = tecton.container.BlockContainer;
    _ = tecton.container.EntityContainer;
    _ = tecton.command.CommandRegistry;
    _ = tecton.command.CommandContext;
    _ = tecton.network.NetworkHandler;
    _ = tecton.tasks.TaskQueue;
    _ = tecton.tasks.ThreadedTaskQueue;
    _ = tecton.events.Events;
    _ = tecton.plugins.PluginRuntime;

    _ = tecton.protocol;
    _ = tecton.nbt;
    _ = tecton.binary_stream;
}
