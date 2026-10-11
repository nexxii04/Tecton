const std = @import("std");
const Raknet = @import("Raknet");
const shouldEmitStartupLogs = @import("../core/config.zig").shouldEmitStartupLogs;

pub const PermissionGroup = struct {
    name: []const u8,
    permissions: std.StringHashMap(void),
};

pub const PermissionManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    groups: std.StringHashMap(*PermissionGroup),
    player_groups: std.StringHashMap([]const u8),
    default_group: []const u8,
    path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8, default_group: []const u8) PermissionManager {
        var mgr = PermissionManager{
            .io = io,
            .allocator = allocator,
            .groups = std.StringHashMap(*PermissionGroup).init(allocator),
            .player_groups = std.StringHashMap([]const u8).init(allocator),
            .default_group = default_group,
            .path = path,
        };
        mgr.load();
        if (mgr.groups.count() == 0) mgr.createDefaults();
        return mgr;
    }

    pub fn deinit(self: *PermissionManager) void {
        var git = self.groups.valueIterator();
        while (git.next()) |group| {
            var kit = group.*.permissions.keyIterator();
            while (kit.next()) |key| {
                self.allocator.free(key.*);
            }
            self.allocator.free(group.*.name);
            group.*.permissions.deinit();
            self.allocator.destroy(group.*);
        }
        self.groups.deinit();
        var pit = self.player_groups.iterator();
        while (pit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.player_groups.deinit();
    }

    pub fn hasPermission(self: *const PermissionManager, player_name: []const u8, permission: []const u8) bool {
        if (permission.len == 0) return true;

        const group_name = self.player_groups.get(player_name) orelse self.default_group;
        const group = self.groups.get(group_name) orelse return false;

        if (group.permissions.contains("*")) return true;
        if (group.permissions.contains(permission)) return true;

        if (std.mem.lastIndexOfScalar(u8, permission, '.')) |dot| {
            var buf: [128]u8 = undefined;
            if (dot + 2 <= buf.len) {
                @memcpy(buf[0..dot], permission[0..dot]);
                buf[dot] = '.';
                buf[dot + 1] = '*';
                if (group.permissions.contains(buf[0 .. dot + 2])) return true;
            }
        }

        return false;
    }

    pub fn getPlayerGroup(self: *const PermissionManager, player_name: []const u8) []const u8 {
        return self.player_groups.get(player_name) orelse self.default_group;
    }

    pub fn setPlayerGroup(self: *PermissionManager, player_name: []const u8, group_name: []const u8) !void {
        if (!self.groups.contains(group_name)) return error.GroupNotFound;

        const val = try self.allocator.dupe(u8, group_name);
        errdefer self.allocator.free(val);
        if (self.player_groups.getPtr(player_name)) |entry| {
            const old = entry.*;
            entry.* = val;
            self.save() catch |err| {
                entry.* = old;
                return err;
            };
            self.allocator.free(old);
        } else {
            const key = try self.allocator.dupe(u8, player_name);
            errdefer self.allocator.free(key);
            try self.player_groups.put(key, val);
            self.save() catch |err| {
                _ = self.player_groups.remove(key);
                return err;
            };
        }
    }

    fn createDefaults(self: *PermissionManager) void {
        self.createGroup("member", &.{
            "tecton.command.about",
        }) catch {};
        self.createGroup("operator", &.{
            "*",
        }) catch {};
        self.save() catch |err| {
            std.debug.print("Failed to save permissions {s}: {s}\n", .{ self.path, @errorName(err) });
        };
    }

    fn createGroup(self: *PermissionManager, name: []const u8, perms: []const []const u8) !void {
        const group = try self.allocator.create(PermissionGroup);
        group.* = .{
            .name = try self.allocator.dupe(u8, name),
            .permissions = std.StringHashMap(void).init(self.allocator),
        };
        for (perms) |p| {
            try group.permissions.put(try self.allocator.dupe(u8, p), {});
        }
        try self.groups.put(group.name, group);
    }

    fn load(self: *PermissionManager) void {
        const file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch return;
        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        const data = reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        if (root.get("groups")) |groups_val| {
            const groups_obj = switch (groups_val) {
                .object => |o| o,
                else => return,
            };
            var git = groups_obj.iterator();
            while (git.next()) |entry| {
                const group = self.allocator.create(PermissionGroup) catch continue;
                group.* = .{
                    .name = self.allocator.dupe(u8, entry.key_ptr.*) catch continue,
                    .permissions = std.StringHashMap(void).init(self.allocator),
                };
                const perms_arr = switch (entry.value_ptr.*) {
                    .array => |a| a,
                    else => continue,
                };
                for (perms_arr.items) |perm_val| {
                    const perm_str = switch (perm_val) {
                        .string => |s| s,
                        else => continue,
                    };
                    const duped = self.allocator.dupe(u8, perm_str) catch continue;
                    group.permissions.put(duped, {}) catch continue;
                }
                self.groups.put(group.name, group) catch continue;
            }
        }

        if (root.get("players")) |players_val| {
            const players_obj = switch (players_val) {
                .object => |o| o,
                else => return,
            };
            var pit = players_obj.iterator();
            while (pit.next()) |entry| {
                const val_str = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                const val = self.allocator.dupe(u8, val_str) catch continue;
                self.player_groups.put(key, val) catch continue;
            }
        }

        if (shouldEmitStartupLogs()) {
            Raknet.Logger.INFO("Loaded {d} permission groups, {d} player assignments", .{ self.groups.count(), self.player_groups.count() });
        }
    }

    fn save(self: *PermissionManager) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const writer = &out.writer;
        try writer.writeAll("{\n  \"groups\": {\n");
        var gi: usize = 0;
        var git = self.groups.iterator();
        while (git.next()) |entry| {
            try writer.print("    \"{s}\": [\n", .{entry.key_ptr.*});

            var pi: usize = 0;
            const perm_count = entry.value_ptr.*.permissions.count();
            var pit = entry.value_ptr.*.permissions.keyIterator();
            while (pit.next()) |perm| {
                const comma: []const u8 = if (pi + 1 < perm_count) "," else "";
                try writer.print("      \"{s}\"{s}\n", .{ perm.*, comma });
                pi += 1;
            }

            gi += 1;
            if (gi < self.groups.count()) {
                try writer.writeAll("    ],\n");
            } else {
                try writer.writeAll("    ]\n");
            }
        }

        try writer.writeAll("  },\n  \"players\": {\n");
        var pli: usize = 0;
        var plit = self.player_groups.iterator();
        while (plit.next()) |entry| {
            pli += 1;
            const comma: []const u8 = if (pli < self.player_groups.count()) "," else "";
            try writer.print("    \"{s}\": \"{s}\"{s}\n", .{ entry.key_ptr.*, entry.value_ptr.*, comma });
        }
        try writer.writeAll("  }\n}\n");

        const permissions = if (std.Io.Dir.cwd().statFile(self.io, self.path, .{})) |stat| blk: {
            if (stat.permissions.readOnly()) return error.AccessDenied;
            break :blk stat.permissions;
        } else |err| switch (err) {
            error.FileNotFound => std.Io.File.Permissions.default_file,
            else => return err,
        };
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{ .replace = true, .permissions = permissions });
        defer atomic.deinit(self.io);
        var file_writer = atomic.file.writer(self.io, &.{});
        try file_writer.interface.writeAll(out.written());
        try file_writer.interface.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};

test "permission manager loads existing groups and assignments without rewriting the file" {
    try @import("permission_manager_test.zig").test_existing_permissions(PermissionManager);
}

test "permission manager persists a large permissions document" {
    try @import("permission_manager_test.zig").test_large_permissions(PermissionManager);
}

test "permission manager preserves legacy bytes through a save and reload round trip" {
    try @import("permission_manager_test.zig").test_format_round_trip(PermissionManager);
}

test "permission manager creates missing permissions and persists assignments" {
    try @import("permission_manager_test.zig").test_missing_permissions(PermissionManager);
}

test "permission manager preserves disk and memory after a partial write failure" {
    try @import("permission_manager_test.zig").test_failed_write(PermissionManager);
}

test "permission manager rejects read only permissions without changing assignments" {
    try @import("permission_manager_test.zig").test_read_only(PermissionManager);
}

test "permission manager preserves the original file when replacement fails" {
    try @import("permission_manager_test.zig").test_failed_replace(PermissionManager);
}

test "permission manager defaults restrict players to the member group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var mgr = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer mgr.deinit();

    try std.testing.expect(mgr.getPlayerGroup("alice").len > 0);
    try std.testing.expectEqualStrings("member", mgr.getPlayerGroup("alice"));
    try std.testing.expect(mgr.hasPermission("alice", "tecton.command.about"));
    try std.testing.expect(!mgr.hasPermission("alice", "tecton.command.kick"));
    try std.testing.expect(!mgr.hasPermission("alice", "tecton.command.op"));
    try std.testing.expect(!mgr.hasPermission("alice", "tecton.command.floatingtext"));

    try mgr.setPlayerGroup("bob", "operator");
    try std.testing.expectEqualStrings("operator", mgr.getPlayerGroup("bob"));
    try std.testing.expect(mgr.hasPermission("bob", "tecton.command.kick"));
    try std.testing.expect(mgr.hasPermission("bob", "tecton.command.op"));
}
