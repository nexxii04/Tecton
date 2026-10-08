const std = @import("std");
const Raknet = @import("Raknet");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const Display = @import("../items/traits/display.zig");
const Player = @import("../player/player.zig").Player;

var nextContainerId: i8 = @intFromEnum(Protocol.ContainerId.First);

pub const Container = struct {
    allocator: std.mem.Allocator,
    container_type: Protocol.ContainerType,
    identifier: ?Protocol.ContainerId = null,
    storage: []?ItemStack,
    occupants: std.AutoHashMap(*Player, Protocol.ContainerId),
    muted: bool = false,

    pub fn init(allocator: std.mem.Allocator, container_type: Protocol.ContainerType, size: u32) !Container {
        const storage = try allocator.alloc(?ItemStack, size);
        @memset(storage, null);
        return .{
            .allocator = allocator,
            .container_type = container_type,
            .storage = storage,
            .occupants = std.AutoHashMap(*Player, Protocol.ContainerId).init(allocator),
        };
    }

    pub fn deinit(self: *Container) void {
        for (self.storage) |*slot| {
            if (slot.*) |*item| item.deinit();
        }
        self.allocator.free(self.storage);
        self.occupants.deinit();
    }

    pub fn getSize(self: *const Container) u32 {
        return @intCast(self.storage.len);
    }

    pub fn setSize(self: *Container, new_size: u32) !void {
        const new_storage = try self.allocator.alloc(?ItemStack, new_size);
        const copy_len = @min(self.storage.len, new_size);
        @memcpy(new_storage[0..copy_len], self.storage[0..copy_len]);
        if (new_size > self.storage.len) {
            @memset(new_storage[self.storage.len..], null);
        }
        self.allocator.free(self.storage);
        self.storage = new_storage;
    }

    pub fn emptySlotsCount(self: *const Container) u32 {
        var count: u32 = 0;
        for (self.storage) |slot| {
            if (slot == null) count += 1;
        }
        return count;
    }

    pub fn isFull(self: *const Container) bool {
        return self.emptySlotsCount() == 0;
    }

    pub fn getItem(self: *const Container, slot: u32) ?*const ItemStack {
        if (slot >= self.storage.len) return null;
        return if (self.storage[slot]) |*item| item else null;
    }

    pub fn getItemMut(self: *Container, slot: u32) ?*ItemStack {
        if (slot >= self.storage.len) return null;
        return if (self.storage[slot] != null) &(self.storage[slot].?) else null;
    }

    pub fn setItem(self: *Container, slot: u32, item: ItemStack) void {
        if (slot >= self.storage.len) {
            var dropped = item;
            dropped.deinit();
            return;
        }
        if (self.storage[slot]) |*old| old.deinit();
        self.storage[slot] = item;

        if (item.stack_size == 0 or std.mem.eql(u8, item.item_type.identifier, "minecraft:air")) {
            self.storage[slot] = null;
        }

        self.updateSlot(slot);
    }

    pub fn clearSlot(self: *Container, slot: u32) void {
        if (slot >= self.storage.len) return;
        if (self.storage[slot]) |*item| item.deinit();
        self.storage[slot] = null;
        self.updateSlot(slot);
    }

    pub fn clear(self: *Container) void {
        for (self.storage) |*slot| {
            if (slot.*) |*item| item.deinit();
            slot.* = null;
        }
        if (self.occupants.count() > 0) self.update();
    }

    pub fn addItem(self: *Container, item: ItemStack) bool {
        var remaining: u16 = item.stack_size;

        if (item.item_type.stackable) {
            for (self.storage, 0..) |*slot, i| {
                if (remaining == 0) break;
                if (slot.*) |*existing| {
                    if (existing.isStackCompatible(&item) and existing.stack_size < existing.item_type.max_stack_size) {
                        const space = existing.item_type.max_stack_size - existing.stack_size;
                        const to_add = @min(space, remaining);
                        existing.stack_size += to_add;
                        remaining -= to_add;
                        self.updateSlot(@intCast(i));
                    }
                }
            }
        }

        while (remaining > 0) {
            const empty_slot = for (self.storage, 0..) |slot, i| {
                if (slot == null) break i;
            } else break;

            const to_place = @min(remaining, item.item_type.max_stack_size);
            self.storage[empty_slot] = item.cloneWithCount(self.allocator, to_place) catch return false;
            remaining -= to_place;
            self.updateSlot(@intCast(empty_slot));
        }

        return remaining == 0;
    }

    pub fn removeItem(self: *Container, slot: u32, amount: u16) void {
        if (slot >= self.storage.len) return;
        const item = &(self.storage[slot] orelse return);
        const removed = @min(amount, item.stack_size);
        item.stack_size -= removed;
        if (item.stack_size == 0) {
            item.deinit();
            self.storage[slot] = null;
        }
        self.updateSlot(slot);
    }

    pub fn takeItem(self: *Container, slot: u32, amount: u16) ?ItemStack {
        if (slot >= self.storage.len) return null;
        const item = self.storage[slot] orelse return null;
        if (amount >= item.stack_size) {
            self.storage[slot] = null;
            self.updateSlot(slot);
            return item;
        }
        self.storage[slot].?.stack_size -= amount;
        self.updateSlot(slot);
        return item.cloneWithCount(self.allocator, amount) catch return null;
    }

    pub fn swapItems(self: *Container, slot: u32, other_slot: u32, other_container: ?*Container) void {
        const target = other_container orelse self;
        if (slot >= self.storage.len or other_slot >= target.storage.len) return;
        const idx_a = slot;
        const idx_b = other_slot;

        const item_a = self.storage[idx_a];
        const item_b = target.storage[idx_b];

        self.storage[idx_a] = item_b;
        target.storage[idx_b] = item_a;

        self.updateSlot(idx_a);
        target.updateSlot(idx_b);
    }

    pub fn updateSlot(self: *Container, slot: u32) void {
        if (self.muted) return;

        const item_stack = if (slot < self.storage.len) self.storage[slot] else null;
        const network_item = if (item_stack) |item| item.toNetworkStack() else Protocol.NetworkItemStackDescriptor{
            .network = 0,
            .stack_size = null,
            .metadata = null,
            .item_stack_id = null,
            .network_block_id = null,
            .extras = null,
        };

        var iter = self.occupants.iterator();
        while (iter.next()) |entry| {
            const player = entry.key_ptr.*;
            const id = entry.value_ptr.*;

            var stream = BinaryStream.init(self.allocator, null, null);
            defer stream.deinit();

            const packet = Protocol.InventorySlotPacket{
                .container_id = id,
                .slot = slot,
                .full_container_name = .{ .identifier = .Container, .dynamic_identifier = 0 },
                .storage_item = .{ .network = 0, .stack_size = null, .metadata = null, .item_stack_id = null, .network_block_id = null, .extras = null },
                .item = network_item,
            };
            const serialized = packet.serialize(&stream) catch continue;
            player.network.sendPacket(player.connection, serialized) catch continue;
        }
    }

    pub fn update(self: *Container) void {
        if (self.muted) return;

        const items = self.allocator.alloc(Protocol.NetworkItemStackDescriptor, self.storage.len) catch return;
        defer self.allocator.free(items);

        for (self.storage, 0..) |slot, i| {
            items[i] = if (slot) |item| item.toNetworkStack() else Protocol.NetworkItemStackDescriptor{
                .network = 0,
                .stack_size = null,
                .metadata = null,
                .item_stack_id = null,
                .network_block_id = null,
                .extras = null,
            };
        }

        var iter = self.occupants.iterator();
        while (iter.next()) |entry| {
            const player = entry.key_ptr.*;
            const id = entry.value_ptr.*;

            var stream = BinaryStream.init(self.allocator, null, null);
            defer stream.deinit();

            const packet = Protocol.InventoryContentPacket{
                .container_id = id,
                .items = items,
                .full_container_name = .{ .identifier = .Container, .dynamic_identifier = 0 },
                .storage_item = .{ .network = 0, .stack_size = null, .metadata = null, .item_stack_id = null, .network_block_id = null, .extras = null },
            };
            const serialized = packet.serialize(&stream) catch continue;
            player.network.sendPacket(player.connection, serialized) catch continue;
        }
    }

    pub fn show(self: *Container, player: *Player) Protocol.ContainerId {
        if (player.opened_container) |opened| opened.close(player, true);

        const id = getNextContainerId();
        self.occupants.put(player, id) catch return .None;
        player.opened_container = self;
        return id;
    }

    pub fn close(self: *Container, player: *Player, server_initiated: bool) void {
        const id = self.occupants.get(player) orelse return;

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const packet = Protocol.ContainerClosePacket{
            .identifier = id,
            .container_type = self.container_type,
            .server_initiated = server_initiated,
        };
        const serialized = packet.serialize(&stream) catch return;
        player.network.sendPacket(player.connection, serialized) catch {};

        player.opened_container = null;
        _ = self.occupants.remove(player);
    }

    pub fn getAllOccupants(self: *const Container) std.AutoHashMap(*Player, Protocol.ContainerId) {
        return self.occupants;
    }

    pub fn getNextContainerId() Protocol.ContainerId {
        const id: Protocol.ContainerId = @enumFromInt(nextContainerId);
        nextContainerId += 1;
        if (nextContainerId > @intFromEnum(Protocol.ContainerId.Last)) {
            nextContainerId = @intFromEnum(Protocol.ContainerId.First);
        }
        return id;
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("../items/item_type.zig");
    pub const std = test_owner.std;
    pub const ItemStack = test_owner.ItemStack;
    pub const Display = test_owner.Display;
    pub const Container = test_owner.Container;
};

test "slot access beyond size returns null instead of wrapping" {
    try @import("container_test.zig").Suite(test_scope).case_000();
}

test "takeItem preserves item nbt when splitting a stack" {
    try @import("container_test.zig").Suite(test_scope).case_001();
}
