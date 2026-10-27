pub fn Fixture(comptime scope: type) type {
    return struct {
        pub const std = scope.std;
        pub const testing = std.testing;
        pub const allocator = testing.allocator;

        pub const Tecton = scope.Tecton;
        pub const Host = scope.Host;
        pub const host = scope.host;
        pub const hostChecked = scope.hostChecked;
        pub const commandViews = scope.commandViews;
        pub const CommandContext = scope.CommandContext;
        pub const Command = scope.Command;
        pub const Player = scope.Player;
        pub const Entity = scope.Entity;
        pub const EcsWorld = scope.EcsWorld;
        pub const NetworkHandler = scope.NetworkHandler;
        pub const Dimension = scope.Dimension;
        pub const World = scope.World;
        pub const Connection = scope.Connection;
        pub const Protocol = scope.Protocol;
        pub const block_root = scope.block_root;

        pub const PlayerRegistry = @TypeOf(@as(Tecton, undefined).players);
        pub const WorldRegistry = @TypeOf(@as(Tecton, undefined).worlds);
        pub const CommandRegistry = @TypeOf(@as(Tecton, undefined).command_registry);
        pub const CommandEnum = std.meta.Child(@TypeOf(@as(CommandRegistry, undefined).enums.items));
        pub const GameInstanceRegistry = @TypeOf(@as(Tecton, undefined).instances);
        pub const PermissionManager = @TypeOf(@as(Tecton, undefined).permission_manager);
        pub const PlayerLocations = @TypeOf(@as(Tecton, undefined).player_locations);
        pub const FloatingTextManager = std.meta.Child(std.meta.Child(@TypeOf(@as(Dimension, undefined).floating_texts)));
        pub const Events = @TypeOf(@as(Tecton, undefined).events);
        pub const TaskQueue = @TypeOf(@as(Tecton, undefined).tasks);
        pub const ThreadedTaskQueue = @TypeOf(@as(Tecton, undefined).threaded_tasks);
        pub const TickProfiler = @TypeOf(@as(Tecton, undefined).profiler);
        pub const Interval = @TypeOf(@as(Host, undefined).mob_broadcast_interval);

        pub fn stubNetwork() NetworkHandler {
            var stub: NetworkHandler = undefined;
            stub.allocator = allocator;
            stub.frame_buffers = null;
            stub.port = null;
            stub.options = .{ .compression_method = .Zlib, .compression_threshold = 0 };
            return stub;
        }

        pub fn plainNetwork() NetworkHandler {
            var stub: NetworkHandler = undefined;
            stub.allocator = allocator;
            stub.frame_buffers = null;
            stub.port = null;
            stub.options = .{ .compression_method = .NotPresent, .compression_threshold = 255 };
            return stub;
        }

        pub fn baseTecton(tecton: *Tecton, network: *NetworkHandler) void {
            tecton.* = undefined;
            tecton.io = testing.io;
            tecton.allocator = allocator;
            tecton.config = .{ .allocator = allocator };
            tecton.network = network;
            tecton.network_initialized = true;
            tecton.mob_broadcast_interval = 2;
            tecton.events = Events.init(allocator);
            tecton.fixAddress();
        }

        pub fn fakePlayer(runtime_id: i64, connection: *Connection) Player {
            var player: Player = undefined;
            player.entity.runtime_id = runtime_id;
            player.connection = connection;
            player.pending_removal = .init(false);
            return player;
        }

        pub fn fakeEntity() Entity {
            var entity: Entity = undefined;
            entity.ecs_id = 0;
            entity.position = std.mem.zeroes(@TypeOf(entity.position));
            entity.rotation = std.mem.zeroes(@TypeOf(entity.rotation));
            entity.motion = std.mem.zeroes(@TypeOf(entity.motion));
            entity.flags = @TypeOf(entity.flags).init();
            return entity;
        }

        /// A pointer-shaped connection with a stable id and no transport behind it.
        pub fn fakeConnection(storage: *u128, id: u64) *Connection {
            storage.* = @intCast(id);
            return @ptrCast(@alignCast(storage));
        }

        pub fn registerAir() !void {
            const air_type = try block_root.BlockType.init(allocator, "minecraft:air");
            try air_type.register();
            const air_perm = try block_root.BlockPermutation.init(allocator, 0, "minecraft:air", block_root.BlockState.init(allocator));
            try air_perm.register();
            try air_type.addPermutation(air_perm);
        }

        pub fn enumValues(registry: *CommandRegistry, name: []const u8) ?[]const []const u8 {
            for (registry.enums.items) |cmd_enum| {
                if (std.mem.eql(u8, cmd_enum.name, name)) return cmd_enum.values;
            }
            return null;
        }
    };
}
