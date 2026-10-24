const std = @import("std");
const entity_id = @import("entity_id.zig");
const EntityId = entity_id.EntityId;
const Kind = entity_id.Kind;

fn PtrTuple(comptime Cs: anytype) type {
    var types: [Cs.len]type = undefined;
    for (Cs, 0..) |C, i| types[i] = *C;
    return std.meta.Tuple(&types);
}

fn callExpanded(comptime callback: anytype, ctx: anytype, id: EntityId, ptrs: anytype) void {
    const n = ptrs.len;
    if (n == 1) return callback(ctx, id, ptrs[0]);
    if (n == 2) return callback(ctx, id, ptrs[0], ptrs[1]);
    if (n == 3) return callback(ctx, id, ptrs[0], ptrs[1], ptrs[2]);
    if (n == 4) return callback(ctx, id, ptrs[0], ptrs[1], ptrs[2], ptrs[3]);
    if (n == 5) return callback(ctx, id, ptrs[0], ptrs[1], ptrs[2], ptrs[3], ptrs[4]);
    @compileError("queries support at most five components");
}

fn smallestDriver(world: anytype, comptime Cs: anytype) usize {
    var min_len: usize = std.math.maxInt(usize);
    var driver_index: usize = 0;
    inline for (Cs, 0..) |C, i| {
        const length = world.store(C).len;
        if (length < min_len) {
            min_len = length;
            driver_index = i;
        }
    }
    return driver_index;
}

fn iterateDriver(
    world: anytype,
    comptime Driver: type,
    comptime Cs: anytype,
    comptime kind: ?Kind,
    ctx: anytype,
    comptime callback: anytype,
) void {
    const driver = world.store(Driver);
    var i: usize = 0;
    while (i < driver.len) : (i += 1) {
        const id = driver.dense_ids[i];
        if (comptime kind) |k| {
            if (id.kind != k) continue;
        }
        var present = true;
        inline for (Cs) |C| {
            if (C != Driver) {
                if (!world.store(C).contains(id)) present = false;
            }
        }
        if (!present) continue;

        var ptrs: PtrTuple(Cs) = undefined;
        inline for (Cs, 0..) |C, j| {
            if (C == Driver) {
                ptrs[j] = &driver.dense_values[i];
            } else {
                ptrs[j] = world.store(C).get(id).?;
            }
        }
        callExpanded(callback, ctx, id, ptrs);
    }
}

fn run(
    world: anytype,
    comptime Cs: anytype,
    comptime kind: ?Kind,
    ctx: anytype,
    comptime callback: anytype,
) void {
    comptime if (Cs.len == 0) @compileError("queries need at least one component");
    const driver_index = smallestDriver(world, Cs);
    inline for (Cs, 0..) |C, i| {
        if (i == driver_index) {
            iterateDriver(world, C, Cs, kind, ctx, callback);
        }
    }
}

pub fn each(
    world: anytype,
    comptime Cs: anytype,
    ctx: anytype,
    comptime callback: anytype,
) void {
    run(world, Cs, null, ctx, callback);
}

pub fn eachKind(
    world: anytype,
    comptime kind: Kind,
    comptime Cs: anytype,
    ctx: anytype,
    comptime callback: anytype,
) void {
    run(world, Cs, kind, ctx, callback);
}

pub fn countMatching(world: anytype, comptime Cs: anytype) usize {
    var total: usize = 0;
    const driver_index = smallestDriver(world, Cs);
    inline for (Cs, 0..) |C, i| {
        if (i == driver_index) {
            const driver = world.store(C);
            var j: usize = 0;
            while (j < driver.len) : (j += 1) {
                const id = driver.dense_ids[j];
                var present = true;
                inline for (Cs) |Other| {
                    if (Other != C) {
                        if (!world.store(Other).contains(id)) present = false;
                    }
                }
                if (present) total += 1;
            }
        }
    }
    return total;
}

pub fn first(world: anytype, comptime Cs: anytype) ?EntityId {
    const driver_index = smallestDriver(world, Cs);
    var result: ?EntityId = null;
    inline for (Cs, 0..) |C, i| {
        if (i == driver_index) {
            const driver = world.store(C);
            var j: usize = 0;
            while (j < driver.len) : (j += 1) {
                const id = driver.dense_ids[j];
                var present = true;
                inline for (Cs) |Other| {
                    if (Other != C) {
                        if (!world.store(Other).contains(id)) present = false;
                    }
                }
                if (present) {
                    result = id;
                    break;
                }
            }
        }
    }
    return result;
}

const world_mod = @import("world.zig");

const Tag = struct { value: u32 = 0 };
const Marker = struct { active: bool = false };
const QueryTestWorld = world_mod.World(.{ Tag, Marker });

test "each visits only entities holding every queried component" {
    const allocator = std.testing.allocator;
    var world = try QueryTestWorld.init(allocator, 16);
    defer world.deinit();

    var expected: u32 = 0;
    for (0..10) |i| {
        const id = try world.create(if (i % 2 == 0) .item else .mob);
        try world.add(id, Tag{ .value = @intCast(i) });
        if (i % 2 == 0) {
            try world.add(id, Marker{ .active = true });
            expected += @intCast(i);
        }
    }

    var total_sum: u32 = 0;
    each(&world, .{ Tag, Marker }, &total_sum, struct {
        fn call(sum: *u32, _: EntityId, tag: *Tag, _: *Marker) void {
            sum.* += tag.value;
        }
    }.call);
    try std.testing.expectEqual(expected, total_sum);
    try std.testing.expectEqual(@as(usize, 5), countMatching(&world, .{ Tag, Marker }));
    try std.testing.expect(first(&world, .{ Tag, Marker }) != null);
}

test "eachKind filters by entity kind" {
    const allocator = std.testing.allocator;
    var world = try QueryTestWorld.init(allocator, 16);
    defer world.deinit();

    for (0..6) |i| {
        const id = try world.create(if (i < 3) .mob else .item);
        try world.add(id, Tag{ .value = @intCast(i) });
    }

    var mob_tags: usize = 0;
    eachKind(&world, .mob, .{ Tag }, &mob_tags, struct {
        fn call(count: *usize, _: EntityId, _: *Tag) void {
            count.* += 1;
        }
    }.call);
    try std.testing.expectEqual(@as(usize, 3), mob_tags);
}

test "each supports mutation through borrowed pointers" {
    const allocator = std.testing.allocator;
    var world = try QueryTestWorld.init(allocator, 8);
    defer world.deinit();

    const id = try world.create(.item);
    try world.add(id, Tag{ .value = 1 });
    try world.add(id, Marker{ .active = false });

    each(&world, .{ Tag, Marker }, {}, struct {
        fn call(_: void, _: EntityId, tag: *Tag, marker: *Marker) void {
            tag.value = 7;
            marker.active = true;
        }
    }.call);

    try std.testing.expectEqual(@as(u32, 7), world.get(id, Tag).?.value);
    try std.testing.expect(world.get(id, Marker).?.active);
}

test "queries drive from the smallest store" {
    const allocator = std.testing.allocator;
    var world = try QueryTestWorld.init(allocator, 128);
    defer world.deinit();

    for (0..100) |_| {
        const id = try world.create(.mob);
        try world.add(id, Tag{});
    }
    const tagged = try world.create(.item);
    try world.add(tagged, Tag{});
    try world.add(tagged, Marker{});

    try std.testing.expectEqual(@as(usize, 1), countMatching(&world, .{ Tag, Marker }));
    try std.testing.expectEqual(tagged, first(&world, .{ Marker }).?);
}
