const std = @import("std");
const Player = @import("player.zig").Player;

pub const buffer_count = 4;

pub const PlayerSnapshot = struct {
    buffers: [buffer_count]std.ArrayList(*Player),
    live: std.atomic.Value(u8) = .init(0),
    write: u8 = 0,
    version: u64 = 0,

    pub fn init() PlayerSnapshot {
        return .{ .buffers = .{ .empty, .empty, .empty, .empty } };
    }

    pub fn deinit(self: *PlayerSnapshot, allocator: std.mem.Allocator) void {
        for (&self.buffers) |*buffer| buffer.deinit(allocator);
    }

    pub fn items(self: *const PlayerSnapshot) []const *Player {
        return self.buffers[self.live.load(.acquire)].items;
    }

    pub fn publish(self: *PlayerSnapshot, allocator: std.mem.Allocator, iter: anytype) void {
        var it = iter;
        const next = (self.write +% 1) % buffer_count;
        const dst = &self.buffers[next];
        dst.clearRetainingCapacity();
        while (it.next()) |entry| {
            const player = entry.*;
            if (player.pending_removal.load(.acquire)) continue;
            dst.append(allocator, player) catch break;
        }

        if (std.mem.eql(*Player, self.buffers[self.live.load(.monotonic)].items, dst.items)) return;

        self.write = next;
        self.live.store(next, .release);
        self.version += 1;
    }
};

fn fakePlayer(removal_pending: bool) Player {
    var player: Player = undefined;
    player.pending_removal = .init(removal_pending);
    return player;
}

const Players = struct {
    storage: [8]Player = undefined,
    map: std.AutoHashMap(i64, *Player) = undefined,

    fn init(self: *Players, allocator: std.mem.Allocator, pending: []const bool) void {
        self.map = std.AutoHashMap(i64, *Player).init(allocator);
        for (pending, 0..) |is_pending, i| {
            self.storage[i] = fakePlayer(is_pending);
            self.map.put(@intCast(i + 1), &self.storage[i]) catch unreachable;
        }
    }

    fn deinit(self: *Players) void {
        self.map.deinit();
    }

    fn add(self: *Players, index: usize, removal_pending: bool) void {
        self.storage[index] = fakePlayer(removal_pending);
        self.map.put(@intCast(index + 1), &self.storage[index]) catch unreachable;
    }

    fn publish(self: *Players, snapshot: *PlayerSnapshot, allocator: std.mem.Allocator) void {
        snapshot.publish(allocator, self.map.valueIterator());
    }
};

fn expectSameSet(expected: []const *Player, actual: []const *Player) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |wanted| {
        var found = false;
        for (actual) |candidate| {
            if (candidate == wanted) found = true;
        }
        try std.testing.expect(found);
    }
}

test "a published slice survives later mutations" {
    const allocator = std.testing.allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    var players: Players = undefined;
    players.init(allocator, &.{ false, false, false });
    defer players.deinit();

    players.publish(&snapshot, allocator);
    const held = snapshot.items();
    try std.testing.expectEqual(@as(usize, 3), held.len);
    const original = [_]*Player{ &players.storage[0], &players.storage[1], &players.storage[2] };

    players.add(3, false);
    players.publish(&snapshot, allocator);
    try expectSameSet(&original, held);
    try std.testing.expectEqual(@as(usize, 4), snapshot.items().len);

    players.add(4, false);
    players.publish(&snapshot, allocator);
    try expectSameSet(&original, held);
    try std.testing.expectEqual(@as(usize, 5), snapshot.items().len);
}

test "the publisher stays off the published buffer within its margin" {
    const allocator = std.testing.allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    var players: Players = undefined;
    players.init(allocator, &.{false});
    defer players.deinit();

    players.publish(&snapshot, allocator);
    const held = snapshot.items();
    const original = [_]*Player{&players.storage[0]};

    for (0..buffer_count - 1) |i| {
        players.add(i + 1, false);
        players.publish(&snapshot, allocator);
        try expectSameSet(&original, held);
    }
}

test "identical republications do not consume stability margin" {
    const allocator = std.testing.allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    var players: Players = undefined;
    players.init(allocator, &.{false});
    defer players.deinit();

    players.publish(&snapshot, allocator);
    const held = snapshot.items();
    const original = [_]*Player{&players.storage[0]};
    try std.testing.expectEqual(@as(u64, 1), snapshot.version);

    for (0..10) |_| {
        players.publish(&snapshot, allocator);
        try std.testing.expectEqual(@as(u64, 1), snapshot.version);
    }

    for (0..buffer_count - 1) |i| {
        players.add(i + 1, false);
        players.publish(&snapshot, allocator);
        try expectSameSet(&original, held);
    }
}

test "a player on its way out is not published" {
    const allocator = std.testing.allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    var players: Players = undefined;
    players.init(allocator, &.{ false, true, false });
    defer players.deinit();

    players.publish(&snapshot, allocator);

    const expected = [_]*Player{ &players.storage[0], &players.storage[2] };
    try expectSameSet(&expected, snapshot.items());
}

test "a concurrent read between publications always sees a valid list" {
    const allocator = std.heap.smp_allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    const pool_size = 6;
    var pool: [pool_size]Player = undefined;
    for (&pool) |*player| player.* = fakePlayer(false);
    var map = std.AutoHashMap(i64, *Player).init(allocator);
    defer map.deinit();
    for (0..pool_size) |i| map.put(@intCast(i + 1), &pool[i]) catch unreachable;
    snapshot.publish(allocator, map.valueIterator());

    const cycles = 5000;
    var published = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const Writer = struct {
        fn run(
            snap: *PlayerSnapshot,
            map_ptr: *std.AutoHashMap(i64, *Player),
            ids: []Player,
            alloc: std.mem.Allocator,
            produced: *std.atomic.Value(usize),
            taken: *std.atomic.Value(usize),
            total: usize,
        ) void {
            for (0..total) |i| {
                while (taken.load(.acquire) < i) std.atomic.spinLoopHint();
                const key: i64 = @intCast(i % ids.len + 1);
                if (i % 3 == 0) {
                    _ = map_ptr.remove(key);
                } else {
                    map_ptr.put(key, &ids[i % ids.len]) catch unreachable;
                }
                snap.publish(alloc, map_ptr.valueIterator());
                produced.store(i + 1, .release);
            }
        }
    };

    const Reader = struct {
        fn run(
            snap: *PlayerSnapshot,
            ids: []const Player,
            produced: *std.atomic.Value(usize),
            taken: *std.atomic.Value(usize),
            total: usize,
        ) void {
            const low = @intFromPtr(ids.ptr);
            const high = low + @sizeOf(Player) * ids.len;
            for (0..total) |i| {
                var spins: usize = 0;
                while (produced.load(.acquire) < i + 1) : (spins += 1) {
                    if (spins > 1_000_000_000) @panic("el publicador no llego a publicar");
                    std.atomic.spinLoopHint();
                }
                for (snap.items()) |player| {
                    if (@intFromPtr(player) < low or @intFromPtr(player) >= high) {
                        @panic("la lista publicada entrego un puntero que no es de un jugador");
                    }
                }
                taken.store(i + 1, .release);
            }
        }
    };

    const writer = try std.Thread.spawn(.{}, Writer.run, .{
        &snapshot, &map, &pool, allocator, &published, &consumed, cycles,
    });
    Reader.run(&snapshot, &pool, &published, &consumed, cycles);
    writer.join();

    try std.testing.expectEqual(@as(usize, cycles), consumed.load(.acquire));
}

test "marking a player as leaving changes the published list" {
    const allocator = std.testing.allocator;
    var snapshot = PlayerSnapshot.init();
    defer snapshot.deinit(allocator);

    var players: Players = undefined;
    players.init(allocator, &.{ true, false });
    defer players.deinit();

    players.publish(&snapshot, allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items().len);
    try std.testing.expectEqual(&players.storage[1], snapshot.items()[0]);

    players.storage[0].pending_removal.store(false, .release);
    players.publish(&snapshot, allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.items().len);
    try std.testing.expectEqual(@as(u64, 2), snapshot.version);
}
