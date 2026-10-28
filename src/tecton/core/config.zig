const std = @import("std");
const log = @import("log.zig");
const builtin = @import("builtin");
const Protocol = @import("protocol");
const WorkerLayout = @import("../tasks/threaded_tasks.zig").WorkerLayout;

pub const default_jwks_uri = "https://authorization.franchise.minecraft-services.net/.well-known/keys";

/// How signaling TLS is provided. `proxy` leaves the plain listener to an external terminator;
/// `native` terminates TLS inside the server.
pub const TlsMode = enum { off, proxy, native };

pub fn shouldEmitVerboseStartupLogs(mode: std.builtin.OptimizeMode) bool {
    return mode == .Debug;
}

pub fn shouldEmitStartupLogs() bool {
    return shouldEmitVerboseStartupLogs(builtin.mode) and !builtin.is_test;
}

pub const ServerProperties = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    signaling_bind: []const u8 = "",
    tls_mode: TlsMode = .off,
    motd: []const u8 = "Tecton Server",
    level_name: []const u8 = "Bedrock level",
    gamemode: []const u8 = "survival",
    max_players: u32 = 120,
    online_mode: bool = false,
    online_mode_offline_fallback: bool = false,
    jwks_uri: []const u8 = default_jwks_uri,
    identity_key: []const u8 = "server.key",
    require_client_identity: bool = false,
    lan_discovery: bool = true,
    lan_port: u16 = 7551,
    public_candidate: []const u8 = "",
    ice_servers: []const u8 = "",
    max_sessions: u32 = 0,
    max_message_size: u32 = 256 * 1024,
    transport_tick_ms: u32 = 10,
    max_tps: u32 = 20,
    worker_threads: u32 = 0,
    worker_layout: WorkerLayout = .split,
    parallel_visibility: bool = true,
    max_view_distance: u32 = 8,
    simulation_distance: u32 = 4,
    movement_send_priority: []const u8 = "immediate",
    movement_channel: []const u8 = "reliable",
    movement_distance_bands: bool = true,
    network_inbound_ring: bool = true,
    inbound_ring_slots: u32 = 512,
    inbound_ring_slot_size: u32 = 1536,
    ecs_capacity: u32 = 1024,
    count_allocations: bool = false,
    mob_broadcast_interval: u8 = 2,
    default_group: []const u8 = "member",

    allocator: std.mem.Allocator,
    _allocated_strings: std.ArrayList([]const u8) = .empty,

    pub const min_transport_tick_ms: u32 = 5;
    pub const max_transport_tick_ms: u32 = 50;

    pub fn clampTransportTickMs(requested: u32) u32 {
        return std.math.clamp(requested, min_transport_tick_ms, max_transport_tick_ms);
    }

    pub const min_max_sessions: u32 = 64;
    pub const max_max_sessions: u32 = 4096;

    pub fn clampMaxSessions(requested: u32) u32 {
        return std.math.clamp(requested, min_max_sessions, max_max_sessions);
    }

    /// `max-sessions=0` follows the player limit, which keeps a queue of joining clients.
    pub fn effectiveMaxSessions(self: *const ServerProperties) u32 {
        if (self.max_sessions != 0) return clampMaxSessions(self.max_sessions);
        return clampMaxSessions(@max(min_max_sessions, self.max_players +| 32));
    }

    pub const min_max_message_size: u32 = 1024;
    pub const max_max_message_size: u32 = 256 * 1024;

    pub fn clampMaxMessageSize(requested: u32) u32 {
        return std.math.clamp(requested, min_max_message_size, max_max_message_size);
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
        .address = "Address the signaling listener binds to when signaling-bind is empty; empty means all interfaces",
        .port = "Signaling port (the LAN discovery listener advertises this port)",
        .signaling_bind = "Host the plain signaling listener binds to instead of address (empty follows address; the port stays port)",
        .tls_mode = "Signaling TLS: off leaves signaling plain, proxy is terminated in front of the server, native terminates in the server",
        .motd = "What motd should server display in the server list",
        .level_name = "Level name shown to clients before they join",
        .gamemode = "Default game mode: survival, creative, adventure or spectator",
        .max_players = "Max Player count on the server",
        .online_mode = "Verify logins against the Minecraft authorization service; an unverifiable login is refused (see online-mode-offline-fallback)",
        .online_mode_offline_fallback = "With online-mode=true, let unverified logins in as offline identities instead of refusing them",
        .jwks_uri = "JWKS endpoint that verifies player identity tokens; must be https (empty trusts only the operator key)",
        .identity_key = "Path to the operator key that signs signaling answers (created on first start, keep it secret)",
        .require_client_identity = "Reject client identity tokens that do not chain to the operator or a JWKS key",
        .lan_discovery = "Answer LAN discovery pings on UDP",
        .lan_port = "LAN discovery port",
        .public_candidate = "Host advertised to clients for ICE (empty uses the address the client reached)",
        .ice_servers = "Comma-separated ICE servers as stun:<host>:<port> or turn:<host>:<port>@<user>:<pass> (empty disables STUN and TURN)",
        .max_sessions = "Concurrent NetherNet sessions per listener (0 follows max-players; clamped to 64-4096)",
        .max_message_size = "Largest NetherNet message accepted from a client, in bytes (clamped to 1024-262144; each session's outbox slab is sized to this, with a 64 KiB floor and 512 descriptor slots)",
        .transport_tick_ms = "Milliseconds between NetherNet transport ticks (clamped to 5-50)",
        .max_tps = "Max tps",
        .worker_threads = "Tecton worker threads (0 = auto, higher values are clamped)",
        .worker_layout = "Worker layout: split dedicates max(1, cpu/4) workers to input and the rest to world; shared restores the single queue",
        .parallel_visibility = "Run the per-viewer player visibility pass on the world workers instead of inline in the player tick (false restores the serial pass)",
        .max_view_distance = "Max view distance in chunks",
        .simulation_distance = "Simulation distance in chunks (chunks within this range are kept loaded)",
        .movement_send_priority = "Movement broadcast priority: immediate or normal (the NetherNet outbox is FIFO; neither changes reliability)",
        .movement_channel = "Movement broadcast channel: reliable (ordered, may fragment) or unreliable (no retransmits, must fit one message)",
        .movement_distance_bands = "Rate-limit player movement updates by distance to the nearest viewer (false restores a delta every tick)",
        .network_inbound_ring = "Use the zero-alloc SPSC inbound ring instead of the per-packet heap queue (false restores the legacy path)",
        .inbound_ring_slots = "Inbound ring slots (clamped to 64-1048576 and rounded up to a power of two)",
        .inbound_ring_slot_size = "Bytes per inbound ring slot (clamped to 512-65536; larger payloads use bounded overflow slots)",
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

    /// A verified login identity is part of the online-mode contract, so the explicit
    /// switch can only tighten it.
    pub fn clientIdentityRequired(self: *const ServerProperties) bool {
        return self.require_client_identity or self.online_mode;
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
    pub const TlsMode = test_owner.TlsMode;
    pub const default_jwks_uri = test_owner.default_jwks_uri;
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

test "transport tick clamps to the supported range" {
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

test "max sessions defaults to following the player limit" {
    try @import("config_test.zig").Suite(test_scope).case_009();
}

test "an existing max-sessions line overrides the default and rejects garbage" {
    try @import("config_test.zig").Suite(test_scope).case_010();
}

test "a saved properties file carries max-sessions and loads it back" {
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
    try std.testing.expectEqual(@as(u32, 256 * 1024), properties.max_message_size);
    try std.testing.expectEqual(@as(u32, 1024), properties.ecs_capacity);
    try properties.setField("max-message-size", "524288");
    try properties.setField("ecs-capacity", "8192");
    try properties.setField("count-allocations", "true");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/memory.properties", .{tmp.sub_path});
    try properties.save(std.testing.io, path);
    var loaded = try ServerProperties.load(std.testing.io, allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 524288), loaded.max_message_size);
    try std.testing.expectEqual(@as(u32, 8192), loaded.ecs_capacity);
    try std.testing.expect(loaded.count_allocations);
}

test "the client chunk radius clamps to the supported range" {
    try @import("config_test.zig").Suite(test_scope).case_017();
}

test "the signaling keys parse and only accept known values" {
    try @import("config_test.zig").Suite(test_scope).case_018();
}

test "a properties file with the removed keys still loads" {
    try @import("config_test.zig").Suite(test_scope).case_019();
}

test "NAT and identity overrides parse" {
    try @import("config_test.zig").Suite(test_scope).case_020();
}

test "movement-channel keeps whatever the file says and defaults to reliable" {
    try @import("config_test.zig").Suite(test_scope).case_021();
}
