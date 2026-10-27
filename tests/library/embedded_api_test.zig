const std = @import("std");
const tecton = @import("tecton");

fn tick(_: ?*anyopaque) void {}
fn prepare(_: ?*anyopaque) void {}
fn start(_: ?*anyopaque) void {}
fn shutdown(_: ?*anyopaque) void {}

test "external consumers can use the public vanilla API" {
    const options = tecton.ServerOptions{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .composition = tecton.composition,
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

    try std.testing.expect(@hasDecl(tecton.Server, "init"));
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

test "single chest inventory survives World.save and LevelDB reopen" {
    try chestRoundTrip(false);
}

test "double chest inventory survives World.save and LevelDB reopen" {
    try chestRoundTrip(true);
}

fn chestRoundTrip(comptime double: bool) !void {
    const allocator = std.testing.allocator;
    const block = tecton.world.block;
    const ItemStack = tecton.items.ItemStack;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_buf, ".zig-cache/tmp/{s}/db", .{tmp.sub_path}, 0);

    var options = tecton.defaultOptions(std.testing.io, allocator);
    options.properties = .{ .allocator = allocator, .address = "127.0.0.1", .port = 0 };
    options.paths = .{
        .permissions = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path}),
        .banned_players = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bans.json", .{tmp.sub_path}),
        .player_locations = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/locations.json", .{tmp.sub_path}),
    };
    defer allocator.free(options.paths.permissions);
    defer allocator.free(options.paths.banned_players);
    defer allocator.free(options.paths.player_locations);
    options.enable_console = false;
    options.discover_native_plugins = false;
    options.auto_load_worlds = false;
    options.create_default_world = false;
    var server = try tecton.Server.init(options);
    defer server.deinit();
    try server.start();

    const chest = try block.BlockPermutation.resolve(allocator, "minecraft:chest", null);
    const item_type = tecton.items.ItemType.get("minecraft:diamond_sword").?;
    var expected = [_]ItemStack{
        ItemStack.init(allocator, tecton.items.ItemType.get("minecraft:dirt").?, .{ .stack_size = 7 }),
        ItemStack.init(allocator, tecton.items.ItemType.get("minecraft:cobblestone").?, .{ .stack_size = 10, .metadata = 3 }),
        ItemStack.init(allocator, item_type, .{}),
    };
    defer for (&expected) |*item| item.deinit();
    try expected[2].addTrait(try tecton.items.traits.DisplayTrait.create(allocator, .{}));
    try tecton.items.traits.display.setDisplayName(&expected[2], "Stored treasure");
    try tecton.items.traits.display.setLore(&expected[2], &.{ "First line", "Second line" });
    try std.testing.expect(tecton.items.enchantments.ops.enchant(&expected[2], 9, 5, .{}) == .applied);
    const slots = if (double) [_]u32{ 0, 30, 53 } else [_]u32{ 0, 13, 26 };
    const left = tecton.protocol.BlockPosition{ .x = 0, .y = 64, .z = 0 };
    const right = tecton.protocol.BlockPosition{ .x = 1, .y = 64, .z = 0 };
    const containerOf = struct {
        fn get(b: *block.Block) *tecton.container.Container {
            const instance = b.getTrait("chest").?;
            const State = struct {
                container: ?tecton.container.BlockContainer = null,
                pair_position: ?tecton.protocol.BlockPosition = null,
                is_parent: bool = false,
            };
            const state: *State = @ptrCast(@alignCast(instance.ctx));
            return &state.container.?.base;
        }
    }.get;

    {
        const provider = try tecton.world.provider.LevelDBProvider.init(std.testing.io, allocator, db_path);
        var world = try tecton.world.World.init(undefined, allocator, "test", provider.asProvider());
        defer world.deinit();
        const dim = try world.createDimension("overworld", .Overworld, null, false);
        try dim.setPermutation(left, chest, 0);
        if (double) {
            try dim.setPermutation(right, chest, 0);
            try block.applyTraitsForBlock(allocator, dim, right);
        }
        try block.applyTraitsForBlock(allocator, dim, left);
        const container = containerOf(dim.getBlockPtr(left).?);
        try std.testing.expectEqual(@as(u32, if (double) 54 else 27), container.getSize());
        for (&expected, slots) |*item, slot| container.setItem(slot, try item.cloneWithCount(allocator, item.stack_size));
        world.save();
    }

    const reopened = try tecton.world.provider.LevelDBProvider.init(std.testing.io, allocator, db_path);
    var world = try tecton.world.World.init(undefined, allocator, "test", reopened.asProvider());
    defer world.deinit();
    const dim = try world.createDimension("overworld", .Overworld, null, false);
    _ = try dim.getOrCreateChunk(0, 0);
    try std.testing.expectEqualStrings("minecraft:chest", (try dim.getPermutation(left, 0)).identifier);
    const restored = containerOf(dim.getBlockPtr(left).?);
    try std.testing.expectEqual(@as(u32, if (double) 54 else 27), restored.getSize());
    for (restored.storage, 0..) |slot, index| {
        var expected_index: ?usize = null;
        for (slots, 0..) |occupied, i| {
            if (occupied == index) expected_index = i;
        }
        if (expected_index) |i| {
            const actual = slot orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected[i].stack_size, actual.stack_size);
            try std.testing.expectEqual(expected[i].metadata, actual.metadata);
            try std.testing.expectEqualStrings(expected[i].item_type.identifier, actual.item_type.identifier);
            try std.testing.expect(expected[i].isStackCompatible(&actual));
        } else try std.testing.expect(slot == null);
    }
    if (double) {
        const child = containerOf(dim.getBlockPtr(right).?);
        try std.testing.expectEqual(@as(u32, 27), child.getSize());
        for (child.storage) |slot| try std.testing.expect(slot == null);
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

test "stop wakes run and the game tick advances without the transport" {
    const io = std.testing.io;
    var server = try tecton.Server.init(.{
        .io = io,
        .allocator = std.testing.allocator,
        .composition = tecton.composition,
        .properties = tecton.ServerProperties{
            .allocator = std.testing.allocator,
            .address = "127.0.0.1",
            .port = 0,
        },
        .enable_console = false,
        .discover_native_plugins = false,
        .auto_load_worlds = false,
        .create_default_world = false,
    });
    defer server.deinit();
    try server.start();

    var run_future = try io.concurrent(runServer, .{&server});
    const target_tick = server.tick_count + 3;
    while (server.tick_count < target_tick) {
        try io.sleep(.fromNanoseconds(std.time.ns_per_ms * 5), .awake);
    }

    try server.stop();
    try run_future.await(io);
    try std.testing.expect(server.tick_count >= target_tick);
}

fn runServer(server: *tecton.Server) anyerror!void {
    try server.run();
}

test "an embedded server does not allocate on the tick thread in steady state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var server = try tecton.Server.init(.{
        .io = io,
        .allocator = allocator,
        .composition = tecton.composition,
        .properties = tecton.ServerProperties{
            .allocator = allocator,
            .address = "127.0.0.1",
            .port = 0,
            .count_allocations = true,
        },
        .enable_console = false,
        .discover_native_plugins = false,
        .auto_load_worlds = false,
        .create_default_world = false,
    });
    defer server.deinit();
    try std.testing.expect(server.isCountingAllocations());
    try server.start();

    const warmup_until = server.tick_count + 40;
    while (server.tick_count < warmup_until) {
        try io.sleep(.fromNanoseconds(std.time.ns_per_ms * 5), .awake);
    }

    server.resetTickAllocationPeak();
    const measured_until = server.tick_count + 20;
    while (server.tick_count < measured_until) {
        try io.sleep(.fromNanoseconds(std.time.ns_per_ms * 5), .awake);
    }

    const peak = server.peakTickAllocations();
    if (peak != 0) {
        std.debug.print("embedded tick allocation peak {d}, last tick {d}\n", .{ peak, server.lastTickAllocations() });
    }
    try std.testing.expectEqual(@as(usize, 0), peak);
}
