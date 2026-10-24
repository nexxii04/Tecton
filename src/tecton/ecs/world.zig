const std = @import("std");
const entity_id = @import("entity_id.zig");
const store_mod = @import("store.zig");

pub const EntityId = entity_id.EntityId;
pub const Kind = entity_id.Kind;
pub const DenseStore = store_mod.DenseStore;

pub const WorldError = error{ CapacityExceeded, InvalidEntity };

fn StoreTuple(comptime components: anytype) type {
    var types: [components.len]type = undefined;
    for (components, 0..) |C, i| types[i] = DenseStore(C);
    return std.meta.Tuple(&types);
}

pub fn World(comptime components: anytype) type {
    return struct {
        const Self = @This();

        pub const ComponentTypes = components;

        allocator: std.mem.Allocator,
        generations: []u16,
        alive_words: []u64,
        free_indices: []u32,
        free_len: usize,
        count: usize = 0,
        epoch: u64 = 0,
        stores: StoreTuple(components),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity > std.math.maxInt(i32)) return error.CapacityExceeded;
            const generations = try allocator.alloc(u16, capacity);
            errdefer allocator.free(generations);
            const alive_words = try allocator.alloc(u64, (capacity + 63) / 64);
            errdefer allocator.free(alive_words);
            const free_indices = try allocator.alloc(u32, capacity);
            errdefer allocator.free(free_indices);
            @memset(generations, 1);
            @memset(alive_words, 0);
            for (free_indices, 0..) |*slot, i| slot.* = @intCast(i);

            var stores: StoreTuple(components) = undefined;
            var initialized: usize = 0;
            errdefer {
                inline for (0..components.len) |i| {
                    if (i < initialized) stores[i].deinit(allocator);
                }
            }
            inline for (0..components.len) |i| {
                stores[i] = try DenseStore(components[i]).init(allocator, capacity);
                initialized += 1;
            }

            return .{
                .allocator = allocator,
                .generations = generations,
                .alive_words = alive_words,
                .free_indices = free_indices,
                .free_len = capacity,
                .stores = stores,
            };
        }

        pub fn reserve(self: *Self, capacity: usize) !void {
            const previous = self.generations.len;
            if (capacity <= previous) return;
            var replacement = try Self.init(self.allocator, capacity);
            errdefer replacement.deinit();
            @memcpy(replacement.generations[0..previous], self.generations);
            @memcpy(replacement.alive_words[0..self.alive_words.len], self.alive_words);
            @memcpy(replacement.free_indices[0..self.free_len], self.free_indices[0..self.free_len]);
            inline for (0..components.len) |i| {
                const source = &self.stores[i];
                const target = &replacement.stores[i];
                @memcpy(target.sparse[0..source.sparse.len], source.sparse);
                @memcpy(target.dense_ids[0..source.len], source.dense_ids[0..source.len]);
                @memcpy(target.dense_values[0..source.len], source.dense_values[0..source.len]);
                target.len = source.len;
            }
            for (previous..capacity, self.free_len..) |index, free_index| {
                replacement.free_indices[free_index] = @intCast(index);
            }
            replacement.free_len = self.free_len + capacity - previous;
            replacement.count = self.count;
            replacement.epoch = self.epoch + 1;
            self.deinit();
            self.* = replacement;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.generations);
            self.allocator.free(self.alive_words);
            self.allocator.free(self.free_indices);
            inline for (0..components.len) |i| {
                self.stores[i].deinit(self.allocator);
            }
        }

        pub fn create(self: *Self, kind: Kind) WorldError!EntityId {
            if (self.free_len == 0) return error.CapacityExceeded;
            self.free_len -= 1;
            const index = self.free_indices[self.free_len];
            const word = index >> 6;
            self.alive_words[word] |= @as(u64, 1) << @intCast(index & 63);
            self.count += 1;
            return .{ .index = index, .generation = self.generations[index], .kind = kind };
        }

        pub fn destroy(self: *Self, id: EntityId) bool {
            if (!self.isAlive(id)) return false;
            inline for (0..components.len) |i| {
                self.stores[i].remove(id);
            }
            self.alive_words[id.index >> 6] &= ~(@as(u64, 1) << @intCast(id.index & 63));
            self.generations[id.index] +%= 1;
            if (self.generations[id.index] == 0) self.generations[id.index] = 1;
            self.free_indices[self.free_len] = id.index;
            self.free_len += 1;
            self.count -= 1;
            return true;
        }

        pub fn isAlive(self: *const Self, id: EntityId) bool {
            if (id.index >= self.generations.len) return false;
            const word = self.alive_words[id.index >> 6];
            const alive = (word & (@as(u64, 1) << @intCast(id.index & 63))) != 0;
            return alive and self.generations[id.index] == id.generation;
        }

        pub fn store(self: *Self, comptime C: type) *DenseStore(C) {
            inline for (components, 0..) |T, i| {
                if (T == C) return &self.stores[i];
            }
            @compileError("unregistered component: " ++ @typeName(C));
        }

        pub fn get(self: *Self, id: EntityId, comptime C: type) ?*C {
            return self.store(C).get(id);
        }

        pub fn add(self: *Self, id: EntityId, value: anytype) !void {
            return self.store(@TypeOf(value)).add(id, value);
        }

        pub fn remove(self: *Self, id: EntityId, comptime C: type) void {
            self.store(C).remove(id);
        }
    };
}

const Position = struct { x: f32, y: f32, z: f32 };
const Speed = struct { velocity: f32 };

const TestComponents = .{ Position, Speed };

const TestWorld = World(TestComponents);

test "create recycles indices with fresh generations" {
    var world = try TestWorld.init(std.testing.allocator, 2);
    defer world.deinit();

    const first = try world.create(.mob);
    try std.testing.expect(world.isAlive(first));
    try std.testing.expectEqual(@as(usize, 1), world.count);
    try std.testing.expect(world.destroy(first));
    try std.testing.expectEqual(@as(usize, 0), world.count);

    const second = try world.create(.mob);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(!world.isAlive(first));
    try std.testing.expect(world.isAlive(second));
}

test "destroy removes every registered component" {
    var world = try TestWorld.init(std.testing.allocator, 4);
    defer world.deinit();

    const id = try world.create(.item);
    try world.add(id, Position{ .x = 1, .y = 2, .z = 3 });
    try world.add(id, Speed{ .velocity = 0.5 });
    try std.testing.expect(world.get(id, Position) != null);
    try std.testing.expect(world.get(id, Speed) != null);

    try std.testing.expect(world.destroy(id));
    try std.testing.expect(world.get(id, Position) == null);
    try std.testing.expect(world.get(id, Speed) == null);
}

test "capacity exhaustion surfaces as an error" {
    var world = try TestWorld.init(std.testing.allocator, 1);
    defer world.deinit();

    _ = try world.create(.item);
    try std.testing.expectError(error.CapacityExceeded, world.create(.item));
}

test "world reserve preserves entities components and free list" {
    var world = try TestWorld.init(std.testing.allocator, 2);
    defer world.deinit();

    const stale = try world.create(.mob);
    try std.testing.expect(world.destroy(stale));
    const held = try world.create(.item);
    try world.add(held, Position{ .x = 3, .y = 4, .z = 5 });
    try world.add(held, Speed{ .velocity = 0.25 });

    try world.reserve(8);
    try std.testing.expect(!world.isAlive(stale));
    try std.testing.expect(world.isAlive(held));
    try std.testing.expectEqual(@as(f32, 3), world.get(held, Position).?.x);
    try std.testing.expectEqual(@as(f32, 0.25), world.get(held, Speed).?.velocity);
    try std.testing.expectEqual(@as(u64, 1), world.epoch);

    for (0..7) |_| {
        const id = try world.create(.mob);
        try std.testing.expect(id.index != held.index);
    }
    try std.testing.expectError(error.CapacityExceeded, world.create(.mob));
}

test "world operations never allocate after reservation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var world = try TestWorld.init(failing.allocator(), 64);
    defer world.deinit();
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;

    var ids: [64]EntityId = undefined;
    for (&ids) |*slot| {
        const id = try world.create(.item);
        try world.add(id, Position{ .x = 1, .y = 2, .z = 3 });
        try world.add(id, Speed{ .velocity = 0.5 });
        slot.* = id;
    }
    try std.testing.expectError(error.CapacityExceeded, world.create(.item));
    for (0..100) |i| {
        try std.testing.expect(world.destroy(ids[i % ids.len]));
        const id = try world.create(.item);
        try world.add(id, Speed{ .velocity = 0.5 });
        ids[i % ids.len] = id;
    }
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}

fn exerciseReserve(allocator: std.mem.Allocator) !void {
    var world = try TestWorld.init(allocator, 2);
    defer world.deinit();
    const id = try world.create(.item);
    try world.add(id, Position{ .x = 9, .y = 9, .z = 9 });
    try world.reserve(8);
    try std.testing.expectEqual(@as(f32, 9), world.get(id, Position).?.x);
}

test "world reserve unwinds allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseReserve, .{});
}
