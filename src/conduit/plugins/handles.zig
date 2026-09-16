const std = @import("std");
const api = @import("api.zig");

pub const HandleRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    free_indices: std.ArrayList(u32),

    const Entry = struct {
        ptr: ?*anyopaque = null,
        generation: u16 = 1,
        kind: api.HandleKind = .invalid,
    };

    pub fn init(allocator: std.mem.Allocator) HandleRegistry {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .free_indices = .empty,
        };
    }

    pub fn deinit(self: *HandleRegistry) void {
        self.entries.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
    }

    pub fn insert(self: *HandleRegistry, kind: api.HandleKind, ptr: *anyopaque) !api.Handle {
        const index = if (self.free_indices.pop()) |free| free else blk: {
            const value: u32 = @intCast(self.entries.items.len);
            try self.entries.append(self.allocator, .{});
            break :blk value;
        };
        var slot = &self.entries.items[index];
        if (slot.generation == 0) slot.generation = 1;
        slot.* = .{ .ptr = ptr, .generation = slot.generation, .kind = kind };
        return .{ .index = index, .generation = slot.generation, .kind = kind };
    }

    pub fn remove(self: *HandleRegistry, handle: api.Handle) void {
        const slot = self.entry(handle) orelse return;
        slot.ptr = null;
        slot.kind = .invalid;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        self.free_indices.append(self.allocator, handle.index) catch {};
    }

    pub fn findPtr(self: *const HandleRegistry, kind: api.HandleKind, ptr: *anyopaque) ?api.Handle {
        for (self.entries.items, 0..) |slot, index| {
            if (slot.kind == kind and slot.ptr == ptr) {
                return .{ .index = @intCast(index), .generation = slot.generation, .kind = kind };
            }
        }
        return null;
    }

    pub fn resolve(self: *const HandleRegistry, handle: api.Handle, kind: api.HandleKind) ?*anyopaque {
        if (handle.kind != kind) return null;
        const slot = self.entry(handle) orelse return null;
        if (slot.kind != kind or slot.generation != handle.generation) return null;
        return slot.ptr;
    }

    fn entry(self: *const HandleRegistry, handle: api.Handle) ?*Entry {
        if (handle.kind == .invalid or handle.index >= self.entries.items.len) return null;
        return @constCast(&self.entries.items[handle.index]);
    }
};

test "handle generations reject stale references" {
    var registry = HandleRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var first: u8 = 1;
    const handle = try registry.insert(.player, @ptrCast(&first));
    try std.testing.expect(registry.resolve(handle, .player) != null);
    registry.remove(handle);
    try std.testing.expect(registry.resolve(handle, .player) == null);

    var second: u8 = 2;
    const replacement = try registry.insert(.player, @ptrCast(&second));
    try std.testing.expect(replacement.generation != handle.generation);
    try std.testing.expect(registry.resolve(replacement, .player) != null);
}
