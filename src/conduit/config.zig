const std = @import("std");
const builtin = @import("builtin");
const Raknet = @import("Raknet");

pub fn shouldEmitVerboseStartupLogs(mode: std.builtin.OptimizeMode) bool {
    return mode == .Debug;
}

pub const ServerProperties = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 19132,
    motd: []const u8 = "Conduit Server",
    max_players: u32 = 120,
    online_mode: bool = true,
    max_tps: u32 = 20,
    worker_threads: u32 = 0,
    max_view_distance: u32 = 16,
    simulation_distance: u32 = 4,
    max_mtu: u16 = max_max_mtu,
    default_group: []const u8 = "member",

    allocator: std.mem.Allocator,
    _allocated_strings: std.ArrayList([]const u8) = .empty,

    // 576 is the IPv4 minimum reassembly size, the smallest MTU a RakNet handshake survives.
    pub const min_max_mtu: u16 = 576;
    pub const max_max_mtu: u16 = Raknet.MAX_MTU_SIZE;

    pub fn clampMaxMtu(requested: u16) u16 {
        return @min(@max(requested, min_max_mtu), max_max_mtu);
    }

    const comments = .{
        .address = "What address should the server run on",
        .port = "What port should the server run on",
        .motd = "What motd should server display in the server list",
        .max_players = "Max Player count on the server",
        .online_mode = "Whether to use online mode (WIP)",
        .max_tps = "Max tps",
        .worker_threads = "Conduit worker threads (0 = auto, higher values are clamped)",
        .max_view_distance = "Max view distance in chunks",
        .simulation_distance = "Simulation distance in chunks (chunks within this range are kept loaded)",
        .max_mtu = "Max RakNet MTU (clamped to 576-1400; clients still negotiate the minimum with this cap)",
        .default_group = "Default permission group for new players",
    };

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ServerProperties {
        Raknet.Logger.init(allocator);
        var self = ServerProperties{ .allocator = allocator };
        errdefer self.deinit();

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (shouldEmitVerboseStartupLogs(builtin.mode)) {
                    Raknet.Logger.INFO("server.properties not found, creating with defaults", .{});
                }
                try self.save(io, path);
                return self;
            },
            else => return err,
        };
        defer file.close(io);

        if (shouldEmitVerboseStartupLogs(builtin.mode)) {
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

    fn setField(self: *ServerProperties, key: []const u8, value: []const u8) !void {
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
                    @field(self, field.name) = std.mem.eql(u8, value, "true");
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

test "max mtu clamps to the range RakNet supports" {
    const clamp = ServerProperties.clampMaxMtu;
    try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(ServerProperties.max_max_mtu));
    try std.testing.expectEqual(@as(u16, 1400), clamp(1492));
    try std.testing.expectEqual(ServerProperties.max_max_mtu, clamp(std.math.maxInt(u16)));
    try std.testing.expectEqual(@as(u16, 1028), clamp(1028));
    try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(ServerProperties.min_max_mtu));
    try std.testing.expectEqual(ServerProperties.min_max_mtu, clamp(0));
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

test "verbose startup logs are disabled in release modes" {
    try std.testing.expect(shouldEmitVerboseStartupLogs(.Debug));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseFast));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSafe));
    try std.testing.expect(!shouldEmitVerboseStartupLogs(.ReleaseSmall));
}
