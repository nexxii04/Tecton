const std = @import("std");
const Raknet = @import("Raknet");

pub const Location = struct {
    world: []const u8,
    dimension: []const u8,
};

const OwnedEntry = Location;

pub const PlayerLocations = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    entries: std.StringHashMap(OwnedEntry),
    dirty: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) PlayerLocations {
        return .{
            .allocator = allocator,
            .io = io,
            .path = path,
            .entries = std.StringHashMap(OwnedEntry).init(allocator),
        };
    }

    pub fn deinit(self: *PlayerLocations) void {
        self.clearEntries();
        self.entries.deinit();
    }

    fn clearEntries(self: *PlayerLocations) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.world);
            self.allocator.free(entry.value_ptr.dimension);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn load(self: *PlayerLocations) void {
        self.clearEntries();

        const file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch return;
        defer file.close(self.io);

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        const data = reader.interface.allocRemaining(self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch |err| {
            Raknet.Logger.ERROR("Failed to parse {s}: {any}", .{ self.path, err });
            return;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return,
        };

        var it = root.iterator();
        while (it.next()) |entry| {
            const obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const world_name = jsonString(obj.get("world")) orelse continue;
            const dimension_name = jsonString(obj.get("dimension")) orelse continue;
            self.set(entry.key_ptr.*, world_name, dimension_name);
        }
        self.dirty = false;
    }

    pub fn count(self: *const PlayerLocations) usize {
        return self.entries.count();
    }

    pub fn flush(self: *PlayerLocations) void {
        if (!self.dirty) return;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        self.writeJson(&stringify) catch |err| {
            Raknet.Logger.ERROR("Failed to encode {s}: {any}", .{ self.path, err });
            return;
        };

        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = out.written(),
        }) catch |err| {
            Raknet.Logger.ERROR("Failed to write {s}: {any}", .{ self.path, err });
            return;
        };
        self.dirty = false;
    }

    fn writeJson(self: *PlayerLocations, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try stringify.objectField(entry.key_ptr.*);
            try stringify.beginObject();
            try stringify.objectField("world");
            try stringify.write(entry.value_ptr.world);
            try stringify.objectField("dimension");
            try stringify.write(entry.value_ptr.dimension);
            try stringify.endObject();
        }
        try stringify.endObject();
    }

    pub fn set(self: *PlayerLocations, uuid: []const u8, world: []const u8, dimension: []const u8) void {
        const uuid_copy = self.allocator.dupe(u8, uuid) catch return;
        const world_copy = self.allocator.dupe(u8, world) catch {
            self.allocator.free(uuid_copy);
            return;
        };
        const dimension_copy = self.allocator.dupe(u8, dimension) catch {
            self.allocator.free(uuid_copy);
            self.allocator.free(world_copy);
            return;
        };

        if (self.entries.fetchRemove(uuid)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.world);
            self.allocator.free(old.value.dimension);
        }

        self.entries.put(uuid_copy, .{ .world = world_copy, .dimension = dimension_copy }) catch {
            self.allocator.free(uuid_copy);
            self.allocator.free(world_copy);
            self.allocator.free(dimension_copy);
            return;
        };
        self.dirty = true;
    }

    pub fn get(self: *const PlayerLocations, uuid: []const u8) ?Location {
        return self.entries.get(uuid);
    }

    pub fn getPtr(self: *const PlayerLocations, uuid: []const u8) ?*const Location {
        const entry = self.entries.getPtr(uuid) orelse return null;
        return entry;
    }

    pub fn remove(self: *PlayerLocations, uuid: []const u8) bool {
        const old = self.entries.fetchRemove(uuid) orelse return false;
        self.allocator.free(old.key);
        self.allocator.free(old.value.world);
        self.allocator.free(old.value.dimension);
        self.dirty = true;
        return true;
    }

    fn jsonString(value: ?std.json.Value) ?[]const u8 {
        const val = value orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }
};

test "player locations round trip through json" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/player_locations.json", .{&tmp.sub_path});

    var locations = PlayerLocations.init(std.testing.io, allocator, path);
    defer locations.deinit();

    try std.testing.expect(locations.get("uuid-a") == null);

    locations.set("uuid-a", "world", "overworld");
    locations.set("uuid-b", "arena", "nether");
    try std.testing.expect(locations.dirty);
    locations.flush();
    try std.testing.expect(!locations.dirty);

    var loaded = PlayerLocations.init(std.testing.io, allocator, path);
    defer loaded.deinit();
    loaded.load();

    try std.testing.expectEqual(@as(usize, 2), loaded.entries.count());
    const entry_a = loaded.get("uuid-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("world", entry_a.world);
    try std.testing.expectEqualStrings("overworld", entry_a.dimension);
    const entry_b = loaded.get("uuid-b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("arena", entry_b.world);
    try std.testing.expectEqualStrings("nether", entry_b.dimension);

    locations.set("uuid-a", "arena", "end");
    locations.flush();
    loaded.load();
    const updated = loaded.get("uuid-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("arena", updated.world);
    try std.testing.expectEqualStrings("end", updated.dimension);

    try std.testing.expect(loaded.remove("uuid-b"));
    loaded.flush();

    var reloaded = PlayerLocations.init(std.testing.io, allocator, path);
    defer reloaded.deinit();
    reloaded.load();
    try std.testing.expectEqual(@as(usize, 1), reloaded.entries.count());
    try std.testing.expect(reloaded.get("uuid-b") == null);

    const kept = reloaded.get("uuid-a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("arena", kept.world);
    try std.testing.expectEqualStrings("end", kept.dimension);
}
