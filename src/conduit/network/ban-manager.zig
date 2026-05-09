const std = @import("std");
const Raknet = @import("Raknet");
const shouldEmitVerboseStartupLogs = @import("../config.zig").shouldEmitVerboseStartupLogs;
const builtin = @import("builtin");

pub const BanEntry = struct {
    uuid: []const u8,
    name: []const u8,
    created: []const u8,
    source: []const u8,
    expires: []const u8,
    reason: []const u8,
};

pub const BanManager = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    entries: std.ArrayList(BanEntry),
    path: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) BanManager {
        var mgr = BanManager{
            .io = io,
            .allocator = allocator,
            .entries = .empty,
            .path = path,
        };
        mgr.load();
        return mgr;
    }

    pub fn deinit(self: *BanManager) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.uuid);
            self.allocator.free(entry.name);
            self.allocator.free(entry.created);
            self.allocator.free(entry.source);
            self.allocator.free(entry.expires);
            self.allocator.free(entry.reason);
        }
        if (self.entries.capacity > 0) self.entries.deinit(self.allocator);
    }

    pub fn isBanned(self: *const BanManager, name: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return true;
        }
        return false;
    }

    pub fn isBannedByXuid(self: *const BanManager, uuid: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.uuid, uuid)) return true;
        }
        return false;
    }

    pub fn ban(self: *BanManager, uuid: []const u8, name: []const u8, source: []const u8, reason: []const u8) !void {
        if (self.isBanned(name)) return;

        const entry = BanEntry{
            .uuid = try self.allocator.dupe(u8, uuid),
            .name = try self.allocator.dupe(u8, name),
            .created = try self.allocator.dupe(u8, "unknown"),
            .source = try self.allocator.dupe(u8, source),
            .expires = try self.allocator.dupe(u8, "forever"),
            .reason = try self.allocator.dupe(u8, reason),
        };
        try self.entries.append(self.allocator, entry);
        self.save();
    }

    pub fn unban(self: *BanManager, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                self.allocator.free(entry.uuid);
                self.allocator.free(entry.name);
                self.allocator.free(entry.created);
                self.allocator.free(entry.source);
                self.allocator.free(entry.expires);
                self.allocator.free(entry.reason);
                _ = self.entries.orderedRemove(i);
                self.save();
                return true;
            }
        }
        return false;
    }

    fn load(self: *BanManager) void {
        const file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch return;
        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        const data = reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return,
        };

        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const entry = BanEntry{
                .uuid = self.allocator.dupe(u8, getStr(obj, "uuid")) catch continue,
                .name = self.allocator.dupe(u8, getStr(obj, "name")) catch continue,
                .created = self.allocator.dupe(u8, getStr(obj, "created")) catch continue,
                .source = self.allocator.dupe(u8, getStr(obj, "source")) catch continue,
                .expires = self.allocator.dupe(u8, getStr(obj, "expires")) catch continue,
                .reason = self.allocator.dupe(u8, getStr(obj, "reason")) catch continue,
            };
            self.entries.append(self.allocator, entry) catch continue;
        }
        if (shouldEmitVerboseStartupLogs(builtin.mode)) {
            Raknet.Logger.INFO("Loaded {d} banned players", .{self.entries.items.len});
        }
    }

    fn save(self: *BanManager) void {
        const file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch return;
        defer file.close(self.io);

        var writer = file.writer(self.io, &.{});
        writer.interface.writeAll("[\n") catch return;
        for (self.entries.items, 0..) |entry, i| {
            writer.interface.writeAll("  {\n") catch return;
            writeField(&writer.interface, "uuid", entry.uuid);
            writeField(&writer.interface, "name", entry.name);
            writeField(&writer.interface, "created", entry.created);
            writeField(&writer.interface, "source", entry.source);
            writeField(&writer.interface, "expires", entry.expires);
            writeLastField(&writer.interface, "reason", entry.reason);
            if (i + 1 < self.entries.items.len) {
                writer.interface.writeAll("  },\n") catch return;
            } else {
                writer.interface.writeAll("  }\n") catch return;
            }
        }
        writer.interface.writeAll("]\n") catch return;
        writer.interface.flush() catch |err| {
            std.log.err("failed to flush writer: {}", .{err});
        };
    }

    fn writeField(writer: *std.Io.Writer, key: []const u8, val: []const u8) void {
        var buf: [512]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, "    \"{s}\": \"{s}\",\n", .{ key, val }) catch return;
        writer.writeAll(written) catch {};
    }

    fn writeLastField(writer: *std.Io.Writer, key: []const u8, val: []const u8) void {
        var buf: [512]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, "    \"{s}\": \"{s}\"\n", .{ key, val }) catch return;
        writer.writeAll(written) catch {};
    }

    fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
        const val = obj.get(key) orelse return "";
        return switch (val) {
            .string => |s| s,
            else => "",
        };
    }
};
