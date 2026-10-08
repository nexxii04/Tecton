const std = @import("std");
const builtin = @import("builtin");
const Raknet = @import("Raknet");
const Protocol = @import("protocol");
const WorkerLayout = @import("tasks/threaded_tasks.zig").WorkerLayout;

pub fn shouldEmitVerboseStartupLogs(mode: std.builtin.OptimizeMode) bool {
    return mode == .Debug;
}

pub fn shouldEmitStartupLogs() bool {
    return shouldEmitVerboseStartupLogs(builtin.mode) and !builtin.is_test;
}

pub const ServerProperties = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    motd: []const u8 = "Tecton Server",
    gamemode: []const u8 = "survival",
    max_players: u32 = 120,
    online_mode: bool = false,
    online_mode_offline_fallback: bool = false,
    max_tps: u32 = 20,
    worker_threads: u32 = 0,
    worker_layout: WorkerLayout = .split,
    parallel_visibility: bool = true,
    max_view_distance: u32 = 16,
    simulation_distance: u32 = 4,
    max_mtu: u16 = max_max_mtu,
    movement_send_priority: []const u8 = "immediate",
    movement_distance_bands: bool = true,
    network_inbound_ring: bool = true,
    inbound_ring_slots: u32 = 8192,
    inbound_ring_slot_size: u32 = 1536,
    mob_broadcast_interval: u8 = 2,
    default_group: []const u8 = "member",

    allocator: std.mem.Allocator,
    _allocated_strings: std.ArrayList([]const u8) = .empty,

    pub const min_max_mtu: u16 = 576;
    pub const max_max_mtu: u16 = Raknet.MAX_MTU_SIZE;

    pub fn clampMaxMtu(requested: u16) u16 {
        return @min(@max(requested, min_max_mtu), max_max_mtu);
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
        .inbound_ring_slot_size = "Bytes per inbound ring slot (clamped to 512-65536; larger datagrams use a heap fallback)",
        .mob_broadcast_interval = "Ticks between in-air mob movement broadcasts (clamped to 1-20; 1 is the old every-tick behavior)",
        .default_group = "Default permission group for new players",
    };

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ServerProperties {
        Raknet.Logger.init(allocator);
        var self = ServerProperties{ .allocator = allocator };
        errdefer self.deinit();

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (shouldEmitStartupLogs()) {
                    Raknet.Logger.INFO("server.properties not found, creating with defaults", .{});
                }
                try self.save(io, path);
                return self;
            },
            else => return err,
        };
        defer file.close(io);

        if (shouldEmitStartupLogs()) {
            Raknet.Logger.INFO("Loading server.properties", .{});
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
                Raknet.Logger.WARN("Unknown or invalid property: {s} ({any})", .{ key, err });
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

    pub fn save(self: *const ServerProperties, io: std.Io, path: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        inline for (@typeInfo(ServerProperties).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "allocator") or
                std.mem.eql(u8, field.name, "_allocated_strings")) continue;

            const file_key = comptime blk: {
                var name_buf: [field.name.len]u8 = undefined;
                @memcpy(&name_buf, field.name);
                std.mem.replaceScalar(u8, &name_buf, '_', '-');
                break :blk name_buf;
            };

            if (@hasField(@TypeOf(comments), field.name)) {
                const comment = std.fmt.bufPrint(buf[pos..], "# {s}\n", .{@field(comments, field.name)}) catch return error.BufferOverflow;
                pos += comment.len;
            }

            const val = @field(self, field.name);
            const line = if (field.type == []const u8)
                std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, val }) catch return error.BufferOverflow
            else if (field.type == bool)
                std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, if (val) "true" else "false" }) catch return error.BufferOverflow
            else if (@typeInfo(field.type) == .@"enum")
                std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, @tagName(val) }) catch return error.BufferOverflow
            else if (@typeInfo(field.type) == .int)
                std.fmt.bufPrint(buf[pos..], "{s}={d}\n", .{ file_key, val }) catch return error.BufferOverflow
            else
                unreachable;
            pos += line.len;
        }

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var write_buf: [4098]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        writer.interface.writeAll(buf[0..pos]) catch return error.WriteError;
        writer.interface.flush() catch |err| {
            std.log.err("failed to flush writer: {}", .{err});
        };
    }

    pub fn deinit(self: *ServerProperties) void {
        for (self._allocated_strings.items) |s| {
            self.allocator.free(s);
        }
        self._allocated_strings.deinit(self.allocator);
    }
};

test "gamemode defaults to survival and validates configured modes" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
    try properties.setField("gamemode", "creative");
    try std.testing.expectEqual(Protocol.GameMode.Creative, properties.gameMode());
    try properties.setField("gamemode", "Adventure");
    try std.testing.expectEqual(Protocol.GameMode.Adventure, properties.gameMode());
    try properties.setField("gamemode", "spectator");
    try std.testing.expectEqual(Protocol.GameMode.Spectator, properties.gameMode());
    try properties.setField("gamemode", "survival");
    try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
    try std.testing.expectError(error.InvalidValue, properties.setField("gamemode", "invalid"));
    try std.testing.expectEqual(Protocol.GameMode.Survival, properties.gameMode());
}

test "gamemode survives saving and loading properties" {
    const path = "test-gamemode.properties";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try properties.setField("gamemode", "adventure");
    try properties.save(std.testing.io, path);
    var loaded = try ServerProperties.load(std.testing.io, std.testing.allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(Protocol.GameMode.Adventure, loaded.gameMode());
}

test "max mtu clamps to the range RakNet supports" {
    const clamp = ServerProperties.clampMaxMtu;
    try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(ServerProperties.max_max_mtu));
    try std.testing.expectEqual(@as(u16, 1400), clamp(1492));
    try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(std.math.maxInt(u16)));
    try std.testing.expectEqual(@as(u16, 1028), clamp(1028));
    try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(ServerProperties.min_max_mtu));
    try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(0));
}

test "movement-send-priority keeps whatever the file says and defaults to immediate" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expectEqualStrings("immediate", properties.movement_send_priority);

    try properties.setField("movement-send-priority", "normal");
    try std.testing.expectEqualStrings("normal", properties.movement_send_priority);

    try std.testing.expectError(error.UnknownProperty, properties.setField("movement-send_priority", "normal"));
}

test "a saved properties file carries movement-send-priority and loads it back" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "test-movement-priority.properties";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var properties = ServerProperties{ .allocator = allocator };
    defer properties.deinit();
    properties.movement_send_priority = "immediate";
    try properties.save(io, path);

    var content: [8192]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const bytes = try reader.interface.readSliceShort(&content);
    try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nmovement-send-priority=immediate\n") != null);

    var loaded = try ServerProperties.load(io, allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("immediate", loaded.movement_send_priority);
}

test "movement distance bands default on and only accept true or false" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expect(properties.movement_distance_bands);

    try properties.setField("movement-distance-bands", "false");
    try std.testing.expect(!properties.movement_distance_bands);

    try properties.setField("movement-distance-bands", "true");
    try std.testing.expect(properties.movement_distance_bands);

    try std.testing.expectError(error.InvalidValue, properties.setField("movement-distance-bands", "maybe"));
}

test "worker layout parses split and shared and rejects garbage" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expectEqual(WorkerLayout.split, properties.worker_layout);

    try properties.setField("worker-layout", "shared");
    try std.testing.expectEqual(WorkerLayout.shared, properties.worker_layout);
    try properties.setField("worker-layout", "split");
    try std.testing.expectEqual(WorkerLayout.split, properties.worker_layout);

    try std.testing.expectError(error.InvalidValue, properties.setField("worker-layout", "chunky"));
    try std.testing.expectError(error.UnknownProperty, properties.setField("worker-layouts", "split"));
}

test "inbound ring properties parse and clamp" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expect(properties.network_inbound_ring);
    try std.testing.expectEqual(@as(u32, 8192), properties.inbound_ring_slots);
    try std.testing.expectEqual(@as(u32, 1536), properties.inbound_ring_slot_size);

    try properties.setField("network-inbound-ring", "false");
    try std.testing.expect(!properties.network_inbound_ring);
    try properties.setField("network-inbound-ring", "true");
    try std.testing.expect(properties.network_inbound_ring);
    try std.testing.expectError(error.InvalidValue, properties.setField("network-inbound-ring", "maybe"));

    try properties.setField("inbound-ring-slots", "16384");
    try std.testing.expectEqual(@as(u32, 16384), properties.inbound_ring_slots);
    try properties.setField("inbound-ring-slot-size", "2048");
    try std.testing.expectEqual(@as(u32, 2048), properties.inbound_ring_slot_size);

    try std.testing.expectEqual(ServerProperties.min_inbound_ring_slots, ServerProperties.clampInboundRingSlots(0));
    try std.testing.expectEqual(ServerProperties.max_inbound_ring_slots, ServerProperties.clampInboundRingSlots(std.math.maxInt(u32)));
    try std.testing.expectEqual(ServerProperties.min_inbound_ring_slot_size, ServerProperties.clampInboundRingSlotSize(1));
    try std.testing.expectEqual(ServerProperties.max_inbound_ring_slot_size, ServerProperties.clampInboundRingSlotSize(std.math.maxInt(u32)));
}

test "the mob broadcast interval clamps to the supported range" {
    const clamp = ServerProperties.clampMobBroadcastInterval;
    try std.testing.expectEqual(@as(u8, 1), clamp(0));
    try std.testing.expectEqual(@as(u8, 1), clamp(1));
    try std.testing.expectEqual(@as(u8, 2), clamp(2));
    try std.testing.expectEqual(@as(u8, 20), clamp(20));
    try std.testing.expectEqual(@as(u8, 20), clamp(std.math.maxInt(u8)));

    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expectEqual(@as(u8, 2), properties.mob_broadcast_interval);
    try properties.setField("mob-broadcast-interval", "4");
    try std.testing.expectEqual(@as(u8, 4), properties.mob_broadcast_interval);
    try std.testing.expectError(error.InvalidValue, properties.setField("mob-broadcast-interval", "fast"));
}

test "max mtu defaults to the RakNet ceiling" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expectEqual(ServerProperties.max_max_mtu, properties.max_mtu);
}

test "an existing max-mtu line overrides the default and rejects garbage" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();

    try properties.setField("max-mtu", "1028");
    try std.testing.expectEqual(@as(u16, 1028), properties.max_mtu);

    try std.testing.expectError(error.InvalidValue, properties.setField("max-mtu", "big"));
    try std.testing.expectError(error.UnknownProperty, properties.setField("mtu", "1028"));
}

test "a saved properties file carries max-mtu and loads it back" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "test-max-mtu.properties";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var properties = ServerProperties{ .allocator = allocator };
    defer properties.deinit();
    properties.max_mtu = 1188;
    try properties.save(io, path);

    var content: [4096]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const bytes = try reader.interface.readSliceShort(&content);
    try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nmax-mtu=1188\n") != null);

    var loaded = try ServerProperties.load(io, allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u16, 1188), loaded.max_mtu);
    try std.testing.expectEqual(@as(u16, 19132), loaded.port);
}

test "online mode defaults to off and only accepts true or false" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expect(!properties.online_mode);

    try properties.setField("online-mode", "true");
    try std.testing.expect(properties.online_mode);

    try properties.setField("online-mode", "false");
    try std.testing.expect(!properties.online_mode);

    try std.testing.expectError(error.InvalidValue, properties.setField("online-mode", "yes"));
    try std.testing.expect(!properties.online_mode);
}

test "unverified online logins are refused unless the fallback is switched on" {
    var properties = ServerProperties{ .allocator = std.testing.allocator };
    defer properties.deinit();
    try std.testing.expect(!properties.online_mode_offline_fallback);

    try properties.setField("online-mode-offline-fallback", "true");
    try std.testing.expect(properties.online_mode_offline_fallback);

    try properties.setField("online-mode-offline-fallback", "false");
    try std.testing.expect(!properties.online_mode_offline_fallback);

    try std.testing.expectError(error.InvalidValue, properties.setField("online-mode-offline-fallback", "maybe"));
}

test "a saved properties file carries online-mode and loads it back" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const path = "test-online-mode.properties";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var properties = ServerProperties{ .allocator = allocator };
    defer properties.deinit();
    try properties.save(io, path);

    var content: [8192]u8 = undefined;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const bytes = try reader.interface.readSliceShort(&content);
    try std.testing.expect(std.mem.indexOf(u8, content[0..bytes], "\nonline-mode=false\n") != null);

    var loaded = try ServerProperties.load(io, allocator, path);
    defer loaded.deinit();
    try std.testing.expect(!loaded.online_mode);
}

test "verbose startup logs are disabled in release modes" {
    try std.testing.expect(shouldEmitVerboseStartupLogs(.Debug));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseFast));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSafe));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSmall));
}

test "startup logs are never emitted from a test binary" {
    try std.testing.expect(!shouldEmitStartupLogs());
}
