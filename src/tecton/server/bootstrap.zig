const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const Tecton = @import("../tecton.zig").Tecton;
const shouldEmitStartupLogs = @import("../core/config.zig").shouldEmitStartupLogs;
const services = @import("./services.zig");
const worlds = @import("worlds.zig");
const entities = @import("../world/dimension/entities.zig");

const EntityTypeRegistry = @import("../entity/entity_type_registry.zig");
const EntityTraits = @import("../entity/traits/root.zig");
const FireTrait = EntityTraits.FireTrait;
const GravityTrait = EntityTraits.GravityTrait;
const HealthTrait = EntityTraits.HealthTrait;
const VillagerTradeTrait = EntityTraits.VillagerTradeTrait;
const EcsEntityId = @import("../entity/ecs.zig").EntityId;
const ItemDrop = @import("../entity/ecs.zig").ItemDrop;
const CreativeContentLoader = @import("../items/creative_content_loader.zig");
const ItemPalette = @import("../items/item_palette.zig");
const ItemType = @import("../items/item_type.zig").ItemType;
const EnchantmentRegistry = @import("../items/enchantments/registry.zig");
const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
const initRegistries = @import("../world/block/root.zig").initRegistries;
const loadBlockPermutations = @import("../world/block/root.zig").loadBlockPermutations;
const BarrelTrait = @import("../world/block/traits/barrel.zig").BarrelTrait;
const ChestTrait = @import("../world/block/traits/chest.zig").ChestTrait;
const OpenBitTrait = @import("../world/block/traits/open_bit.zig").OpenBitTrait;
const UpperBlockTrait = @import("../world/block/traits/upper_block.zig").UpperBlockTrait;
const WallConnectionTrait = @import("../world/block/traits/wall_connection.zig").WallConnectionTrait;

pub fn prepare(tecton: *Tecton) !void {
    if (tecton.prepared) return;
    try initRegistries(tecton.allocator);
    try ChestTrait.register();
    try BarrelTrait.register();
    try UpperBlockTrait.registerForState("upper_block_bit");
    try OpenBitTrait.registerForState("open_bit");
    try WallConnectionTrait.register();
    const count = try loadBlockPermutations(tecton.allocator);
    if (shouldEmitStartupLogs()) {
        Raknet.Logger.INFO("Loaded {d} block permutations", .{count});
    }
    try BlockPermutation.initNbtHashLookup(tecton.allocator);

    EntityTraits.initEntityTraitRegistry(tecton.allocator);
    try GravityTrait.register();
    try HealthTrait.register();
    try FireTrait.register();
    try VillagerTradeTrait.register();

    try ItemPalette.initRegistry(tecton.allocator);
    const item_count = try ItemPalette.loadItemTypes(tecton.allocator);
    if (shouldEmitStartupLogs()) {
        Raknet.Logger.INFO("Loaded {d} item types", .{item_count});
    }
    const enchantment_count = try EnchantmentRegistry.load();
    if (shouldEmitStartupLogs()) {
        Raknet.Logger.INFO("Loaded {d} enchantments", .{enchantment_count});
    }
    {
        const entries = try ItemPalette.getItemRegistry(tecton.allocator);
        defer tecton.allocator.free(entries);
        var stream = BinaryStream.init(tecton.allocator, null, null);
        defer stream.deinit();
        const pkt = Protocol.ItemRegistryPacket{ .entries = entries };
        const raw = try pkt.serialize(&stream);
        tecton.serialized_item_registry = try tecton.allocator.dupe(u8, raw);
        if (shouldEmitStartupLogs()) {
            Raknet.Logger.INFO("Pre-serialized item registry ({d} bytes)", .{tecton.serialized_item_registry.?.len});
        }
    }

    {
        tecton.serialized_biome_definitions = Protocol.BiomeDefinitionsLoader.loadVanillaSerialized(tecton.allocator) catch |err| blk: {
            Raknet.Logger.ERROR("Failed to serialize biome definitions: {any}", .{err});
            break :blk null;
        };
        if (tecton.serialized_biome_definitions) |raw| {
            if (shouldEmitStartupLogs()) {
                Raknet.Logger.INFO("Pre-serialized biome definitions ({d} bytes)", .{raw.len});
            }
        }
    }

    const entity_type_count = try EntityTypeRegistry.initRegistry(tecton.allocator);
    if (shouldEmitStartupLogs()) {
        Raknet.Logger.INFO("Loaded {d} entity types", .{entity_type_count});
    }

    tecton.creative_content = CreativeContentLoader.loadCreativeContent(tecton.allocator) catch |err| blk: {
        Raknet.Logger.ERROR("Failed to load creative content: {any}", .{err});
        break :blk null;
    };
    if (tecton.creative_content) |cc| {
        if (shouldEmitStartupLogs()) {
            Raknet.Logger.INFO("Loaded {d} creative groups and {d} creative items", .{ cc.group_count, cc.item_count });
        }
    }

    {
        tecton.pre_spawn_data = Protocol.PreSpawnData.load(tecton.allocator) catch |err| blk: {
            Raknet.Logger.ERROR("Failed to load pre-spawn data: {any}", .{err});
            break :blk null;
        };
        if (tecton.pre_spawn_data) |psd| {
            if (shouldEmitStartupLogs()) {
                Raknet.Logger.INFO("Loaded pre-spawn data ({d} block palette entries, {d} voxel shapes)", .{ psd.block_palette.len, psd.voxel_shapes.len });
            }
        }
    }

    if (tecton.auto_load_worlds) {
        if (std.Io.Dir.cwd().openDir(tecton.io, tecton.paths.worlds, .{ .iterate = true })) |worlds_dir_val| {
            var worlds_dir = worlds_dir_val;
            defer worlds_dir.close(tecton.io);
            var dir_it = worlds_dir.iterate();
            while (dir_it.next(tecton.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                _ = worlds.load(services.host(tecton), tecton.paths.worlds, entry.name) catch |err| {
                    Raknet.Logger.ERROR("Failed to load world '{s}': {any}", .{ entry.name, err });
                    continue;
                };
                Raknet.Logger.INFO("Loaded world: {s}", .{entry.name});
            }
        } else |_| {
            std.Io.Dir.cwd().createDir(tecton.io, tecton.paths.worlds, .default_dir) catch {};
        }

        if (tecton.worlds.count() == 0 and tecton.create_default_world) {
            Raknet.Logger.INFO("No worlds found, creating default world", .{});
            _ = try worlds.load(services.host(tecton), tecton.paths.worlds, "world");
        }
    }

    tecton.player_locations.load();
    tecton.ecs.setDropCallback(@ptrCast(tecton), ecsDrop);
    tecton.plugin_runtime.attach(tecton, &tecton.events, Protocol.PROTOCOL);
    if (tecton.discover_native_plugins) {
        tecton.plugin_runtime.discover(tecton.io, Protocol.PROTOCOL, tecton.paths.plugins);
    }
    var world_instances = tecton.worlds.valueIterator();
    while (world_instances.next()) |world| {
        if (world.*.getDimension("overworld")) |dimension| {
            _ = tecton.instances.create(world.*.identifier, world.*, dimension) catch |err| {
                Raknet.Logger.ERROR("Failed to create instance for world '{s}': {any}", .{ world.*.identifier, err });
            };
        }
    }
    if (shouldEmitStartupLogs()) {
        Raknet.Logger.INFO("Loaded {d} player locations", .{tecton.player_locations.count()});
    }

    const commands = .{
        @import("../command/list/summon.zig"),
        @import("../command/list/about.zig"),
        @import("../command/list/stop.zig"),
        @import("../command/list/tp.zig"),
        @import("../command/list/gamemode.zig"),
        @import("../command/list/kick.zig"),
        @import("../command/list/ban.zig"),
        @import("../command/list/give.zig"),
        @import("../command/list/weather.zig"),
        @import("../command/list/op.zig"),
        @import("../command/list/floating_text.zig"),
        @import("../command/list/enchant.zig"),
        @import("../command/list/movement.zig"),
    };
    inline for (commands) |cmd| {
        try cmd.register(&tecton.command_registry);
    }

    try @import("../command/list/worlds.zig").register(&tecton.command_registry, tecton);
    try @import("../command/list/world.zig").register(&tecton.command_registry, services.commandViews(tecton).world_admin);
    tecton.prepared = true;
    if (tecton.prepare_callback) |callback| callback(tecton.lifecycle_userdata);
}

test "op and deop persist permission changes across a reload" {
    const Op = @import("../command/list/op.zig");
    Raknet.Logger.init(std.heap.page_allocator);
    const PermissionManager = @TypeOf(@as(Tecton, undefined).permission_manager);
    const CommandRegistry = @TypeOf(@as(Tecton, undefined).command_registry);
    const CommandViews = @typeInfo(@TypeOf(services.commandViews)).@"fn".return_type.?;
    const NetworkHandler = std.meta.Child(@TypeOf(@as(Tecton, undefined).network));
    const fixture = "{\"groups\":{\"member\":[\"tecton.command.about\"],\"operator\":[\"*\"]},\"players\":{\"Alice\":\"member\",\"Bob\":\"operator\"}}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = fixture });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try Op.register(&registry);
    const Adapter = struct {
        fn get(raw: *anyopaque, name: []const u8) []const u8 {
            const mgr: *PermissionManager = @ptrCast(@alignCast(raw));
            return mgr.getPlayerGroup(name);
        }
        fn set(raw: *anyopaque, name: []const u8, group: []const u8) !void {
            const mgr: *PermissionManager = @ptrCast(@alignCast(raw));
            try mgr.setPlayerGroup(name, group);
        }
        fn default(raw: *anyopaque) []const u8 {
            const mgr: *PermissionManager = @ptrCast(@alignCast(raw));
            return mgr.default_group;
        }
        fn refresh(_: *anyopaque, _: std.mem.Allocator, _: []const u8) void {}
    };
    var views: CommandViews = undefined;
    views.permission_admin = .{ .ctx = &manager, .get_group = Adapter.get, .set_group = Adapter.set, .default_group = Adapter.default, .refresh_abilities = Adapter.refresh };
    var network: NetworkHandler = undefined;
    registry.dispatchConsole(views, &network, "/op Alice");
    registry.dispatchConsole(views, &network, "/deop Bob");
    try std.testing.expectEqualStrings("operator", manager.getPlayerGroup("Alice"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("Bob"));
    const data = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(data);
    try std.testing.expect(!std.mem.eql(u8, fixture, data));
    var loaded = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("operator", loaded.getPlayerGroup("Alice"));
    try std.testing.expectEqualStrings("member", loaded.getPlayerGroup("Bob"));
    try std.testing.expect(loaded.hasPermission("Alice", "tecton.command.op"));
    try std.testing.expect(!loaded.hasPermission("Bob", "tecton.command.op"));
}

test "op and deop refresh the target's abilities exactly once per successful change" {
    const Op = @import("../command/list/op.zig");
    Raknet.Logger.init(std.heap.page_allocator);
    const PermissionManager = @TypeOf(@as(Tecton, undefined).permission_manager);
    const CommandRegistry = @TypeOf(@as(Tecton, undefined).command_registry);
    const CommandViews = @typeInfo(@TypeOf(services.commandViews)).@"fn".return_type.?;
    const NetworkHandler = std.meta.Child(@TypeOf(@as(Tecton, undefined).network));
    const fixture = "{\"groups\":{\"member\":[\"tecton.command.about\"],\"operator\":[\"*\"]},\"players\":{\"Alice\":\"member\",\"Bob\":\"operator\"}}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = fixture });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try Op.register(&registry);
    const Recorder = struct {
        manager: *PermissionManager,
        calls: usize = 0,
        last_name: []const u8 = "",
        fn get(raw: *anyopaque, name: []const u8) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.manager.getPlayerGroup(name);
        }
        fn set(raw: *anyopaque, name: []const u8, group: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.manager.setPlayerGroup(name, group);
        }
        fn default(raw: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.manager.default_group;
        }
        fn refresh(raw: *anyopaque, _: std.mem.Allocator, username: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.last_name = username;
        }
    };
    var recorder = Recorder{ .manager = &manager };
    var views: CommandViews = undefined;
    views.permission_admin = .{ .ctx = &recorder, .get_group = Recorder.get, .set_group = Recorder.set, .default_group = Recorder.default, .refresh_abilities = Recorder.refresh };
    var network: NetworkHandler = undefined;
    registry.dispatchConsole(views, &network, "/op Alice");
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("Alice", recorder.last_name);
    registry.dispatchConsole(views, &network, "/op Alice");
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    registry.dispatchConsole(views, &network, "/deop Bob");
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqualStrings("Bob", recorder.last_name);
    registry.dispatchConsole(views, &network, "/deop Bob");
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    registry.dispatchConsole(views, &network, "/op");
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
}

fn ecsDrop(context: *anyopaque, _: EcsEntityId, position: Protocol.Vector3f, item: ItemDrop) void {
    const tecton: *Tecton = @ptrCast(@alignCast(context));
    const dimension = tecton.worlds.get("world") orelse return;
    const overworld = dimension.getDimension("overworld") orelse return;
    const item_type = ItemType.get(item.identifier) orelse return;
    _ = entities.spawnItemEntity(overworld, item_type, item.count, position, item.pickup_delay, Protocol.Vector3f.init(0, 0.1, 0)) catch {};
}
