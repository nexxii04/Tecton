const std = @import("std");

pub const Kind = enum(u8) {
    subchunks,
    block_entities,
    entities,
};

pub const Key = struct {
    kind: Kind,
    dim: u8 = 0,
    x: i32 = 0,
    z: i32 = 0,
};

pub fn chunkKey(kind: Kind, dim_index: i32, x: i32, z: i32) Key {
    return .{ .kind = kind, .dim = @intCast(@as(u32, @bitCast(dim_index)) & 0xff), .x = x, .z = z };
}

pub const Put = struct { key: []u8, value: []u8 };

pub const Record = struct {
    puts: std.ArrayListUnmanaged(Put) = .empty,
    deletes: std.ArrayListUnmanaged([]u8) = .empty,
    bytes: usize = 0,

    pub fn addPut(self: *Record, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try self.puts.append(allocator, .{ .key = owned_key, .value = owned_value });
        self.bytes += owned_key.len + owned_value.len;
    }

    pub fn addDelete(self: *Record, allocator: std.mem.Allocator, key: []const u8) !void {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        try self.deletes.append(allocator, owned_key);
        self.bytes += owned_key.len;
    }

    pub fn isEmpty(self: *const Record) bool {
        return self.puts.items.len == 0 and self.deletes.items.len == 0;
    }

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        for (self.puts.items) |put| {
            allocator.free(put.key);
            allocator.free(put.value);
        }
        for (self.deletes.items) |key| allocator.free(key);
        self.puts.deinit(allocator);
        self.deletes.deinit(allocator);
        self.* = .{};
    }
};
