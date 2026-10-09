const std = @import("std");

pub const Kind = enum(u8) {
    world = 1,
    player = 2,
    entity = 3,
    item = 4,
    block = 5,
    inventory = 6,
    registration = 7,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot),
    free_slots: std.ArrayList(u32),

    const Slot = struct {
        pointer: usize = 0,
        generation: u32 = 1,
        kind: Kind = .world,
        active: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_slots = .empty,
        };
    }

    pub fn deinit(self: *Table) void {
        self.slots.deinit(self.allocator);
        self.free_slots.deinit(self.allocator);
    }

    pub fn put(self: *Table, kind: Kind, pointer: usize) !u64 {
        if (pointer == 0) return error.InvalidPointer;
        for (self.slots.items, 0..) |slot, index| {
            if (slot.active and slot.kind == kind and slot.pointer == pointer) {
                return encode(kind, @intCast(index), slot.generation);
            }
        }

        const index = if (self.free_slots.pop()) |value| value else blk: {
            const value: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{});
            break :blk value;
        };
        var slot = &self.slots.items[index];
        if (slot.generation == 0) slot.generation = 1;
        slot.pointer = pointer;
        slot.kind = kind;
        slot.active = true;
        return encode(kind, index, slot.generation);
    }

    pub fn get(self: *const Table, kind: Kind, handle: u64) ?usize {
        const decoded = decode(handle) orelse return null;
        if (decoded.kind != kind or decoded.index >= self.slots.items.len) return null;
        const slot = self.slots.items[decoded.index];
        if (!slot.active or slot.generation != decoded.generation) return null;
        return slot.pointer;
    }

    pub fn remove(self: *Table, kind: Kind, handle: u64) bool {
        const decoded = decode(handle) orelse return false;
        if (decoded.kind != kind or decoded.index >= self.slots.items.len) return false;
        var slot = &self.slots.items[decoded.index];
        if (!slot.active or slot.generation != decoded.generation) return false;
        slot.active = false;
        slot.pointer = 0;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.free_slots.append(self.allocator, decoded.index) catch return false;
        return true;
    }

    pub fn removePointer(self: *Table, kind: Kind, pointer: usize) bool {
        for (self.slots.items, 0..) |slot, index| {
            if (slot.active and slot.kind == kind and slot.pointer == pointer) {
                return self.remove(kind, encode(kind, @intCast(index), slot.generation));
            }
        }
        return false;
    }

    fn encode(kind: Kind, index: u32, generation: u32) u64 {
        return (@as(u64, @intFromEnum(kind)) << 56) | (@as(u64, generation & 0x00ff_ffff) << 32) | index;
    }

    const Decoded = struct {
        kind: Kind,
        index: u32,
        generation: u32,
    };

    fn decode(handle: u64) ?Decoded {
        const kind_value: u8 = @intCast(handle >> 56);
        const kind: Kind = @enumFromInt(kind_value);
        return .{
            .kind = kind,
            .generation = @intCast((handle >> 32) & 0x00ff_ffff),
            .index = @intCast(handle & 0xffff_ffff),
        };
    }
};

test "handles reject stale generations" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const first = try table.put(.world, 0x1234);
    try std.testing.expectEqual(@as(usize, 0x1234), table.get(.world, first).?);
    try std.testing.expect(table.remove(.world, first));
    try std.testing.expect(table.get(.world, first) == null);

    const second = try table.put(.world, 0x5678);
    try std.testing.expect(second != first);
    try std.testing.expectEqual(@as(usize, 0x5678), table.get(.world, second).?);
}
