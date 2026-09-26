const std = @import("std");

const Protocol = @import("protocol");

const BlockPermutation = @import("../world/block/block-permutation.zig").BlockPermutation;
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
        if (self.add_packet.len > 0) allocator.free(self.add_packet);
        if (self.remove_packet.len > 0) allocator.free(self.remove_packet);
        self.viewers.deinit();
        allocator.free(self.name_tag);
        allocator.free(self.text);
        allocator.free(self.title);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn encode(self: *FloatingText) !void {
        if (self.add_packet.len > 0) self.allocator.free(self.add_packet);
        if (self.remove_packet.len > 0) self.allocator.free(self.remove_packet);
        self.add_packet = &.{};
        self.remove_packet = &.{};

        const add_packet = try Protocol.FloatingText.encodeAdd(
            self.allocator,
            self.unique_id,
            self.runtime_id,
            self.position,
            self.name_tag,
            self.block_runtime_id,
        );
        errdefer self.allocator.free(add_packet);

        const remove_packet = try Protocol.FloatingText.encodeRemove(self.allocator, self.unique_id);
        self.add_packet = add_packet;
        self.remove_packet = remove_packet;
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

    pub fn remove(self: *FloatingTextManager, name: []const u8) !void {
        const hologram = self.by_name.get(name) orelse return error.FloatingTextNotFound;
        self.despawn(hologram);
    }

    pub fn updateVisibilityForPlayer(self: *FloatingTextManager, player: *Player) void {
        if (!self.canTrack(player)) return;

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

    fn showToNearbyPlayers(self: *FloatingTextManager, hologram: *FloatingText) void {
        const snapshots = self.dimension.world.conduit.getPlayerSnapshots();
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
        self.dimension.world.conduit.network.sendPacket(player.connection, packet) catch {};
    }

    fn despawn(self: *FloatingTextManager, hologram: *FloatingText) void {
        const conduit = self.dimension.world.conduit;
        var viewer_it = hologram.viewers.keyIterator();
        while (viewer_it.next()) |runtime_id| {
            const player = conduit.players.get(runtime_id.*) orelse continue;
            conduit.network.sendPacket(player.connection, hologram.remove_packet) catch {};
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
