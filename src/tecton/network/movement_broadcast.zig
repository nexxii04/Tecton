const std = @import("std");
const testing = std.testing;

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

pub const MAX_BATCH_BYTES: usize = 936;

pub const FRAMESET_BYTES: usize = 1000;

pub fn markRef(stream: *BinaryStream, emitter_rid: i64, before: usize) DeltaRef {
    const after = stream.getBuffer().len;
    return .{ .emitter_rid = emitter_rid, .offset = before, .len = after - before };
}

pub const DeltaRef = struct {
    emitter_rid: i64,
    offset: usize,
    len: usize,

    pub fn slice(self: DeltaRef, payload: []const u8) []const u8 {
        return payload[self.offset..][0..self.len];
    }
};

pub const REGION_BLOCKS: i32 = 32;

const REGION_SHIFT: u5 = 5;

pub fn regionCoord(block: f32) i32 {
    return @as(i32, @intFromFloat(@floor(block))) >> REGION_SHIFT;
}

pub fn regionOf(dim: usize, block_x: f32, block_z: f32) Region {
    return .{ .dim = dim, .x = regionCoord(block_x), .z = regionCoord(block_z) };
}

pub fn regionRadius(view_distance: i32) i32 {
    if (view_distance <= 0) return 1;
    return @divFloor(view_distance + 1, 2) + 1;
}

pub const BAND_INTERVALS = [_]u8{ 1, 2, 4, 8 };

pub const BAND_DISTANCES = [_]f32{ 16.0, 32.0, 48.0 };

pub const BAND_REFRESH_TICKS: u64 = 10;

pub fn bandForDistanceSq(distance_sq: f32) u8 {
    inline for (BAND_DISTANCES, 0..) |limit, index| {
        if (distance_sq <= limit * limit) return @intCast(index + 1);
    }
    return BAND_INTERVALS.len;
}

pub fn due(band: u8, tick: u64) bool {
    if (band <= 1) return true;
    return tick % @as(u64, band) == 0;
}

pub const Emission = struct { reset: bool, send: bool };

pub fn emission(previous: ?u8, band: u8, tick: u64, forced: bool) Emission {
    if (previous == null or previous.? != band) return .{ .reset = true, .send = true };
    if (forced) return .{ .reset = false, .send = true };
    return .{ .reset = false, .send = due(band, tick) };
}

pub const ViewerPoint = struct {
    runtime_id: i64,
    dimension: usize,
    x: f32,
    z: f32,
};

pub const NearestViewer = struct { band: u8, distance: f32 };

pub fn nearestViewerBand(
    runtime_id: i64,
    dimension: usize,
    x: f32,
    z: f32,
    viewers: []const ViewerPoint,
) ?NearestViewer {
    var best_sq: f32 = std.math.floatMax(f32);
    var found = false;
    for (viewers) |viewer| {
        if (viewer.runtime_id == runtime_id) continue;
        if (viewer.dimension != dimension) continue;
        const dx = viewer.x - x;
        const dz = viewer.z - z;
        const distance_sq = dx * dx + dz * dz;
        if (!found or distance_sq < best_sq) {
            best_sq = distance_sq;
            found = true;
        }
    }
    if (!found) return null;
    return .{ .band = bandForDistanceSq(best_sq), .distance = @sqrt(best_sq) };
}

pub const Region = struct { dim: usize, x: i32, z: i32 };

pub const Slot = struct { region: Region, ref: DeltaRef };

pub const Bucket = struct { dim: usize, x: i32, z: i32, start: u32, end: u32 };

pub const Cursor = struct { bucket: usize = 0, offset: u32 = 0 };

pub const Index = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    buckets: std.ArrayListUnmanaged(Bucket) = .empty,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.buckets.deinit(allocator);
    }

    pub fn reset(self: *Index) void {
        self.slots.clearRetainingCapacity();
        self.buckets.clearRetainingCapacity();
    }

    pub fn add(self: *Index, allocator: std.mem.Allocator, region: Region, ref: DeltaRef) !void {
        try self.slots.append(allocator, .{ .region = region, .ref = ref });
    }

    pub fn finish(self: *Index, allocator: std.mem.Allocator) !void {
        std.mem.sort(Slot, self.slots.items, {}, slotLessThan);
        self.buckets.clearRetainingCapacity();
        for (self.slots.items, 0..) |slot, index| {
            if (self.buckets.items.len > 0) {
                const previous = &self.buckets.items[self.buckets.items.len - 1];
                if (previous.dim == slot.region.dim and
                    previous.x == slot.region.x and
                    previous.z == slot.region.z)
                {
                    previous.end = @intCast(index + 1);
                    continue;
                }
            }
            try self.buckets.append(allocator, .{
                .dim = slot.region.dim,
                .x = slot.region.x,
                .z = slot.region.z,
                .start = @intCast(index),
                .end = @intCast(index + 1),
            });
        }
    }

    pub fn collect(
        self: *const Index,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u32),
        dim: usize,
        block_x: f32,
        block_z: f32,
        radius: i32,
    ) !void {
        const cx = regionCoord(block_x);
        const cz = regionCoord(block_z);
        const x0 = cx - radius;
        const x1 = cx + radius;
        const z1 = cz + radius;
        const low = lowerBoundDim(self.buckets.items, dim);
        const high = upperBoundDim(self.buckets.items, dim);

        var index = low;
        var z = cz - radius;
        while (z <= z1) : (z += 1) {
            while (index < high and self.buckets.items[index].z < z) index += 1;
            if (index == high or self.buckets.items[index].z != z) continue;
            while (index < high and self.buckets.items[index].x < x0) index += 1;
            while (index < high and
                self.buckets.items[index].z == z and
                self.buckets.items[index].x <= x1) : (index += 1)
            {
                try out.append(allocator, @intCast(index));
            }
        }
    }
};

pub fn fillBatch(
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    payload: []const u8,
    slots: []const Slot,
    buckets: []const Bucket,
    candidates: []const u32,
    cursor: Cursor,
    viewer_rid: i64,
    visible: anytype,
    max_bytes: usize,
) Cursor {
    var bytes: usize = 0;
    var bucket_index = cursor.bucket;
    var offset = cursor.offset;

    while (bucket_index < candidates.len) : (bucket_index += 1) {
        const bucket = buckets[candidates[bucket_index]];
        while (bucket.start + offset < bucket.end) : (offset += 1) {
            const at: usize = bucket.start + offset;
            const ref = slots[at].ref;

            if (ref.emitter_rid == viewer_rid) continue;
            if (!visible.contains(ref.emitter_rid)) continue;

            if (out.items.len > 0 and bytes + ref.len > max_bytes) {
                return .{ .bucket = bucket_index, .offset = offset };
            }

            out.append(allocator, ref.slice(payload)) catch return .{ .bucket = candidates.len };
            bytes += ref.len;
        }
        offset = 0;
    }

    return .{ .bucket = candidates.len };
}

fn slotLessThan(_: void, a: Slot, b: Slot) bool {
    if (a.region.dim != b.region.dim) return a.region.dim < b.region.dim;
    if (a.region.z != b.region.z) return a.region.z < b.region.z;
    return a.region.x < b.region.x;
}

fn lowerBoundDim(buckets: []const Bucket, dim: usize) usize {
    var low: usize = 0;
    var high: usize = buckets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (buckets[mid].dim < dim) low = mid + 1 else high = mid;
    }
    return low;
}

fn upperBoundDim(buckets: []const Bucket, dim: usize) usize {
    var low: usize = 0;
    var high: usize = buckets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (buckets[mid].dim <= dim) low = mid + 1 else high = mid;
    }
    return low;
}

fn fakePayload(bytes: []const u8) []const u8 {
    return bytes;
}

fn refAt(emitter_rid: i64, offset: usize, len: usize) DeltaRef {
    return .{ .emitter_rid = emitter_rid, .offset = offset, .len = len };
}

test "the distance bands step at 16, 32 and 48 blocks" {
    try testing.expectEqual(BAND_DISTANCES.len + 1, BAND_INTERVALS.len);

    try testing.expectEqual(@as(u8, 1), bandForDistanceSq(0));
    try testing.expectEqual(@as(u8, 1), bandForDistanceSq(16.0 * 16.0));
    try testing.expectEqual(@as(u8, 2), bandForDistanceSq(16.001 * 16.001));
    try testing.expectEqual(@as(u8, 2), bandForDistanceSq(32.0 * 32.0));
    try testing.expectEqual(@as(u8, 3), bandForDistanceSq(32.001 * 32.001));
    try testing.expectEqual(@as(u8, 4), bandForDistanceSq(48.001 * 48.001));
    try testing.expectEqual(@as(u8, 4), bandForDistanceSq(std.math.floatMax(f32)));
}

test "every band is produced on its own stride" {
    try testing.expect(due(1, 7));
    try testing.expect(due(2, 8));
    try testing.expect(!due(2, 7));
    try testing.expect(due(4, 8));
    try testing.expect(!due(4, 6));
    try testing.expect(due(8, 80));
    try testing.expect(!due(8, 87));
}

test "a band change forces a full state and a teleport is never deferred" {
    const skipped = emission(2, 2, 9, false);
    try testing.expect(!skipped.reset);
    try testing.expect(!skipped.send);

    const on_stride = emission(4, 4, 8, false);
    try testing.expect(!on_stride.reset);
    try testing.expect(on_stride.send);

    const closer = emission(4, 2, 9, false);
    try testing.expect(closer.reset);
    try testing.expect(closer.send);

    const first = emission(null, 4, 9, false);
    try testing.expect(first.reset);
    try testing.expect(first.send);

    const teleport = emission(8, 8, 9, true);
    try testing.expect(!teleport.reset);
    try testing.expect(teleport.send);
}

test "the band comes from the nearest viewer in the same dimension" {
    const viewers = [_]ViewerPoint{
        .{ .runtime_id = 1, .dimension = 7, .x = 0, .z = 0 },
        .{ .runtime_id = 2, .dimension = 7, .x = 10, .z = 0 },
        .{ .runtime_id = 3, .dimension = 7, .x = 100, .z = 0 },
        .{ .runtime_id = 4, .dimension = 8, .x = 0, .z = 0 },
    };

    const close = nearestViewerBand(1, 7, 0, 0, &viewers) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 1), close.band);
    try testing.expectApproxEqAbs(@as(f32, 10), close.distance, 0.001);

    const middle = nearestViewerBand(1, 7, 40, 0, &viewers) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 2), middle.band);
    try testing.expectApproxEqAbs(@as(f32, 30), middle.distance, 0.001);

    const far = [_]ViewerPoint{
        .{ .runtime_id = 2, .dimension = 7, .x = 0, .z = 90 },
    };
    const far_band = nearestViewerBand(1, 7, 0, 0, &far) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 4), far_band.band);
    try testing.expectApproxEqAbs(@as(f32, 90), far_band.distance, 0.001);

    const alone = [_]ViewerPoint{
        .{ .runtime_id = 3, .dimension = 8, .x = 0, .z = 0 },
    };
    try testing.expect(nearestViewerBand(1, 7, 0, 0, &alone) == null);
    try testing.expect(nearestViewerBand(1, 7, 0, 0, viewers[0..1]) == null);
}

test "a skipped tick is not lost: the next delta carries every change" {
    const MoveDelta = @import("../player/move_delta.zig");
    const at = struct {
        fn f(x: f32, y: f32, z: f32) MoveDelta.State {
            return .{ .position = .{ x, y, z }, .rotation = .{ 0, 0, 0 } };
        }
    }.f;

    var last: MoveDelta.LastBroadcast = .{};
    var pending: ?MoveDelta.State = null;
    var emitted: ?Protocol.MoveActorDeltaPacket = null;

    const ticks = [_]struct { tick: u64, state: MoveDelta.State }{
        .{ .tick = 0, .state = at(1, 64, 0) },
        .{ .tick = 1, .state = at(1, 65, 0) },
        .{ .tick = 2, .state = at(1, 65, 1) },
        .{ .tick = 3, .state = at(1, 65, 2) },
        .{ .tick = 4, .state = at(2, 65, 2) },
    };

    for (ticks) |t| {
        pending = t.state;
        if (!due(4, t.tick)) continue;
        emitted = MoveDelta.nextDelta(&last, 7, pending.?, t.tick);
        pending = null;
    }

    try testing.expect(pending == null);
    const packet = emitted orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?f32, 2), packet.x);
    try testing.expectEqual(@as(?f32, 65), packet.y);
    try testing.expectEqual(@as(?f32, 2), packet.z);
}

test "a teleport is never deferred by the band gate" {
    const MoveDelta = @import("../player/move_delta.zig");
    var last: MoveDelta.LastBroadcast = .{};
    _ = MoveDelta.nextDelta(&last, 7, .{ .position = .{ 0, 64, 0 }, .rotation = .{ 0, 0, 0 } }, 0) orelse
        return error.TestUnexpectedResult;

    const jumped = MoveDelta.State{ .position = .{ 40, 64, 0 }, .rotation = .{ 0, 0, 0 } };
    try testing.expect(!due(8, 9));
    try testing.expect(MoveDelta.isTeleport(&last, jumped));
    try testing.expect(emission(8, 8, 9, MoveDelta.isTeleport(&last, jumped)).send);

    const packet = MoveDelta.nextDelta(&last, 7, jumped, 9) orelse return error.TestUnexpectedResult;
    try testing.expect(packet.force_move);
}

test "the region radius covers the view distance" {
    var view: i32 = 0;
    while (view <= 32) : (view += 1) {
        const radius = regionRadius(view);
        try testing.expect(radius >= 1);
        try testing.expect((radius - 1) * REGION_BLOCKS >= view * 16);
    }
}

test "a viewer only walks the buckets around it" {
    const allocator = testing.allocator;
    var index: Index = .{};
    defer index.deinit(allocator);

    var visible = std.AutoHashMap(i64, u32).init(allocator);
    defer visible.deinit();
    try visible.put(10, 1);
    try visible.put(20, 1);

    try visible.put(30, 1);
    try visible.put(40, 1);

    try index.add(allocator, regionOf(1, 0, 0), refAt(10, 0, 2));
    try index.add(allocator, regionOf(1, 0, 0), refAt(20, 2, 2));
    try index.add(allocator, regionOf(1, 1000, 0), refAt(30, 4, 2));
    try index.add(allocator, regionOf(2, 0, 0), refAt(40, 6, 2));
    try index.finish(allocator);

    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    try index.collect(allocator, &candidates, 1, 0, 0, 2);
    try testing.expectEqual(@as(usize, 1), candidates.items.len);

    const payload = "aabbccdd";
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    const cursor = fillBatch(
        &out,
        allocator,
        fakePayload(payload),
        index.slots.items,
        index.buckets.items,
        candidates.items,
        .{},
        99,
        visible,
        MAX_BATCH_BYTES,
    );

    try testing.expectEqual(candidates.items.len, cursor.bucket);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualSlices(u8, "aa", out.items[0]);
    try testing.expectEqualSlices(u8, "bb", out.items[1]);
}

test "a receiver never gets its own delta" {
    const allocator = testing.allocator;
    var index: Index = .{};
    defer index.deinit(allocator);

    var visible = std.AutoHashMap(i64, u32).init(allocator);
    defer visible.deinit();
    try visible.put(10, 1);
    try visible.put(20, 1);

    try index.add(allocator, regionOf(1, 0, 0), refAt(20, 0, 2));
    try index.add(allocator, regionOf(1, 0, 0), refAt(10, 2, 2));
    try index.finish(allocator);

    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    try index.collect(allocator, &candidates, 1, 0, 0, 1);

    const payload = "aabb";
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    _ = fillBatch(
        &out,
        allocator,
        fakePayload(payload),
        index.slots.items,
        index.buckets.items,
        candidates.items,
        .{},
        20,
        visible,
        MAX_BATCH_BYTES,
    );

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualSlices(u8, "bb", out.items[0]);
}

test "a size cut drops nothing: the rest goes out in the next batch" {
    const allocator = testing.allocator;
    var payload: [100 * 29]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    var index: Index = .{};
    defer index.deinit(allocator);

    var visible = std.AutoHashMap(i64, u32).init(allocator);
    defer visible.deinit();
    for (0..100) |i| {
        try index.add(allocator, regionOf(1, @floatFromInt(i * REGION_BLOCKS * 2), 0), refAt(@intCast(i), i * 29, 29));
        try visible.put(@intCast(i), 1);
    }

    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    try index.finish(allocator);
    try index.collect(allocator, &candidates, 1, 0, 0, 200);
    try testing.expectEqual(@as(usize, 100), candidates.items.len);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    var batches: usize = 0;
    var delivered: usize = 0;
    var cursor: Cursor = .{};
    while (cursor.bucket < candidates.items.len) {
        out.clearRetainingCapacity();
        cursor = fillBatch(
            &out,
            allocator,
            fakePayload(&payload),
            index.slots.items,
            index.buckets.items,
            candidates.items,
            cursor,
            1000,
            visible,
            MAX_BATCH_BYTES,
        );
        try testing.expect(out.items.len > 0);

        var bytes: usize = 0;
        for (out.items) |slice| bytes += slice.len;
        try testing.expect(bytes <= MAX_BATCH_BYTES or out.items.len == 1);

        batches += 1;
        delivered += out.items.len;
    }

    try testing.expectEqual(@as(usize, 100), delivered);
    try testing.expect(batches > 1);
}

test "a delta larger than the limit is still emitted and the loop progresses" {
    const allocator = testing.allocator;
    var index: Index = .{};
    defer index.deinit(allocator);

    var visible = std.AutoHashMap(i64, u32).init(allocator);
    defer visible.deinit();
    try visible.put(10, 1);

    const payload = [_]u8{0xAA} ** (MAX_BATCH_BYTES * 2);
    try index.add(allocator, regionOf(1, 0, 0), refAt(10, 0, payload.len));
    try index.finish(allocator);

    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    try index.collect(allocator, &candidates, 1, 0, 0, 1);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    const cursor = fillBatch(
        &out,
        allocator,
        fakePayload(&payload),
        index.slots.items,
        index.buckets.items,
        candidates.items,
        .{},
        99,
        visible,
        MAX_BATCH_BYTES,
    );

    try testing.expectEqual(candidates.items.len, cursor.bucket);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "invisible deltas do not consume batch budget" {
    const allocator = testing.allocator;
    var index: Index = .{};
    defer index.deinit(allocator);

    var visible = std.AutoHashMap(i64, u32).init(allocator);
    defer visible.deinit();
    try visible.put(50, 1);

    var payload: [51 * 29]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    for (0..51) |i| {
        const rid: i64 = if (i == 50) 50 else @intCast(i);
        try index.add(allocator, regionOf(1, @floatFromInt(i), 0), refAt(rid, i * 29, 29));
    }
    try index.finish(allocator);

    var candidates: std.ArrayListUnmanaged(u32) = .empty;
    defer candidates.deinit(allocator);
    try index.collect(allocator, &candidates, 1, 0, 0, 50);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    const cursor = fillBatch(
        &out,
        allocator,
        fakePayload(&payload),
        index.slots.items,
        index.buckets.items,
        candidates.items,
        .{},
        99,
        visible,
        MAX_BATCH_BYTES,
    );

    try testing.expectEqual(candidates.items.len, cursor.bucket);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "offsets stay valid when the tick buffer grows" {
    var stream = BinaryStream.init(testing.allocator, null, null);
    defer stream.deinit();

    var refs: std.ArrayList(DeltaRef) = .empty;
    defer refs.deinit(testing.allocator);

    const initial_capacity = stream.capacity();

    for (0..300) |i| {
        const packet = Protocol.MoveActorDeltaPacket{
            .runtime_id = @intCast(i),
            .x = @floatFromInt(i),
            .y = @floatFromInt(i * 2),
            .z = @floatFromInt(i * 3),
            .rotation_x = @intCast(@as(i32, @intCast(i % 128)) - 64),
            .on_ground = i % 2 == 0,
        };
        const before = stream.getBuffer().len;
        _ = try packet.serialize(&stream);
        try refs.append(testing.allocator, markRef(&stream, @intCast(i), before));
    }

    try testing.expect(stream.capacity() > initial_capacity);

    const payload = stream.getBuffer();

    var total: usize = 0;
    for (refs.items) |ref| total += ref.len;
    try testing.expectEqual(payload.len, total);

    for (refs.items, 0..) |ref, i| {
        var reader = BinaryStream.init(testing.allocator, ref.slice(payload), null);
        const decoded = try Protocol.MoveActorDeltaPacket.deserialize(&reader);
        try testing.expectEqual(@as(u64, i), decoded.runtime_id);
        try testing.expectEqual(@as(?f32, @floatFromInt(i)), decoded.x);
        try testing.expectEqual(@as(?f32, @floatFromInt(i * 3)), decoded.z);
        try testing.expectEqual(i % 2 == 0, decoded.on_ground);
    }
}
