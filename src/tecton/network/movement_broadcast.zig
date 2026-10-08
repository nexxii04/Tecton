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

const test_owner = @This();
const test_scope = struct {
    pub const test_dependency_0 = @import("../player/move_delta.zig");
    pub const std = test_owner.std;
    pub const testing = test_owner.testing;
    pub const BinaryStream = test_owner.BinaryStream;
    pub const Protocol = test_owner.Protocol;
    pub const MAX_BATCH_BYTES = test_owner.MAX_BATCH_BYTES;
    pub const markRef = test_owner.markRef;
    pub const DeltaRef = test_owner.DeltaRef;
    pub const REGION_BLOCKS = test_owner.REGION_BLOCKS;
    pub const regionOf = test_owner.regionOf;
    pub const regionRadius = test_owner.regionRadius;
    pub const BAND_INTERVALS = test_owner.BAND_INTERVALS;
    pub const BAND_DISTANCES = test_owner.BAND_DISTANCES;
    pub const bandForDistanceSq = test_owner.bandForDistanceSq;
    pub const due = test_owner.due;
    pub const emission = test_owner.emission;
    pub const ViewerPoint = test_owner.ViewerPoint;
    pub const nearestViewerBand = test_owner.nearestViewerBand;
    pub const Cursor = test_owner.Cursor;
    pub const Index = test_owner.Index;
    pub const fillBatch = test_owner.fillBatch;
    pub const fakePayload = test_owner.fakePayload;
    pub const refAt = test_owner.refAt;
};

test "the distance bands step at 16, 32 and 48 blocks" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_000();
}

test "every band is produced on its own stride" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_001();
}

test "a band change forces a full state and a teleport is never deferred" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_002();
}

test "the band comes from the nearest viewer in the same dimension" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_003();
}

test "a skipped tick is not lost: the next delta carries every change" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_004();
}

test "a teleport is never deferred by the band gate" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_005();
}

test "the region radius covers the view distance" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_006();
}

test "a viewer only walks the buckets around it" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_007();
}

test "a receiver never gets its own delta" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_008();
}

test "a size cut drops nothing: the rest goes out in the next batch" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_009();
}

test "a delta larger than the limit is still emitted and the loop progresses" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_010();
}

test "invisible deltas do not consume batch budget" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_011();
}

test "offsets stay valid when the tick buffer grows" {
    try @import("movement_broadcast_test.zig").Suite(test_scope).case_012();
}
