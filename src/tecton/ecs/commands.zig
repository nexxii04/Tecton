const std = @import("std");
const Protocol = @import("protocol");
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const DespawnCause = @import("../events/types.zig").DespawnCause;
const entity_id = @import("entity_id.zig");

const EntityId = entity_id.EntityId;

pub const DespawnCmd = struct {
    id: EntityId,
    cause: DespawnCause,
};

fn AddList(comptime C: type) type {
    return std.ArrayListUnmanaged(struct { id: EntityId, value: C });
}

fn AddTuple(comptime components: anytype) type {
    var types: [components.len]type = undefined;
    for (components, 0..) |C, i| types[i] = AddList(C);
    return std.meta.Tuple(&types);
}

fn RemoveTuple(comptime components: anytype) type {
    var types: [components.len]type = undefined;
    for (0..components.len) |i| types[i] = std.ArrayListUnmanaged(EntityId);
    return std.meta.Tuple(&types);
}

pub const DropRequest = struct {
    dimension: *Dimension,
    source_runtime: i64,
    killer_runtime: ?i64,
    position: Protocol.Vector3f,
    item: ItemStack,
    pickup_delay: u32,
};

pub const DropQueue = struct {
    requests: std.ArrayListUnmanaged(DropRequest) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !DropQueue {
        var queue = DropQueue{};
        try queue.requests.ensureTotalCapacity(allocator, capacity);
        return queue;
    }

    pub fn deinit(self: *DropQueue, allocator: std.mem.Allocator) void {
        for (self.requests.items) |*request| request.item.deinit();
        self.requests.deinit(allocator);
    }

    pub fn enqueue(self: *DropQueue, allocator: std.mem.Allocator, request: DropRequest) !void {
        try self.requests.append(allocator, request);
    }

    pub fn pending(self: *const DropQueue) []const DropRequest {
        return self.requests.items;
    }

    pub fn drain(self: *DropQueue) []DropRequest {
        return self.requests.items;
    }

    pub fn clearDelivered(self: *DropQueue, delivered: usize) void {
        for (self.requests.items[0..delivered]) |*request| request.item.deinit();
        self.requests.shrinkRetainingCapacity(self.requests.items.len - delivered);
    }

    pub fn clearRetainingCapacity(self: *DropQueue) void {
        for (self.requests.items) |*request| request.item.deinit();
        self.requests.clearRetainingCapacity();
    }
};

pub const FlushStats = struct {
    despawned: usize = 0,
    stale_despawns: usize = 0,
    failed_adds: usize = 0,
    enqueue_failures: usize = 0,
};

fn emptyAddTuple(comptime components: anytype) AddTuple(components) {
    var tuple: AddTuple(components) = undefined;
    inline for (0..components.len) |i| tuple[i] = .empty;
    return tuple;
}

fn emptyRemoveTuple(comptime components: anytype) RemoveTuple(components) {
    var tuple: RemoveTuple(components) = undefined;
    inline for (0..components.len) |i| tuple[i] = .empty;
    return tuple;
}

pub fn Commands(comptime components: anytype) type {
    return struct {
        const Self = @This();

        despawns: std.ArrayListUnmanaged(DespawnCmd) = .empty,
        adds: AddTuple(components) = emptyAddTuple(components),
        removes: RemoveTuple(components) = emptyRemoveTuple(components),
        stats: FlushStats = .{},

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            var self = Self{};
            errdefer self.deinit(allocator);
            try self.despawns.ensureTotalCapacity(allocator, capacity);
            inline for (0..components.len) |i| {
                try self.adds[i].ensureTotalCapacity(allocator, 16);
                try self.removes[i].ensureTotalCapacity(allocator, 16);
            }
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.despawns.deinit(allocator);
            inline for (0..components.len) |i| {
                self.adds[i].deinit(allocator);
                self.removes[i].deinit(allocator);
            }
        }

        pub fn despawn(self: *Self, allocator: std.mem.Allocator, id: EntityId, cause: DespawnCause) !void {
            self.despawns.append(allocator, .{ .id = id, .cause = cause }) catch {
                self.stats.enqueue_failures += 1;
                return error.OutOfMemory;
            };
        }

        pub fn addComponent(self: *Self, allocator: std.mem.Allocator, id: EntityId, value: anytype) !void {
            const C = @TypeOf(value);
            inline for (components, 0..) |T, i| {
                if (T == C) {
                    try self.adds[i].append(allocator, .{ .id = id, .value = value });
                    return;
                }
            }
            @compileError("unregistered component: " ++ @typeName(C));
        }

        pub fn removeComponent(self: *Self, allocator: std.mem.Allocator, id: EntityId, comptime C: type) !void {
            inline for (components, 0..) |T, i| {
                if (T == C) {
                    try self.removes[i].append(allocator, id);
                    return;
                }
            }
            @compileError("unregistered component: " ++ @typeName(C));
        }

        pub fn flush(self: *Self, world: anytype) void {
            self.stats = .{};
            inline for (0..components.len) |i| {
                for (self.adds[i].items) |entry| {
                    world.add(entry.id, entry.value) catch {
                        self.stats.failed_adds += 1;
                    };
                }
                self.adds[i].clearRetainingCapacity();
                for (self.removes[i].items) |id| {
                    world.remove(id, components[i]);
                }
                self.removes[i].clearRetainingCapacity();
            }
            for (self.despawns.items) |command| {
                if (world.destroy(command.id)) {
                    self.stats.despawned += 1;
                } else {
                    self.stats.stale_despawns += 1;
                }
            }
            self.despawns.clearRetainingCapacity();
        }

        pub fn pendingOperations(self: *const Self) usize {
            var total = self.despawns.items.len;
            inline for (0..components.len) |i| {
                total += self.adds[i].items.len + self.removes[i].items.len;
            }
            return total;
        }
    };
}

const world_mod = @import("world.zig");

const Health = struct { current: f32 };
const Shield = struct { points: u8 };
const CommandComponents = .{ Health, Shield };
const CommandWorld = world_mod.World(CommandComponents);
const CommandBuffer = Commands(CommandComponents);

test "flush applies deferred adds removes and despawns in order" {
    const allocator = std.testing.allocator;
    var world = try CommandWorld.init(allocator, 8);
    defer world.deinit();
    var commands = try CommandBuffer.init(allocator, 8);
    defer commands.deinit(allocator);

    const id = try world.create(.mob);
    try commands.addComponent(allocator, id, Health{ .current = 20 });
    try commands.addComponent(allocator, id, Shield{ .points = 3 });
    try std.testing.expect(world.get(id, Health) == null);

    commands.flush(&world);
    try std.testing.expectEqual(@as(f32, 20), world.get(id, Health).?.current);
    try std.testing.expectEqual(@as(u8, 3), world.get(id, Shield).?.points);
    try std.testing.expectEqual(@as(usize, 0), commands.pendingOperations());

    try commands.removeComponent(allocator, id, Shield);
    try commands.despawn(allocator, id, .expired);
    try commands.despawn(allocator, id, .expired);
    commands.flush(&world);
    try std.testing.expect(!world.isAlive(id));
    try std.testing.expect(world.get(id, Health) == null);
    try std.testing.expectEqual(@as(usize, 1), commands.stats.despawned);
    try std.testing.expectEqual(@as(usize, 1), commands.stats.stale_despawns);
}

test "flush ignores commands for stale entity ids" {
    const allocator = std.testing.allocator;
    var world = try CommandWorld.init(allocator, 8);
    defer world.deinit();
    var commands = try CommandBuffer.init(allocator, 8);
    defer commands.deinit(allocator);

    const stale = try world.create(.mob);
    try std.testing.expect(world.destroy(stale));
    const fresh = try world.create(.mob);

    try commands.addComponent(allocator, stale, Health{ .current = 5 });
    commands.flush(&world);
    try std.testing.expect(world.get(stale, Health) == null);
    try std.testing.expect(world.get(fresh, Health) == null);
    try std.testing.expectEqual(@as(usize, 1), commands.stats.failed_adds);
}

test "commands never allocate during flush after reservation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try CommandWorld.init(allocator, 8);
    defer world.deinit();
    var commands = try CommandBuffer.init(allocator, 8);
    defer commands.deinit(allocator);

    const id = try world.create(.mob);
    try commands.addComponent(allocator, id, Health{ .current = 1 });
    try commands.despawn(allocator, id, .expired);

    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    commands.flush(&world);
    try std.testing.expectEqual(allocations, failing.alloc_index);
}

test "drop queue owns stacks until delivered" {
    const allocator = std.testing.allocator;
    const ItemType = @import("../items/item_type.zig").ItemType;
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:ecs_drop_test"),
        5001,
        64,
        true,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    defer item_type.deinit();

    var queue = try DropQueue.init(allocator, 4);
    defer queue.deinit(allocator);

    const stack = ItemStack.init(allocator, item_type, .{ .stack_size = 2 });
    try queue.enqueue(allocator, .{
        .dimension = undefined,
        .source_runtime = 7,
        .killer_runtime = 9,
        .position = Protocol.Vector3f.init(1, 2, 3),
        .item = stack,
        .pickup_delay = 40,
    });

    const pending = queue.pending();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(@as(u16, 2), pending[0].item.stack_size);
    queue.clearDelivered(1);
    try std.testing.expectEqual(@as(usize, 0), queue.pending().len);
}
