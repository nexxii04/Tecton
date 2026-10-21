const std = @import("std");
const Protocol = @import("protocol");

pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u16,
    kind: u8 = 0,
    reserved: u8 = 0,
};

pub const Transform = struct {
    position: Protocol.Vector3f,
    rotation: Protocol.Vector2f,
    velocity: Protocol.Vector3f,
    dirty: bool = true,
};

pub const Physics = struct {
    enabled: bool = false,
    gravity: f32 = -0.08,
    drag: f32 = 0.98,
    width: f32 = 0.6,
    height: f32 = 1.8,
    on_ground: bool = false,
};

pub const Health = struct {
    current: f32,
    maximum: f32,
    dirty: bool = true,
};

pub const Metadata = struct {
    flags: u64 = 0,
    scale: f32 = 1.0,
    dirty: bool = true,
};

pub const ItemDrop = struct {
    identifier: []const u8,
    count: u16,
    pickup_delay: u32 = 0,
};

pub const LegacyEntity = struct {
    entity_id: EntityId,
    runtime_id: i64,
};

pub const DropRequest = struct {
    source: EntityId,
    position: Protocol.Vector3f,
    item: ItemDrop,
};

pub fn DenseStore(comptime T: type) type {
    return @import("dense_store.zig").DenseStore(EntityId, T);
}

pub const MovementSystem = struct {
    pub fn run(world: *EcsWorld) void {
        var index: usize = 0;
        while (index < world.physics.len) : (index += 1) {
            const id = world.physics.dense_ids[index];
            const physics = &world.physics.dense_values[index];
            if (!physics.enabled) continue;
            const transform = world.transforms.get(id) orelse continue;
            if (!physics.on_ground) transform.velocity.y += physics.gravity;
            transform.velocity.x *= physics.drag;
            transform.velocity.y *= physics.drag;
            transform.velocity.z *= physics.drag;
            transform.position = transform.position.add(transform.velocity);
            transform.dirty = true;
        }
    }
};

pub const SyncSystem = struct {
    pub const Callback = *const fn (*anyopaque, EntityId, *const Transform, *const Metadata) void;

    pub fn run(world: *EcsWorld) void {
        const callback = world.sync_callback orelse return;
        const context = world.sync_context orelse return;
        var index: usize = 0;
        while (index < world.transforms.len) : (index += 1) {
            const id = world.transforms.dense_ids[index];
            const transform = &world.transforms.dense_values[index];
            if (!transform.dirty) continue;
            const metadata = world.metadata.get(id) orelse &world.empty_metadata;
            callback(context, id, transform, metadata);
            transform.dirty = false;
            if (metadata != &world.empty_metadata) metadata.dirty = false;
        }
    }
};

pub const DropSystem = struct {
    pub const Callback = *const fn (*anyopaque, EntityId, Protocol.Vector3f, ItemDrop) void;

    pub fn run(world: *EcsWorld) void {
        const callback = world.drop_callback orelse {
            world.drop_len = 0;
            return;
        };
        const context = world.drop_context orelse return;
        var index: usize = 0;
        while (index < world.drop_len) : (index += 1) {
            const request = world.drop_queue[index];
            callback(context, request.source, request.position, request.item);
        }
        world.drop_len = 0;
    }
};

pub const EcsWorld = struct {
    allocator: std.mem.Allocator,
    generations: []u16,
    alive: []bool,
    free_indices: []u32,
    free_len: usize,
    transforms: DenseStore(Transform),
    physics: DenseStore(Physics),
    health: DenseStore(Health),
    metadata: DenseStore(Metadata),
    item_drops: DenseStore(ItemDrop),
    drop_queue: []DropRequest,
    drop_len: usize = 0,
    drop_callback: ?DropSystem.Callback = null,
    drop_context: ?*anyopaque = null,
    sync_callback: ?SyncSystem.Callback = null,
    sync_context: ?*anyopaque = null,
    empty_metadata: Metadata = .{},

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EcsWorld {
        if (capacity > std.math.maxInt(i32)) return error.CapacityExceeded;
        const generations = try allocator.alloc(u16, capacity);
        errdefer allocator.free(generations);
        const alive = try allocator.alloc(bool, capacity);
        errdefer allocator.free(alive);
        const free_indices = try allocator.alloc(u32, capacity);
        errdefer allocator.free(free_indices);
        @memset(generations, 1);
        @memset(alive, false);
        for (free_indices, 0..) |*index, i| index.* = @intCast(i);

        var transforms = try DenseStore(Transform).init(allocator, capacity);
        errdefer transforms.deinit();
        var physics = try DenseStore(Physics).init(allocator, capacity);
        errdefer physics.deinit();
        var health = try DenseStore(Health).init(allocator, capacity);
        errdefer health.deinit();
        var metadata = try DenseStore(Metadata).init(allocator, capacity);
        errdefer metadata.deinit();
        var item_drops = try DenseStore(ItemDrop).init(allocator, capacity);
        errdefer item_drops.deinit();
        const drop_queue = try allocator.alloc(DropRequest, capacity);

        return .{
            .allocator = allocator,
            .generations = generations,
            .alive = alive,
            .free_indices = free_indices,
            .free_len = capacity,
            .transforms = transforms,
            .physics = physics,
            .health = health,
            .metadata = metadata,
            .item_drops = item_drops,
            .drop_queue = drop_queue,
        };
    }

    pub fn reserve(self: *EcsWorld, capacity: usize) !void {
        const previous_capacity = self.generations.len;
        if (capacity <= previous_capacity) return;
        var replacement = try EcsWorld.init(self.allocator, capacity);
        errdefer replacement.deinit();
        @memcpy(replacement.generations[0..previous_capacity], self.generations);
        @memcpy(replacement.alive[0..previous_capacity], self.alive);
        @memcpy(replacement.free_indices[0..self.free_len], self.free_indices[0..self.free_len]);
        for (previous_capacity..capacity, self.free_len..) |index, free_index| {
            replacement.free_indices[free_index] = @intCast(index);
        }
        replacement.free_len = self.free_len + capacity - previous_capacity;
        inline for (.{ "transforms", "physics", "health", "metadata", "item_drops" }) |field| {
            const source = &@field(self, field);
            const target = &@field(replacement, field);
            @memcpy(target.sparse[0..source.sparse.len], source.sparse);
            @memcpy(target.dense_ids[0..source.len], source.dense_ids[0..source.len]);
            @memcpy(target.dense_values[0..source.len], source.dense_values[0..source.len]);
            target.len = source.len;
        }
        @memcpy(replacement.drop_queue[0..self.drop_len], self.drop_queue[0..self.drop_len]);
        replacement.drop_len = self.drop_len;
        replacement.drop_callback = self.drop_callback;
        replacement.drop_context = self.drop_context;
        replacement.sync_callback = self.sync_callback;
        replacement.sync_context = self.sync_context;
        replacement.empty_metadata = self.empty_metadata;
        self.deinit();
        self.* = replacement;
    }

    pub fn deinit(self: *EcsWorld) void {
        self.allocator.free(self.generations);
        self.allocator.free(self.alive);
        self.allocator.free(self.free_indices);
        self.transforms.deinit();
        self.physics.deinit();
        self.health.deinit();
        self.metadata.deinit();
        self.item_drops.deinit();
        self.allocator.free(self.drop_queue);
    }

    pub fn create(self: *EcsWorld, kind: u8) !EntityId {
        if (self.free_len == 0) return error.CapacityExceeded;
        self.free_len -= 1;
        const index = self.free_indices[self.free_len];
        self.alive[index] = true;
        return .{ .index = index, .generation = self.generations[index], .kind = kind };
    }

    pub fn destroy(self: *EcsWorld, id: EntityId) bool {
        if (!self.isAlive(id)) return false;
        self.transforms.remove(id);
        self.physics.remove(id);
        self.health.remove(id);
        self.metadata.remove(id);
        self.item_drops.remove(id);
        self.alive[id.index] = false;
        self.generations[id.index] +%= 1;
        if (self.generations[id.index] == 0) self.generations[id.index] = 1;
        self.free_indices[self.free_len] = id.index;
        self.free_len += 1;
        return true;
    }

    pub fn isAlive(self: *const EcsWorld, id: EntityId) bool {
        return id.index < self.alive.len and self.alive[id.index] and self.generations[id.index] == id.generation;
    }

    pub fn registerLegacy(self: *EcsWorld, position: Protocol.Vector3f, rotation: Protocol.Vector2f, velocity: Protocol.Vector3f, flags: u64, scale: f32, kind: u8) !EntityId {
        const id = try self.create(kind);
        errdefer _ = self.destroy(id);
        try self.transforms.add(id, .{ .position = position, .rotation = rotation, .velocity = velocity });
        try self.metadata.add(id, .{ .flags = flags, .scale = scale });
        return id;
    }

    pub fn updateTransform(self: *EcsWorld, id: EntityId, position: Protocol.Vector3f, rotation: Protocol.Vector2f, velocity: Protocol.Vector3f) void {
        if (!self.isAlive(id)) return;
        if (self.transforms.get(id)) |transform| {
            transform.position = position;
            transform.rotation = rotation;
            transform.velocity = velocity;
            transform.dirty = true;
        }
    }

    pub fn attachItemDrop(self: *EcsWorld, id: EntityId, item: ItemDrop) !void {
        if (!self.isAlive(id)) return error.InvalidEntity;
        try self.item_drops.add(id, item);
    }

    pub fn queueDrop(self: *EcsWorld, request: DropRequest) bool {
        if (self.drop_len == self.drop_queue.len) return false;
        self.drop_queue[self.drop_len] = request;
        self.drop_len += 1;
        return true;
    }

    pub fn queueEntityDrop(self: *EcsWorld, id: EntityId, position: Protocol.Vector3f) bool {
        const item = self.item_drops.get(id) orelse return false;
        if (!self.queueDrop(.{ .source = id, .position = position, .item = item.* })) return false;
        self.item_drops.remove(id);
        return true;
    }

    pub fn setDropCallback(self: *EcsWorld, context: *anyopaque, callback: DropSystem.Callback) void {
        self.drop_context = context;
        self.drop_callback = callback;
    }

    pub fn setSyncCallback(self: *EcsWorld, context: *anyopaque, callback: SyncSystem.Callback) void {
        self.sync_context = context;
        self.sync_callback = callback;
    }

    pub fn tick(self: *EcsWorld) void {
        MovementSystem.run(self);
        SyncSystem.run(self);
        DropSystem.run(self);
    }

    test "reservation preserves entity generations components and pending drops" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseReserve, .{});
    }

    test "ecs operations and ticks never allocate after reservation" {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var world = try EcsWorld.init(failing.allocator(), 64);
        defer world.deinit();
        const allocations = failing.alloc_index;
        failing.fail_index = allocations;
        for (0..64) |_| {
            const id = try world.registerLegacy(.zero(), .zero(), .zero(), 0, 1, 1);
            try world.physics.add(id, .{ .enabled = true });
            try world.attachItemDrop(id, .{ .identifier = "minecraft:stone", .count = 1 });
            try std.testing.expect(world.queueEntityDrop(id, .zero()));
        }
        try std.testing.expectError(error.CapacityExceeded, world.create(1));
        for (0..100) |_| world.tick();
        try std.testing.expectEqual(allocations, failing.alloc_index);
        try std.testing.expect(!failing.has_induced_failure);
    }

    test "entity generations invalidate stale ids" {
        try @import("ecs_test.zig").Suite(EcsWorld).case_000();
    }

    test "dense stores swap remove without invalidating remaining ids" {
        try @import("ecs_test.zig").Suite(EcsWorld).case_001();
    }

    test "dense tick processes a thousand entities without growing storage" {
        try @import("ecs_test.zig").Suite(EcsWorld).case_002();
    }
};

fn exerciseReserve(allocator: std.mem.Allocator) !void {
    var world = try EcsWorld.init(allocator, 2);
    defer world.deinit();
    const stale = try world.create(1);
    try std.testing.expect(world.destroy(stale));
    const held = try world.registerLegacy(.{ .x = 3, .y = 4, .z = 5 }, .zero(), .zero(), 42, 1, 2);
    try world.attachItemDrop(held, .{ .identifier = "minecraft:stone", .count = 7 });
    try std.testing.expect(world.queueEntityDrop(held, .zero()));
    try world.reserve(8);
    try std.testing.expect(!world.isAlive(stale));
    try std.testing.expect(world.isAlive(held));
    try std.testing.expectEqual(@as(f32, 3), world.transforms.get(held).?.position.x);
    try std.testing.expectEqual(@as(u64, 42), world.metadata.get(held).?.flags);
    try std.testing.expectEqual(@as(usize, 1), world.drop_len);
    try std.testing.expectEqual(@as(u16, 7), world.drop_queue[0].item.count);
    for (0..7) |_| {
        const id = try world.create(3);
        try std.testing.expect(id.index != held.index);
    }
    try std.testing.expectError(error.CapacityExceeded, world.create(3));
}
