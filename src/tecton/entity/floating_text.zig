const std = @import("std");

const Protocol = @import("protocol");

const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
const Compression = @import("../network/compression/compression.zig").Compression;
const CompressionOptions = @import("../network/compression/options.zig").CompressionOptions;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const Entity = @import("./entity.zig").Entity;
const Player = @import("../player/player.zig").Player;

pub const FloatingText = struct {
    allocator: std.mem.Allocator,
    dimension: *Dimension,
    runtime_id: i64,
    unique_id: i64,
    name: []const u8,
    title: []const u8,
    text: []const u8,
    name_tag: []const u8,
    position: Protocol.Vector3f,
    block_runtime_id: i32,
    viewers: std.AutoHashMap(i64, void),
    add_packet: []const u8,
    remove_packet: []const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        dimension: *Dimension,
        name: []const u8,
        title: []const u8,
        text: []const u8,
        position: Protocol.Vector3f,
        runtime_id: i64,
        block_runtime_id: i32,
    ) !*FloatingText {
        const hologram = try allocator.create(FloatingText);
        errdefer allocator.destroy(hologram);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const title_copy = try allocator.dupe(u8, title);
        errdefer allocator.free(title_copy);
        const text_copy = try allocator.dupe(u8, text);
        errdefer allocator.free(text_copy);
        const name_tag = try Protocol.FloatingText.composeNameTag(allocator, title_copy, text_copy);
        errdefer allocator.free(name_tag);

        hologram.* = .{
            .allocator = allocator,
            .dimension = dimension,
            .runtime_id = runtime_id,
            .unique_id = runtime_id,
            .name = name_copy,
            .title = title_copy,
            .text = text_copy,
            .name_tag = name_tag,
            .position = position,
            .block_runtime_id = block_runtime_id,
            .viewers = std.AutoHashMap(i64, void).init(allocator),
            .add_packet = &.{},
            .remove_packet = &.{},
        };
        errdefer hologram.viewers.deinit();

        try hologram.encode();
        return hologram;
    }

    pub fn destroy(self: *FloatingText) void {
        const allocator = self.allocator;
        self.freePackets();
        self.viewers.deinit();
        allocator.free(self.name_tag);
        allocator.free(self.text);
        allocator.free(self.title);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn encode(self: *FloatingText) !void {
        const packets = try self.buildPackets(self.name_tag);
        self.freePackets();
        self.add_packet = packets.add;
        self.remove_packet = packets.remove;
    }

    pub fn setText(self: *FloatingText, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        const name_tag = try Protocol.FloatingText.composeNameTag(self.allocator, self.title, text_copy);
        errdefer self.allocator.free(name_tag);

        const packets = try self.buildPackets(name_tag);

        self.allocator.free(self.text);
        self.allocator.free(self.name_tag);
        self.freePackets();

        self.text = text_copy;
        self.name_tag = name_tag;
        self.add_packet = packets.add;
        self.remove_packet = packets.remove;
    }

    const Packets = struct {
        add: []const u8,
        remove: []const u8,
    };

    fn buildPackets(self: *const FloatingText, name_tag: []const u8) !Packets {
        const add = try Protocol.FloatingText.encodeAdd(
            self.allocator,
            self.unique_id,
            self.runtime_id,
            self.position,
            name_tag,
            self.block_runtime_id,
        );
        errdefer self.allocator.free(add);

        const remove = try Protocol.FloatingText.encodeRemove(self.allocator, self.unique_id);
        errdefer self.allocator.free(remove);

        return .{ .add = add, .remove = remove };
    }

    fn freePackets(self: *FloatingText) void {
        if (self.add_packet.len > 0) self.allocator.free(self.add_packet);
        if (self.remove_packet.len > 0) self.allocator.free(self.remove_packet);
        self.add_packet = &.{};
        self.remove_packet = &.{};
    }
};

pub const FloatingTextManager = struct {
    pub const MAX_FLOATING_TEXTS: usize = 256;
    pub const MAX_FREE_RUNTIME_IDS: usize = 512;

    allocator: std.mem.Allocator,
    dimension: *Dimension,
    texts: std.ArrayList(*FloatingText),
    by_name: std.StringHashMap(*FloatingText),
    free_runtime_ids: std.ArrayList(i64),
    air_block_runtime_id: i32,

    viewers_mutex: std.Io.Mutex = .init,

    pub fn create(allocator: std.mem.Allocator, dimension: *Dimension) !*FloatingTextManager {
        const manager = try allocator.create(FloatingTextManager);
        manager.* = .{
            .allocator = allocator,
            .dimension = dimension,
            .texts = .empty,
            .by_name = std.StringHashMap(*FloatingText).init(allocator),
            .free_runtime_ids = .empty,
            .air_block_runtime_id = resolveAirBlockRuntimeId(allocator),
        };
        return manager;
    }

    pub fn destroy(self: *FloatingTextManager) void {
        for (self.texts.items) |hologram| hologram.destroy();
        self.texts.deinit(self.allocator);
        self.by_name.deinit();
        self.free_runtime_ids.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn find(self: *const FloatingTextManager, name: []const u8) ?*FloatingText {
        return self.by_name.get(name);
    }

    pub fn items(self: *const FloatingTextManager) []const *FloatingText {
        return self.texts.items;
    }

    pub fn add(self: *FloatingTextManager, name: []const u8, text: []const u8, position: Protocol.Vector3f) !*FloatingText {
        if (self.by_name.contains(name)) return error.FloatingTextAlreadyExists;
        if (self.texts.items.len >= MAX_FLOATING_TEXTS) return error.FloatingTextLimitReached;

        const runtime_id = self.acquireRuntimeId();
        const hologram = FloatingText.create(
            self.allocator,
            self.dimension,
            name,
            "",
            text,
            position,
            runtime_id,
            self.air_block_runtime_id,
        ) catch |err| {
            self.releaseRuntimeId(runtime_id);
            return err;
        };
        errdefer hologram.destroy();
        errdefer self.releaseRuntimeId(hologram.runtime_id);

        try self.by_name.put(hologram.name, hologram);
        errdefer _ = self.by_name.remove(hologram.name);

        try self.texts.append(self.allocator, hologram);

        self.showToNearbyPlayers(hologram);
        return hologram;
    }

    pub fn edit(self: *FloatingTextManager, name: []const u8, text: []const u8) !*FloatingText {
        const hologram = self.by_name.get(name) orelse return error.FloatingTextNotFound;
        try hologram.setText(text);
        self.refreshViewers(hologram);
        return hologram;
    }

    pub fn remove(self: *FloatingTextManager, name: []const u8) !void {
        const hologram = self.by_name.get(name) orelse return error.FloatingTextNotFound;
        self.despawn(hologram);
    }

    pub fn updateVisibilityForPlayer(self: *FloatingTextManager, player: *Player) void {
        if (!self.canTrack(player)) return;

        const io = self.dimension.world.tecton.io;
        self.viewers_mutex.lock(io) catch return;
        defer self.viewers_mutex.unlock(io);

        for (self.texts.items) |hologram| {
            const in_range = isInRange(hologram, player);
            const tracked = hologram.viewers.contains(player.entity.runtime_id);
            if (in_range and !tracked) {
                self.showToPlayer(hologram, player);
            } else if (!in_range and tracked) {
                self.hideFromPlayer(hologram, player);
            }
        }
    }

    pub fn forgetViewer(self: *FloatingTextManager, player_runtime_id: i64) void {
        for (self.texts.items) |hologram| {
            _ = hologram.viewers.remove(player_runtime_id);
        }
    }

    pub fn despawnForViewer(self: *FloatingTextManager, player: *Player) void {
        for (self.texts.items) |hologram| {
            if (!hologram.viewers.remove(player.entity.runtime_id)) continue;
            self.sendPacket(player, hologram.remove_packet);
        }
    }

    fn canTrack(self: *const FloatingTextManager, player: *const Player) bool {
        if (!player.spawned) return false;
        if (player.pending_removal.load(.acquire)) return false;
        if (player.entity.dimension != self.dimension) return false;
        return player.entity.instance_id == self.dimension.instance_id;
    }

    fn refreshViewers(self: *FloatingTextManager, hologram: *FloatingText) void {
        const tecton = self.dimension.world.tecton;
        const packets = [_][]const u8{ hologram.remove_packet, hologram.add_packet };
        var viewer_it = hologram.viewers.keyIterator();
        while (viewer_it.next()) |runtime_id| {
            const player = tecton.players.byRuntimeId(runtime_id.*) orelse continue;
            tecton.network.sendPackets(player.connection, &packets) catch {};
        }
    }

    fn showToNearbyPlayers(self: *FloatingTextManager, hologram: *FloatingText) void {
        const snapshots = self.dimension.world.tecton.getPlayerSnapshots();
        for (snapshots) |player| {
            if (!self.canTrack(player)) continue;
            if (!isInRange(hologram, player)) continue;
            self.showToPlayer(hologram, player);
        }
    }

    fn showToPlayer(self: *FloatingTextManager, hologram: *FloatingText, player: *Player) void {
        self.sendPacket(player, hologram.add_packet);
        hologram.viewers.put(player.entity.runtime_id, {}) catch {};
    }

    fn hideFromPlayer(self: *FloatingTextManager, hologram: *FloatingText, player: *Player) void {
        self.sendPacket(player, hologram.remove_packet);
        _ = hologram.viewers.remove(player.entity.runtime_id);
    }

    fn sendPacket(self: *FloatingTextManager, player: *Player, packet: []const u8) void {
        self.dimension.world.tecton.network.sendPacket(player.connection, packet) catch {};
    }

    fn despawn(self: *FloatingTextManager, hologram: *FloatingText) void {
        const tecton = self.dimension.world.tecton;
        var viewer_it = hologram.viewers.keyIterator();
        while (viewer_it.next()) |runtime_id| {
            const player = tecton.players.byRuntimeId(runtime_id.*) orelse continue;
            tecton.network.sendPacket(player.connection, hologram.remove_packet) catch {};
        }
        hologram.viewers.clearRetainingCapacity();

        _ = self.by_name.remove(hologram.name);
        if (std.mem.indexOfScalar(*FloatingText, self.texts.items, hologram)) |index| {
            _ = self.texts.swapRemove(index);
        }

        self.releaseRuntimeId(hologram.runtime_id);
        hologram.destroy();
    }

    fn acquireRuntimeId(self: *FloatingTextManager) i64 {
        if (self.free_runtime_ids.pop()) |runtime_id| return runtime_id;
        return Entity.nextRuntimeId();
    }

    fn releaseRuntimeId(self: *FloatingTextManager, runtime_id: i64) void {
        if (self.free_runtime_ids.items.len >= MAX_FREE_RUNTIME_IDS) return;
        self.free_runtime_ids.append(self.allocator, runtime_id) catch {};
    }
};

fn isInRange(hologram: *const FloatingText, player: *const Player) bool {
    const dx = player.entity.position.x - hologram.position.x;
    const dz = player.entity.position.z - hologram.position.z;
    return Dimension.withinViewDistance(dx, dz, player.view_distance);
}

fn resolveAirBlockRuntimeId(allocator: std.mem.Allocator) i32 {
    const air = BlockPermutation.resolve(allocator, "minecraft:air", null) catch return 0;
    return air.network_id;
}

test "setText refreshes the name tag and the actor packets" {
    const allocator = std.testing.allocator;

    const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Hola", Protocol.Vector3f.init(1, 2, 3), 7, 0);
    defer hologram.destroy();

    try std.testing.expectEqualStrings("Hola", hologram.name_tag);

    try hologram.setText("Adios\nLinea 2");

    try std.testing.expectEqualStrings("Adios\nLinea 2", hologram.text);
    try std.testing.expectEqualStrings("Adios\nLinea 2", hologram.name_tag);
    try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.RemoveActor)), hologram.remove_packet[0]);
    try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.AddEntity)), hologram.add_packet[0]);
    try std.testing.expectEqual(@as(usize, 2), hologram.remove_packet.len);
}

test "the refresh travels as two batch entries" {
    const allocator = std.testing.allocator;

    const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Hola", Protocol.Vector3f.init(1, 2, 3), 7, 0);
    defer hologram.destroy();

    try hologram.setText("Adios");

    try std.testing.expect(std.mem.indexOf(u8, hologram.add_packet, "Adios") != null);

    const entries = [_][]const u8{ hologram.remove_packet, hologram.add_packet };
    const options = CompressionOptions{ .compression_method = .Zlib, .compression_threshold = 0 };
    const batch = try Compression.compress(&entries, options, allocator);
    defer allocator.free(batch);

    const result = try Compression.decompress(batch, options, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.packets.len);
    try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.RemoveActor)), result.packets[0][0]);
    try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.AddEntity)), result.packets[1][0]);
}

test "setText keeps tracked viewers across repeated edits" {
    const allocator = std.testing.allocator;

    const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Uno", Protocol.Vector3f.init(0, 0, 0), 9, 0);
    defer hologram.destroy();

    try hologram.viewers.put(11, {});
    try hologram.viewers.put(22, {});

    try hologram.setText("Dos");
    try hologram.setText("Tres");

    try std.testing.expectEqualStrings("Tres", hologram.name_tag);
    try std.testing.expectEqual(@as(usize, 2), hologram.viewers.count());
}
