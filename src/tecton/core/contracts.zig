const std = @import("std");

const ServerProperties = @import("./config.zig").ServerProperties;
const TickProfiler = @import("./tick_profiler.zig").TickProfiler;
const TaskQueue = @import("../tasks/tasks.zig").TaskQueue;
const ThreadedTaskQueue = @import("../tasks/threaded_tasks.zig").ThreadedTaskQueue;

pub const PermissionQuery = struct {
    ctx: *anyopaque,
    has_permission: *const fn (*anyopaque, []const u8, []const u8, []const u8) bool,

    pub fn hasPermission(self: @This(), username: []const u8, xuid: []const u8, permission: []const u8) bool {
        return self.has_permission(self.ctx, username, xuid, permission);
    }
};

pub const PermissionAdmin = struct {
    ctx: *anyopaque,
    get_group: *const fn (*anyopaque, []const u8) []const u8,
    set_group: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    default_group: *const fn (*anyopaque) []const u8,

    pub fn getPlayerGroup(self: @This(), name: []const u8) []const u8 {
        return self.get_group(self.ctx, name);
    }

    pub fn setPlayerGroup(self: @This(), name: []const u8, group: []const u8) !void {
        return self.set_group(self.ctx, name, group);
    }

    pub fn defaultGroup(self: @This()) []const u8 {
        return self.default_group(self.ctx);
    }
};

pub const BanAdmin = struct {
    ctx: *anyopaque,
    is_banned: *const fn (*anyopaque, []const u8) bool,
    add: *const fn (*anyopaque, []const u8, []const u8, []const u8, []const u8) anyerror!void,
    remove: *const fn (*anyopaque, []const u8) bool,
    entry_name: *const fn (*anyopaque, usize) ?[]const u8,

    pub fn isBanned(self: @This(), name: []const u8) bool {
        return self.is_banned(self.ctx, name);
    }

    pub fn ban(self: @This(), uuid: []const u8, name: []const u8, source: []const u8, reason: []const u8) !void {
        return self.add(self.ctx, uuid, name, source, reason);
    }

    pub fn unban(self: @This(), name: []const u8) bool {
        return self.remove(self.ctx, name);
    }

    pub fn entryName(self: @This(), index: usize) ?[]const u8 {
        return self.entry_name(self.ctx, index);
    }
};

pub const ShutdownHost = struct {
    ctx: *anyopaque,
    shutdown: *const fn (*anyopaque) anyerror!void,
};

pub fn SelectionHost(comptime Player: type) type {
    return struct {
        ctx: *anyopaque,
        io: std.Io,
        get_player_snapshots: *const fn (*anyopaque) []const *Player,

        pub fn getPlayerSnapshots(self: @This()) []const *Player {
            return self.get_player_snapshots(self.ctx);
        }
    };
}

pub fn AboutHost(comptime Player: type) type {
    return struct {
        players: SelectionHost(Player),
        max_players: *const u32,
    };
}

pub fn WorldQuery(comptime World: type) type {
    return struct {
        registry: *const std.StringHashMap(*World),

        pub fn get(self: @This(), name: []const u8) ?*World {
            return self.registry.get(name);
        }

        pub fn count(self: @This()) usize {
            return self.registry.count();
        }

        pub fn keyIterator(self: @This()) std.StringHashMap(*World).KeyIterator {
            return self.registry.keyIterator();
        }

        pub fn valueIterator(self: @This()) std.StringHashMap(*World).ValueIterator {
            return self.registry.valueIterator();
        }
    };
}

pub fn WorldInfoHost(comptime Player: type, comptime World: type) type {
    return struct {
        worlds: WorldQuery(World),
        players: SelectionHost(Player),
        ctx: *anyopaque,
        target_tps: *const fn (*anyopaque) f64,
        current_tps: *const f64,
        current_mspt: *const f64,
        current_raknet_mspt: *const f64,
        current_game_mspt: *const f64,
        profiler: *const TickProfiler,

        pub fn targetTps(self: @This()) f64 {
            return self.target_tps(self.ctx);
        }

        pub fn getPlayerSnapshots(self: @This()) []const *Player {
            return self.players.getPlayerSnapshots();
        }
    };
}

pub fn EnchantmentHost(comptime Events: type) type {
    return struct { events: *Events };
}

pub fn CommandViews(comptime Player: type, comptime World: type, comptime Events: type) type {
    return struct {
        selection: SelectionHost(Player),
        permissions: PermissionQuery,
        permission_admin: PermissionAdmin,
        bans: BanAdmin,
        shutdown: ShutdownHost,
        about: AboutHost(Player),
        world_info: WorldInfoHost(Player, World),
        enchantment: EnchantmentHost(Events),
    };
}

pub fn PlayersHost(comptime Player: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        by_runtime_id: *const fn (*anyopaque, i64) ?*Player,

        pub fn byRuntimeId(self: Self, runtime_id: i64) ?*Player {
            return self.by_runtime_id(self.ctx, runtime_id);
        }
    };
}

pub fn InstancesHost(comptime Dimension: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        assign_dimension: *const fn (*anyopaque, i64, *Dimension) anyerror!void,

        pub fn assignDimension(self: Self, runtime_id: i64, dimension: *Dimension) anyerror!void {
            return self.assign_dimension(self.ctx, runtime_id, dimension);
        }
    };
}

pub const PermsHost = struct {
    const Self = @This();

    ctx: *anyopaque,
    get_player_group: *const fn (*anyopaque, []const u8) []const u8,

    pub fn getPlayerGroup(self: Self, player_name: []const u8) []const u8 {
        return self.get_player_group(self.ctx, player_name);
    }
};

pub fn WorldsHost(comptime World: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        build_world: *const fn (*anyopaque, []const u8) anyerror!*World,
        adopt_world: *const fn (*anyopaque, *World) anyerror!void,
        destroy_world: *const fn (*anyopaque, *World) void,
        end_op: *const fn (*anyopaque, []const u8) void,

        pub fn build(self: Self, name: []const u8) anyerror!*World {
            return self.build_world(self.ctx, name);
        }

        pub fn adopt(self: Self, world: *World) anyerror!void {
            return self.adopt_world(self.ctx, world);
        }

        pub fn destroy(self: Self, world: *World) void {
            self.destroy_world(self.ctx, world);
        }

        pub fn endOp(self: Self, name: []const u8) void {
            self.end_op(self.ctx, name);
        }
    };
}

pub fn ServerHost(
    comptime Player: type,
    comptime Entity: type,
    comptime Events: type,
    comptime Dimension: type,
    comptime World: type,
    comptime Ecs: type,
    comptime Network: type,
) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        config: *const ServerProperties,
        network: *Network,
        events: *Events,
        ecs: *Ecs,
        tasks: *TaskQueue,
        threaded_tasks: *ThreadedTaskQueue,
        profiler: *TickProfiler,
        players: PlayersHost(Player),
        instances: InstancesHost(Dimension),
        permission_manager: PermsHost,
        worlds: WorldsHost(World),
        mob_broadcast_interval: u8,

        get_player_snapshots: *const fn (*anyopaque) []const *Player,
        get_player_count: *const fn (*anyopaque) usize,
        find_player_by_runtime_id: *const fn (*anyopaque, i64) ?*Player,
        register_ecs_entity: *const fn (*anyopaque, *Entity) void,
        unregister_ecs_entity: *const fn (*anyopaque, *Entity) void,
        set_player_location: *const fn (*anyopaque, []const u8, []const u8, []const u8) void,
        enqueue_player_removal: *const fn (*anyopaque, *Player) void,
        remove_player: *const fn (*anyopaque, *Player) void,
        remove_connection_mapping: *const fn (*anyopaque, *anyopaque) void,
        target_tps: *const fn (*anyopaque) f64,
        current_tps: *const fn (*anyopaque) f64,
        current_mspt: *const fn (*anyopaque) f64,
        tick_count: *const fn (*anyopaque) u64,
        refresh_world_command_enums: *const fn (*anyopaque) void,
        refresh_floating_text_command_enums: *const fn (*anyopaque) void,
        reply_to: *const fn (*anyopaque, ?i64, []const u8, [16]u8, []const u8, bool, []const u8) void,

        pub fn getPlayerSnapshots(self: Self) []const *Player {
            return self.get_player_snapshots(self.ctx);
        }

        pub fn getPlayerCount(self: Self) usize {
            return self.get_player_count(self.ctx);
        }

        pub fn findPlayerByRuntimeId(self: Self, runtime_id: i64) ?*Player {
            return self.find_player_by_runtime_id(self.ctx, runtime_id);
        }

        pub fn registerEcsEntity(self: Self, entity: *Entity) void {
            self.register_ecs_entity(self.ctx, entity);
        }

        pub fn unregisterEcsEntity(self: Self, entity: *Entity) void {
            self.unregister_ecs_entity(self.ctx, entity);
        }

        pub fn setPlayerLocation(self: Self, uuid: []const u8, world_identifier: []const u8, dimension_identifier: []const u8) void {
            self.set_player_location(self.ctx, uuid, world_identifier, dimension_identifier);
        }

        pub fn enqueuePlayerRemoval(self: Self, player: *Player) void {
            self.enqueue_player_removal(self.ctx, player);
        }

        pub fn removePlayer(self: Self, player: *Player) void {
            self.remove_player(self.ctx, player);
        }

        pub fn removeConnectionMapping(self: Self, connection: *anyopaque) void {
            self.remove_connection_mapping(self.ctx, connection);
        }

        pub fn targetTps(self: Self) f64 {
            return self.target_tps(self.ctx);
        }

        pub fn currentTps(self: Self) f64 {
            return self.current_tps(self.ctx);
        }

        pub fn currentMspt(self: Self) f64 {
            return self.current_mspt(self.ctx);
        }

        pub fn tickCount(self: Self) u64 {
            return self.tick_count(self.ctx);
        }

        pub fn refreshWorldCommandEnums(self: Self) void {
            self.refresh_world_command_enums(self.ctx);
        }

        pub fn refreshFloatingTextCommandEnums(self: Self) void {
            self.refresh_floating_text_command_enums(self.ctx);
        }

        pub fn replyTo(
            self: Self,
            sender_runtime_id: ?i64,
            origin_type: []const u8,
            uuid: [16]u8,
            request_id: []const u8,
            success: bool,
            message: []const u8,
        ) void {
            self.reply_to(self.ctx, sender_runtime_id, origin_type, uuid, request_id, success, message);
        }
    };
}
