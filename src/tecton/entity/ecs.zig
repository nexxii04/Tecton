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
        const drop_queue = allocator.alloc(DropRequest, capacity) catch |err| {
            item_drops.deinit();
            metadata.deinit();
            health.deinit();
            physics.deinit();
            transforms.deinit();
            allocator.free(free_indices);
            allocator.free(alive);
            allocator.free(generations);
            return err;
        };

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
