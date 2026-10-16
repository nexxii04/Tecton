const std = @import("std");
const Raknet = @import("Raknet");

pub const MAX_PACKET_QUEUE: usize = 4096;
pub const MAX_PACKETS_PER_DRAIN: usize = 4096;

pub const QueuedPacket = struct {
    conn: *Raknet.Connection,
    generation: u64,
    payload: []u8,
    valid: bool = false,
};

pub const PacketDrainResult = struct {
    processed: usize,
    remaining: usize,
};

pub fn drainCap(max_packets: usize) usize {
    return if (max_packets == 0) MAX_PACKETS_PER_DRAIN else @min(max_packets, MAX_PACKETS_PER_DRAIN);
}

/// Keeps packets that did not fit ahead of those that arrived during the drain.
pub fn requeueLeftover(
    out: *std.ArrayList(QueuedPacket),
    arrivals: *std.ArrayList(QueuedPacket),
    allocator: std.mem.Allocator,
    consumed: usize,
) void {
    std.debug.assert(consumed <= out.items.len);
    const leftover_len = out.items.len - consumed;
    std.mem.copyForwards(QueuedPacket, out.items[0..leftover_len], out.items[consumed..]);
    out.items.len = leftover_len;

    out.appendSlice(allocator, arrivals.items) catch {
        for (arrivals.items) |entry| allocator.free(entry.payload);
    };
    arrivals.deinit(allocator);
}

test "leftovers go back ahead of later arrivals" {
    const allocator = std.testing.allocator;
    var batch = std.ArrayList(QueuedPacket).empty;
    defer batch.deinit(allocator);
    var arrivals = std.ArrayList(QueuedPacket).empty;

    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    for ("abcde") |byte| {
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, &.{byte}) });
    }

    for ("fg") |byte| {
        try arrivals.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, &.{byte}) });
    }

    allocator.free(batch.items[0].payload);
    allocator.free(batch.items[1].payload);

    requeueLeftover(&batch, &arrivals, allocator, 2);

    try std.testing.expectEqual(@as(usize, 5), batch.items.len);
    for (batch.items, "cdefg") |entry, expected| {
        try std.testing.expectEqual(expected, entry.payload[0]);
    }

    for (batch.items) |entry| allocator.free(entry.payload);
    batch.items.len = 0;
}

test "requeueing handles an empty leftover and no arrivals" {
    const allocator = std.testing.allocator;
    var conn_storage: u128 align(16) = 0;
    const conn: *Raknet.Connection = @ptrCast(&conn_storage);

    {
        var batch = std.ArrayList(QueuedPacket).empty;
        defer batch.deinit(allocator);
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "a") });
        allocator.free(batch.items[0].payload);
        var arrivals = std.ArrayList(QueuedPacket).empty;
        requeueLeftover(&batch, &arrivals, allocator, 1);
        try std.testing.expectEqual(@as(usize, 0), batch.items.len);
    }

    {
        var batch = std.ArrayList(QueuedPacket).empty;
        defer batch.deinit(allocator);
        try batch.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "a") });
        var arrivals = std.ArrayList(QueuedPacket).empty;
        try arrivals.append(allocator, .{ .conn = conn, .generation = 1, .payload = try allocator.dupe(u8, "b") });
        requeueLeftover(&batch, &arrivals, allocator, 0);
        try std.testing.expectEqual(@as(usize, 2), batch.items.len);
        try std.testing.expectEqual(@as(u8, 'a'), batch.items[0].payload[0]);
        try std.testing.expectEqual(@as(u8, 'b'), batch.items[1].payload[0]);
        for (batch.items) |entry| allocator.free(entry.payload);
        batch.items.len = 0;
    }
}

test "the per-drain cap cannot rise above the hard cap" {
    try std.testing.expectEqual(MAX_PACKETS_PER_DRAIN, drainCap(0));
    try std.testing.expectEqual(@as(usize, 64), drainCap(64));
    try std.testing.expectEqual(MAX_PACKETS_PER_DRAIN, drainCap(MAX_PACKETS_PER_DRAIN * 100));
}
