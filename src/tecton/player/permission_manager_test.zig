const std = @import("std");
const builtin = @import("builtin");

const fixture = "{\"groups\":{\"member\":[\"tecton.command.about\"],\"operator\":[\"*\"]},\"players\":{\"Alice\":\"member\",\"Bob\":\"operator\"}}";

pub fn test_large_permissions(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"groups\":{\"member\":[],\"operator\":[\"*\"]},\"players\":{");
    for (0..8000) |i| {
        try out.writer.print("{s}\"Player{d}\":\"member\"", .{ if (i == 0) "" else ",", i });
    }
    try out.writer.writeAll("}}");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = out.written() });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    try manager.setPlayerGroup("Player7999", "operator");
    var loaded = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 8000), loaded.player_groups.count());
    try std.testing.expectEqualStrings("operator", loaded.getPlayerGroup("Player7999"));
    try std.testing.expectEqualStrings("member", loaded.getPlayerGroup("Player0"));
}

pub fn test_format_round_trip(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "{\n  \"groups\": {\n    \"member\": [\n      \"tecton.command.about\"\n    ]\n  },\n  \"players\": {\n    \"Alice\": \"member\"\n  }\n}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = content });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    try manager.setPlayerGroup("Alice", "member");
    const after = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(content, after);
    var loaded = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer loaded.deinit();
    try loaded.setPlayerGroup("Alice", "member");
    const reloaded = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualStrings(content, reloaded);
}

pub fn test_missing_permissions(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    try manager.setPlayerGroup("Alice", "operator");
    var loaded = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("operator", loaded.getPlayerGroup("Alice"));
}

pub fn test_failed_write(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = fixture });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    const Fail = struct {
        fn write(raw: ?*anyopaque, file: std.Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
            if (offset > 0) return error.NoSpaceLeft;
            _ = header;
            _ = splat;
            return std.testing.io.vtable.fileWritePositional(raw, file, &.{}, &.{data[0][0..@min(16, data[0].len)]}, 1, offset);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.fileWritePositional = Fail.write;
    manager.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.WriteFailed, manager.setPlayerGroup("Alice", "operator"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("Alice"));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(fixture, after);
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

pub fn test_read_only(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = fixture });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();

    var ro_file: ?std.Io.File = null;
    var ro_prev: std.Io.File.Permissions = .default_file;
    defer {
        if (ro_file) |f| {
            f.setPermissions(std.testing.io, ro_prev) catch {};
            f.close(std.testing.io);
        }
    }

    if (comptime builtin.os.tag == .windows) {
        const Deny = struct {
            fn stat(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
                var st = try std.testing.io.vtable.dirStatFile(userdata, dir, sub_path, options);
                st.permissions = @enumFromInt(@intFromEnum(st.permissions) | 0x1);
                return st;
            }
        };
        var vtable = std.testing.io.vtable.*;
        vtable.dirStatFile = Deny.stat;
        manager.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    } else {
        const file = try tmp.dir.openFile(std.testing.io, "permissions.json", .{});
        ro_file = file;
        ro_prev = (try file.stat(std.testing.io)).permissions;
        try file.setPermissions(std.testing.io, ro_prev.setReadOnly(true));
    }
    try std.testing.expectError(error.AccessDenied, manager.setPlayerGroup("Alice", "operator"));
    try std.testing.expectError(error.AccessDenied, manager.setPlayerGroup("NewPlayer", "operator"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("Alice"));
    try std.testing.expect(!manager.player_groups.contains("NewPlayer"));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(fixture, after);
}

pub fn test_failed_replace(comptime PermissionManager: type) !void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "permissions.json", .data = fixture });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{tmp.sub_path});
    var manager = PermissionManager.init(std.testing.io, std.testing.allocator, path, "member");
    defer manager.deinit();
    const Fail = struct {
        fn rename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.dirRename = Fail.rename;
    manager.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.AccessDenied, manager.setPlayerGroup("NewPlayer", "operator"));
    try std.testing.expect(!manager.player_groups.contains("NewPlayer"));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "permissions.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(fixture, after);
    var it = tmp.dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

pub fn test_existing_permissions(comptime PermissionManager: type) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content =
        \\{
        \\  "groups": {
        \\    "member": ["tecton.command.about"],
        \\    "operator": ["*"]
        \\  },
        \\  "players": {
        \\    "ArchBaseline": "operator",
        \\    "ArchObserver": "member"
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "permissions.json", .data = content });
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});

    var manager = PermissionManager.init(io, allocator, path, "member");
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 2), manager.groups.count());
    try std.testing.expectEqual(@as(usize, 2), manager.player_groups.count());
    try std.testing.expectEqualStrings("operator", manager.getPlayerGroup("ArchBaseline"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("ArchObserver"));
    try std.testing.expectEqualStrings("member", manager.getPlayerGroup("NewPlayer"));
    try std.testing.expect(manager.hasPermission("ArchBaseline", "tecton.command.give"));
    try std.testing.expect(manager.hasPermission("ArchObserver", "tecton.command.about"));
    try std.testing.expect(!manager.hasPermission("ArchObserver", "tecton.command.give"));

    const after = try tmp.dir.readFileAlloc(io, "permissions.json", allocator, .limited(1024 * 1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(content, after);
}
