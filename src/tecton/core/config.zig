const std = @import("std");
const log = @import("log.zig");
const builtin = @import("builtin");
const Raknet = @import("Raknet");
const Protocol = @import("protocol");
const WorkerLayout = @import("../tasks/threaded_tasks.zig").WorkerLayout;

pub fn shouldEmitVerboseStartupLogs(mode: std.builtin.OptimizeMode) bool {
    return mode == .Debug;
}

pub fn shouldEmitStartupLogs() bool {
    return shouldEmitVerboseStartupLogs(builtin.mode) and !builtin.is_test;
}

pub const TransportBackend = enum { raknet, nethernet };

pub const ServerProperties = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    motd: []const u8 = "Tecton Server",
    level_name: []const u8 = "Bedrock level",
    transport: TransportBackend = .raknet,
    lan_discovery: bool = true,
    lan_port: u16 = 7551,
    identity_key: []const u8 = "server.key",
    max_message_size: u32 = 256 * 1024,
    transport_tick_ms: u32 = 10,
    outbox_slots: u32 = 512,
    gamemode: []const u8 = "survival",
    max_players: u32 = 120,
    online_mode: bool = false,
    online_mode_offline_fallback: bool = false,
    max_tps: u32 = 20,
    worker_threads: u32 = 0,
    worker_layout: WorkerLayout = .split,
    parallel_visibility: bool = true,
    max_view_distance: u32 = 8,
    simulation_distance: u32 = 4,
    max_mtu: u16 = max_max_mtu,
    movement_send_priority: []const u8 = "immediate",
    movement_distance_bands: bool = true,
    network_inbound_ring: bool = true,
    inbound_ring_slots: u32 = 512,
    inbound_ring_slot_size: u32 = 1536,
    output_slab_slots: u32 = 512,
    transient_slab_slots: u32 = 128,
    outbound_queue_slots: u32 = 1024,
    ecs_capacity: u32 = 1024,
    count_allocations: bool = false,
    mob_broadcast_interval: u8 = 2,
    default_group: []const u8 = "member",

    allocator: std.mem.Allocator,
    _allocated_strings: std.ArrayList([]const u8) = .empty,

    pub const min_max_mtu: u16 = 576;
    pub const max_max_mtu: u16 = Raknet.MAX_MTU_SIZE;

    pub fn clampMaxMtu(requested: u16) u16 {
        return @min(@max(requested, min_max_mtu), max_max_mtu);
    }

    pub const max_view_distance_limit: u32 = 32;
    pub const min_view_distance: i32 = 2;

    pub fn clampViewDistance(requested: i32, configured_max: u32) i32 {
        const ceiling: i32 = @intCast(@min(configured_max, max_view_distance_limit));
        const upper = @max(ceiling, min_view_distance);
        return std.math.clamp(requested, min_view_distance, upper);
    }

    pub fn effectiveMaxViewDistance(self: *const ServerProperties) i32 {
        return clampViewDistance(std.math.maxInt(i32), self.max_view_distance);
    }

    pub const min_inbound_ring_slots: u32 = 64;
    pub const max_inbound_ring_slots: u32 = 1 << 20;
    pub const min_inbound_ring_slot_size: u32 = 512;
    pub const max_inbound_ring_slot_size: u32 = 64 * 1024;

    pub fn clampInboundRingSlots(requested: u32) u32 {
        return @min(@max(requested, min_inbound_ring_slots), max_inbound_ring_slots);
    }

    pub fn clampInboundRingSlotSize(requested: u32) u32 {
        return @min(@max(requested, min_inbound_ring_slot_size), max_inbound_ring_slot_size);
    }

    pub const min_mob_broadcast_interval: u8 = 1;
    pub const max_mob_broadcast_interval: u8 = 20;

    pub fn clampMobBroadcastInterval(requested: u8) u8 {
        return @min(@max(requested, min_mob_broadcast_interval), max_mob_broadcast_interval);
    }

    const comments = .{
        .address = "What address should the server run on",
        .port = "What port should the server run on",
        .motd = "What motd should server display in the server list",
        .level_name = "Level name shown to clients before they join",
        .transport = "Transport backend: raknet (legacy) or nethernet",
        .lan_discovery = "Answer LAN discovery pings on UDP (nethernet backend)",
        .lan_port = "LAN discovery port (nethernet backend)",
        .identity_key = "Path to the operator key that signs signaling answers (created on first start, keep it secret)",
        .max_message_size = "Largest NetherNet message accepted from a client, in bytes",
        .transport_tick_ms = "Milliseconds between NetherNet transport ticks (signaling, ICE and queued frames)",
        .outbox_slots = "Per-session outbound message slots (nethernet backend)",
        .gamemode = "Default game mode: survival, creative, adventure or spectator",
        .max_players = "Max Player count on the server",
        .online_mode = "Verify logins against the Minecraft authorization service; an unverifiable login is refused (see online-mode-offline-fallback)",
        .online_mode_offline_fallback = "With online-mode=true, let unverified logins in as offline identities instead of refusing them",
        .max_tps = "Max tps",
        .worker_threads = "Tecton worker threads (0 = auto, higher values are clamped)",
        .worker_layout = "Worker layout: split dedicates max(1, cpu/4) workers to input and the rest to world; shared restores the single queue",
        .parallel_visibility = "Run the per-viewer player visibility pass on the world workers instead of inline in the player tick (false restores the serial pass)",
        .max_view_distance = "Max view distance in chunks",
        .simulation_distance = "Simulation distance in chunks (chunks within this range are kept loaded)",
        .max_mtu = "Max RakNet MTU (clamped to 576-1400; clients still negotiate the minimum with this cap)",
        .movement_send_priority = "Movement broadcast priority: immediate or normal",
        .movement_distance_bands = "Rate-limit player movement updates by distance to the nearest viewer (false restores a delta every tick)",
        .network_inbound_ring = "Use the zero-alloc SPSC inbound ring instead of the per-packet heap queue (false restores the legacy path)",
        .inbound_ring_slots = "Inbound ring slots (clamped to 64-1048576 and rounded up to a power of two)",
        .inbound_ring_slot_size = "Bytes per inbound ring slot (clamped to 512-65536; larger payloads use bounded overflow slots)",
        .output_slab_slots = "Reliable output datagram slots reserved at startup (minimum 64)",
        .transient_slab_slots = "Transient output datagram slots reserved at startup (minimum 64)",
        .outbound_queue_slots = "Outbound queue slots reserved at startup (minimum 64, rounded to a power of two)",
        .ecs_capacity = "Entity slots reserved at startup (minimum 64; exhaustion never grows storage in the tick)",
        .count_allocations = "Count allocations made by the tick thread and warn when a tick allocates (diagnostics)",
        .mob_broadcast_interval = "Ticks between in-air mob movement broadcasts (clamped to 1-20; 1 is the old every-tick behavior)",
        .default_group = "Default permission group for new players",
    };

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ServerProperties {
        var self = ServerProperties{ .allocator = allocator };
        errdefer self.deinit();

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (shouldEmitStartupLogs()) {
                    log.info("server.properties not found, creating with defaults", .{});
                }
                try self.save(io, path);
                return self;
            },
            else => return err,
        };
        defer file.close(io);

        if (shouldEmitStartupLogs()) {
            log.info("Loading server.properties", .{});
        }

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const content = try reader.interface.allocRemaining(allocator, .limited(1024 * 64));
        defer allocator.free(content);

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0 or line[0] == '#') continue;

            const sep = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..sep];
            const value = line[sep + 1 ..];

            self.setField(key, value) catch |err| {
                log.warn("Unknown or invalid property: {s} ({any})", .{ key, err });
            };
        }

        return self;
    }

    pub fn parseGamemode(value: []const u8) ?Protocol.GameMode {
        if (std.ascii.eqlIgnoreCase(value, "survival")) return .Survival;
        if (std.ascii.eqlIgnoreCase(value, "creative")) return .Creative;
        if (std.ascii.eqlIgnoreCase(value, "adventure")) return .Adventure;
        if (std.ascii.eqlIgnoreCase(value, "spectator")) return .Spectator;
        return null;
    }

    pub fn gameMode(self: *const ServerProperties) Protocol.GameMode {
        return parseGamemode(self.gamemode) orelse .Survival;
    }

    fn setField(self: *ServerProperties, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "gamemode") and parseGamemode(value) == null) return error.InvalidValue;
        inline for (@typeInfo(ServerProperties).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "allocator") or
                std.mem.eql(u8, field.name, "_allocated_strings")) continue;

            const file_key = comptime blk: {
                var name_buf: [field.name.len]u8 = undefined;
                @memcpy(&name_buf, field.name);
                std.mem.replaceScalar(u8, &name_buf, '_', '-');
                break :blk name_buf;
            };

            if (std.mem.eql(u8, key, &file_key)) {
                if (field.type == []const u8) {
                    const duped = try self.allocator.dupe(u8, value);
                    try self._allocated_strings.append(self.allocator, duped);
                    @field(self, field.name) = duped;
                } else if (field.type == bool) {
                    @field(self, field.name) = if (std.mem.eql(u8, value, "true"))
                        true
                    else if (std.mem.eql(u8, value, "false"))
                        false
                    else
                        return error.InvalidValue;
                } else if (@typeInfo(field.type) == .@"enum") {
                    @field(self, field.name) = std.meta.stringToEnum(field.type, value) orelse return error.InvalidValue;
                } else if (@typeInfo(field.type) == .int) {
                    @field(self, field.name) = std.fmt.parseInt(field.type, value, 10) catch return error.InvalidValue;
                }
                return;
            }
        }
        return error.UnknownProperty;
    }

    pub const save = @import("config_write.zig").Methods(ServerProperties, comments).save;

    pub fn deinit(self: *ServerProperties) void {
        for (self._allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self._allocated_strings.deinit(self.allocator);
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const set_field = test_owner.ServerProperties.setField;
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const WorkerLayout = test_owner.WorkerLayout;
    pub const shouldEmitVerboseStartupLogs = test_owner.shouldEmitVerboseStartupLogs;
    pub const shouldEmitStartupLogs = test_owner.shouldEmitStartupLogs;
    pub const ServerProperties = test_owner.ServerProperties;
};

test "gamemode defaults to survival and validates configured modes" {
    try @import("config_test.zig").Suite(test_scope).case_000();
}

test "gamemode survives saving and loading properties" {
    try @import("config_test.zig").Suite(test_scope).case_001();
}

test "max mtu clamps to the range RakNet supports" {
    try @import("config_test.zig").Suite(test_scope).case_002();
}

test "movement-send-priority keeps whatever the file says and defaults to immediate" {
    try @import("config_test.zig").Suite(test_scope).case_003();
}

test "a saved properties file carries movement-send-priority and loads it back" {
    try @import("config_test.zig").Suite(test_scope).case_004();
}

test "movement distance bands default on and only accept true or false" {
    try @import("config_test.zig").Suite(test_scope).case_005();
}

test "worker layout parses split and shared and rejects garbage" {
    try @import("config_test.zig").Suite(test_scope).case_006();
}

test "inbound ring properties parse and clamp" {
    try @import("config_test.zig").Suite(test_scope).case_007();
}

test "the mob broadcast interval clamps to the supported range" {
    try @import("config_test.zig").Suite(test_scope).case_008();
}

test "max mtu defaults to the RakNet ceiling" {
    try @import("config_test.zig").Suite(test_scope).case_009();
}

test "an existing max-mtu line overrides the default and rejects garbage" {
    try @import("config_test.zig").Suite(test_scope).case_010();
}

test "a saved properties file carries max-mtu and loads it back" {
    try @import("config_test.zig").Suite(test_scope).case_011();
}

test "online mode defaults to off and only accepts true or false" {
    try @import("config_test.zig").Suite(test_scope).case_012();
}

test "unverified online logins are refused unless the fallback is switched on" {
    try @import("config_test.zig").Suite(test_scope).case_013();
}

test "a saved properties file carries online-mode and loads it back" {
    try @import("config_test.zig").Suite(test_scope).case_014();
}

test "verbose startup logs are disabled in release modes" {
    try @import("config_test.zig").Suite(test_scope).case_015();
}

test "startup logs are never emitted from a test binary" {
    try @import("config_test.zig").Suite(test_scope).case_016();
}

test "memory capacities survive saving and loading properties" {
    const allocator = std.testing.allocator;
    var properties = ServerProperties{ .allocator = allocator };
    defer properties.deinit();
    try std.testing.expectEqual(@as(u32, 512), properties.output_slab_slots);
    try std.testing.expectEqual(@as(u32, 128), properties.transient_slab_slots);
    try std.testing.expectEqual(@as(u32, 1024), properties.outbound_queue_slots);
    try std.testing.expectEqual(@as(u32, 1024), properties.ecs_capacity);
    try properties.setField("output-slab-slots", "2048");
    try properties.setField("transient-slab-slots", "256");
    try properties.setField("outbound-queue-slots", "4096");
    try properties.setField("ecs-capacity", "8192");
    try properties.setField("count-allocations", "true");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/memory.properties", .{tmp.sub_path});
    try properties.save(std.testing.io, path);
    var loaded = try ServerProperties.load(std.testing.io, allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 2048), loaded.output_slab_slots);
    try std.testing.expectEqual(@as(u32, 256), loaded.transient_slab_slots);
    try std.testing.expectEqual(@as(u32, 4096), loaded.outbound_queue_slots);
    try std.testing.expectEqual(@as(u32, 8192), loaded.ecs_capacity);
    try std.testing.expect(loaded.count_allocations);
}

test "the client chunk radius clamps to the supported range" {
    try @import("config_test.zig").Suite(test_scope).case_017();
}
