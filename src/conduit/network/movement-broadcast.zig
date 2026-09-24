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

pub fn fillBatch(
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    payload: []const u8,
    deltas: []const DeltaRef,
    start: usize,
    viewer_rid: i64,
    visible: anytype,
    max_bytes: usize,
) usize {
    var bytes: usize = 0;
    var index = start;

    while (index < deltas.len) : (index += 1) {
        const ref = deltas[index];

        if (ref.emitter_rid == viewer_rid) continue;
        if (!visible.contains(ref.emitter_rid)) continue;

        if (out.items.len > 0 and bytes + ref.len > max_bytes) return index;

        out.append(allocator, ref.slice(payload)) catch return deltas.len;
        bytes += ref.len;
    }

    return index;
}

fn fakePayload(bytes: []const u8) []const u8 {
    return bytes;
}

fn refAt(emitter_rid: i64, offset: usize, len: usize) DeltaRef {
    return .{ .emitter_rid = emitter_rid, .offset = offset, .len = len };
}

test "a receiver only gets deltas from the senders it can see" {
    var visible = std.AutoHashMap(i64, u32).init(testing.allocator);
    defer visible.deinit();
    try visible.put(10, 1);
    try visible.put(20, 1);

    const payload = "aabbccdd";
    const deltas = [_]DeltaRef{
        refAt(10, 0, 2),
        refAt(20, 2, 2),
        refAt(30, 4, 2),
        refAt(40, 6, 2),
    };

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    const next = fillBatch(&out, testing.allocator, fakePayload(payload), &deltas, 0, 99, visible, MAX_BATCH_BYTES);

    try testing.expectEqual(@as(usize, 4), next);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualSlices(u8, "aa", out.items[0]);
    try testing.expectEqualSlices(u8, "bb", out.items[1]);
}

test "a receiver never gets its own delta" {
    var visible = std.AutoHashMap(i64, u32).init(testing.allocator);
    defer visible.deinit();
    try visible.put(10, 1);

    try visible.put(20, 1);

    const payload = "aabb";
    const deltas = [_]DeltaRef{ refAt(20, 0, 2), refAt(10, 2, 2) };

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    _ = fillBatch(&out, testing.allocator, fakePayload(payload), &deltas, 0, 20, visible, MAX_BATCH_BYTES);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualSlices(u8, "bb", out.items[0]);
}

test "a size cut drops nothing: the rest goes out in the next Baket" {
    var payload: [100 * 29]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    var deltas: [100]DeltaRef = undefined;
    for (&deltas, 0..) |*ref, i| ref.* = refAt(@intCast(i), i * 29, 29);

    var visible = std.AutoHashMap(i64, u32).init(testing.allocator);
    defer visible.deinit();
    for (0..100) |i| try visible.put(@intCast(i), 1);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    var batches: usize = 0;
    var delivered: usize = 0;
    var index: usize = 0;
    while (index < deltas.len) {
        out.clearRetainingCapacity();
        index = fillBatch(&out, testing.allocator, fakePayload(&payload), &deltas, index, 1000, visible, MAX_BATCH_BYTES);
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
    var visible = std.AutoHashMap(i64, u32).init(testing.allocator);
    defer visible.deinit();
    try visible.put(10, 1);

    const payload = [_]u8{0xAA} ** (MAX_BATCH_BYTES * 2);
    const deltas = [_]DeltaRef{refAt(10, 0, payload.len)};

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    const next = fillBatch(&out, testing.allocator, fakePayload(&payload), &deltas, 0, 99, visible, MAX_BATCH_BYTES);

    try testing.expectEqual(@as(usize, 1), next);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "invisible deltas do not consume Baket budget" {
    var visible = std.AutoHashMap(i64, u32).init(testing.allocator);
    defer visible.deinit();
    try visible.put(50, 1);

    var payload: [51 * 29]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    var deltas: [51]DeltaRef = undefined;
    for (&deltas, 0..) |*ref, i| {
        const rid: i64 = if (i == 50) 50 else @intCast(i);
        ref.* = refAt(rid, i * 29, 29);
    }

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);

    const next = fillBatch(&out, testing.allocator, fakePayload(&payload), &deltas, 0, 99, visible, MAX_BATCH_BYTES);

    try testing.expectEqual(@as(usize, 51), next);
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
