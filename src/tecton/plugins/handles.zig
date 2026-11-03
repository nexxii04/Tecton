const std = @import("std");

pub const Kind = enum(u8) {
    world = 1,
    player = 2,
    entity = 3,
    item = 4,
    block = 5,
    inventory = 6,
    registration = 7,
    command = 8,
};

pub const none: u32 = std.math.maxInt(u32);

/// Slots store the address of their owner list head; a Table must not move once it owns handles.
pub const Table = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot),
    free_slots: std.ArrayList(u32),
    index: std.AutoHashMapUnmanaged(usize, u32),
    runtime_head: u32 = none,

    const Slot = struct {
        pointer: usize = 0,
        generation: u32 = 1,
        kind: Kind = .world,
        owner_plugin_id: u32 = 0,
        next_owned: u32 = none,
        prev_owned: u32 = none,
        head: ?*u32 = null,
        active: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_slots = .empty,
            .index = .empty,
        };
    }

    pub fn deinit(self: *Table) void {
        self.slots.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
        self.index.deinit(self.allocator);
    }

    pub fn put(self: *Table, kind: Kind, pointer: usize, owner_plugin_id: u32, head: *u32) !u64 {
        if (pointer == 0) return error.InvalidPointer;
        if (self.index.get(pointer)) |existing| {
            const slot = self.slots.items[existing];
            if (slot.active) {
                if (slot.kind != kind) return error.InvalidPointer;
                if (slot.owner_plugin_id == owner_plugin_id or slot.owner_plugin_id == 0) {
                    return encode(kind, existing, slot.generation);
                }

                // Cross-owner reuse becomes runtime-owned so one plugin's unload cannot invalidate another's handle.
                self.promote(existing);
                return encode(kind, existing, slot.generation);
            }
        }

        try self.index.ensureUnusedCapacity(self.allocator, 1);
        const index = if (self.free_slots.pop()) |value| value else blk: {
            const value: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{});
            errdefer _ = self.slots.pop();
            try self.free_slots.ensureTotalCapacity(self.allocator, self.slots.items.len);
            break :blk value;
        };

        self.index.putAssumeCapacity(pointer, index);
        var slot = &self.slots.items[index];
        if (slot.generation == 0) slot.generation = 1;
        slot.pointer = pointer;
        slot.kind = kind;
        slot.owner_plugin_id = owner_plugin_id;
        slot.active = true;
        slot.head = head;
        slot.prev_owned = none;
        slot.next_owned = head.*;
        if (head.* != none) self.slots.items[head.*].prev_owned = index;
        head.* = index;
        return encode(kind, index, slot.generation);
    }

    pub fn get(self: *const Table, kind: Kind, handle: u64) ?usize {
        const decoded = decode(handle) orelse return null;
        if (decoded.kind != kind or decoded.index >= self.slots.items.len) return null;
        const slot = self.slots.items[decoded.index];
        if (!slot.active or slot.generation != decoded.generation) return null;
        return slot.pointer;
    }

    pub fn ownerOf(self: *const Table, pointer: usize) ?u32 {
        const index = self.index.get(pointer) orelse return null;
        const slot = self.slots.items[index];
        if (!slot.active) return null;
        return slot.owner_plugin_id;
    }

    pub fn handleFor(self: *const Table, kind: Kind, pointer: usize) ?u64 {
        const index = self.index.get(pointer) orelse return null;
        if (index >= self.slots.items.len) return null;
        const slot = self.slots.items[index];
        if (!slot.active or slot.kind != kind) return null;
        return encode(kind, index, slot.generation);
    }

    pub fn remove(self: *Table, kind: Kind, handle: u64) bool {
        const decoded = decode(handle) orelse return false;
        if (decoded.kind != kind or decoded.index >= self.slots.items.len) return false;
        const slot = self.slots.items[decoded.index];
        if (!slot.active or slot.generation != decoded.generation) return false;
        self.unlink(decoded.index);
        self.invalidate(decoded.index);
        return true;
    }

    pub fn removePointer(self: *Table, kind: Kind, pointer: usize) bool {
        const index = self.index.get(pointer) orelse return false;
        const slot = self.slots.items[index];
        if (!slot.active or slot.kind != kind) return false;
        self.unlink(index);
        self.invalidate(index);
        return true;
    }

    pub fn removeOwner(self: *Table, plugin_id: u32, head: *u32) usize {
        if (plugin_id == 0) return 0;
        var current = head.*;
        while (current != none) {
            if (current >= self.slots.items.len) return 0;
            const slot = self.slots.items[current];
            if (!slot.active or slot.owner_plugin_id != plugin_id or slot.head != head) return 0;
            current = slot.next_owned;
        }

        current = head.*;
        head.* = none;
        var count: usize = 0;
        while (current != none) {
            const next = self.slots.items[current].next_owned;
            self.invalidate(current);
            count += 1;
            current = next;
        }
        return count;
    }

    pub fn activeCount(self: *const Table) usize {
        var count: usize = 0;
        for (self.slots.items) |slot| {
            if (slot.active) count += 1;
        }
        return count;
    }

    pub fn countOwner(self: *const Table, head: *const u32) usize {
        var count: usize = 0;
        var current = head.*;
        while (current != none) {
            if (current >= self.slots.items.len) return count;
            const slot = self.slots.items[current];
            if (!slot.active or slot.head != head) return count;
            count += 1;
            current = slot.next_owned;
        }
        return count;
    }

    fn promote(self: *Table, index: u32) void {
        self.unlink(index);
        var slot = &self.slots.items[index];
        slot.owner_plugin_id = 0;
        slot.head = &self.runtime_head;
        slot.prev_owned = none;
        slot.next_owned = self.runtime_head;
        if (self.runtime_head != none) self.slots.items[self.runtime_head].prev_owned = index;
        self.runtime_head = index;
    }

    fn unlink(self: *Table, index: u32) void {
        const slot = self.slots.items[index];
        const head = slot.head orelse return;
        if (slot.prev_owned != none) {
            self.slots.items[slot.prev_owned].next_owned = slot.next_owned;
        } else {
            head.* = slot.next_owned;
        }
        if (slot.next_owned != none) self.slots.items[slot.next_owned].prev_owned = slot.prev_owned;
        var current = &self.slots.items[index];
        current.head = null;
        current.next_owned = none;
        current.prev_owned = none;
    }

    fn invalidate(self: *Table, index: u32) void {
        var slot = &self.slots.items[index];
        _ = self.index.remove(slot.pointer);
        slot.active = false;
        slot.pointer = 0;
        slot.owner_plugin_id = 0;
        slot.next_owned = none;
        slot.prev_owned = none;
        slot.head = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.free_slots.appendAssumeCapacity(index);
    }

    fn encode(kind: Kind, index: u32, generation: u32) u64 {
        return (@as(u64, @intFromEnum(kind)) << 56) | (@as(u64, generation & 0x00ff_ffff) << 32) | @as(u64, index);
    }

    const Decoded = struct {
        kind: Kind,
        index: u32,
        generation: u32,
    };

    fn decode(handle: u64) ?Decoded {
        const kind: Kind = switch (@as(u8, @intCast(handle >> 56))) {
            1 => .world,
            2 => .player,
            3 => .entity,
            4 => .item,
            5 => .block,
            6 => .inventory,
            7 => .registration,
            8 => .command,
            else => return null,
        };
        return .{
            .kind = kind,
            .index = @intCast(handle & 0xffff_ffff),
            .generation = @intCast((handle >> 32) & 0x00ff_ffff),
        };
    }
};

test "handles reject stale generations and foreign kinds" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var head: u32 = none;
    const first = try table.put(.world, 0x1234, 1, &head);
    try std.testing.expectEqual(@as(usize, 0x1234), table.get(.world, first).?);
    try std.testing.expect(table.remove(.world, first));
    try std.testing.expect(table.get(.world, first) == null);

    const second = try table.put(.world, 0x5678, 1, &head);
    try std.testing.expect(second != first);
    try std.testing.expectEqual(@as(usize, 0x5678), table.get(.world, second).?);

    const foreign_kind = (@as(u64, 200) << 56) | (second & 0x00ff_ffff_ffff_ffff);
    try std.testing.expect(table.get(.world, foreign_kind) == null);
    try std.testing.expect(!table.remove(.world, foreign_kind));
}

test "handle dedupe and owner removal are scoped" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var first_owner: u32 = none;
    var second_owner: u32 = none;
    const world = try table.put(.world, 0x1000, 1, &first_owner);
    try std.testing.expectEqual(world, try table.put(.world, 0x1000, 1, &first_owner));
    _ = try table.put(.entity, 0x2000, 1, &first_owner);
    const item = try table.put(.item, 0x3000, 2, &second_owner);

    try std.testing.expectEqual(@as(usize, 2), table.removeOwner(1, &first_owner));
    try std.testing.expect(table.get(.world, world) == null);
    try std.testing.expectEqual(@as(usize, 0x3000), table.get(.item, item).?);
    try std.testing.expect(table.handleFor(.item, 0x3000) != null);
    try std.testing.expect(table.handleFor(.item, 0x1000) == null);

    const reused = try table.put(.world, 0x4000, 2, &second_owner);
    try std.testing.expect(table.removePointer(.world, 0x4000));
    try std.testing.expect(table.get(.world, reused) == null);
}

test "a foreign head cannot remove another owner's handles" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var owner_one: u32 = none;
    var owner_two: u32 = none;
    const world = try table.put(.world, 0x5000, 1, &owner_one);
    _ = try table.put(.world, 0x6000, 1, &owner_one);

    try std.testing.expectEqual(@as(usize, 0), table.removeOwner(2, &owner_one));
    try std.testing.expect(table.get(.world, world) != null);
    try std.testing.expectEqual(@as(usize, 2), table.removeOwner(1, &owner_one));
    try std.testing.expectEqual(@as(usize, 0), table.activeCount());

    _ = try table.put(.world, 0x7000, 2, &owner_two);
    try std.testing.expectEqual(@as(usize, 0), table.removeOwner(2, &owner_one));
    try std.testing.expectEqual(@as(usize, 1), table.activeCount());
}

test "cross-owner dedupe promotes the handle to runtime lifetime" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var first_owner: u32 = none;
    var second_owner: u32 = none;
    const world = try table.put(.world, 0x8000, 1, &first_owner);
    try std.testing.expectEqual(world, try table.put(.world, 0x8000, 2, &second_owner));
    try std.testing.expectEqual(@as(u32, 0), table.ownerOf(0x8000).?);
    try std.testing.expectEqual(@as(usize, 0), table.removeOwner(1, &first_owner));
    try std.testing.expectEqual(@as(usize, 0), table.removeOwner(2, &second_owner));
    try std.testing.expectEqual(@as(usize, 0x8000), table.get(.world, world).?);

    try std.testing.expect(table.removePointer(.world, 0x8000));
    try std.testing.expect(table.get(.world, world) == null);
}
