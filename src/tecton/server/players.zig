const std = @import("std");

const connection_mod = @import("../transport/connection.zig");
const Connection = connection_mod.Connection;

const Player = @import("../player/player.zig").Player;
const PlayerSnapshot = @import("../player/player_snapshot.zig").PlayerSnapshot;
const MovementBroadcast = @import("../network/movement_broadcast.zig");

pub const PlayerRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    by_runtime_id: std.AutoHashMap(i64, *Player),
    by_connection: std.AutoHashMap(u64, *Player),
    mutex: std.Io.Mutex = .init,
    online_count: std.atomic.Value(usize) = .init(0),
    snapshot: PlayerSnapshot,
    pending_removals: std.ArrayList(*Player),
    pending_mutex: std.Io.Mutex = .init,
    movement_index: MovementBroadcast.Index = .{},
    movement_candidates: std.ArrayListUnmanaged(u32) = .empty,
    movement_batch: std.ArrayList([]const u8) = .empty,
    movement_viewers: std.ArrayListUnmanaged(MovementBroadcast.ViewerPoint) = .empty,

    publishing: bool = true,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) PlayerRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .by_runtime_id = std.AutoHashMap(i64, *Player).init(allocator),
            .by_connection = std.AutoHashMap(u64, *Player).init(allocator),
            .snapshot = PlayerSnapshot.init(),
            .pending_removals = std.ArrayList(*Player).empty,
        };
    }

    pub fn deinit(self: *PlayerRegistry) void {
        self.movement_index.deinit(self.allocator);
        self.movement_candidates.deinit(self.allocator);
        self.movement_batch.deinit(self.allocator);
        self.movement_viewers.deinit(self.allocator);
        self.pending_removals.deinit(self.allocator);
        self.by_runtime_id.deinit();
        self.by_connection.deinit();
        self.snapshot.deinit(self.allocator);
    }

    pub fn silence(self: *PlayerRegistry) void {
        self.publishing = false;
    }

    fn publishPlayerCountLocked(self: *PlayerRegistry) void {
        self.online_count.store(self.by_runtime_id.count(), .release);
        self.snapshot.publish(self.allocator, self.by_runtime_id.valueIterator());
    }

    pub fn insert(self: *PlayerRegistry, player: *Player) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.by_runtime_id.put(player.entity.runtime_id, player);
        self.publishPlayerCountLocked();
        try self.by_connection.put(player.connection.id, player);
    }

    pub fn remove(self: *PlayerRegistry, player: *Player) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        _ = self.by_runtime_id.remove(player.entity.runtime_id);
        self.publishPlayerCountLocked();
        _ = self.by_connection.remove(player.connection.id);
    }

    pub fn removeConnection(self: *PlayerRegistry, connection: *Connection) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        _ = self.by_connection.remove(connection.id);
        self.publishPlayerCountLocked();
    }

    pub fn byConnection(self: *PlayerRegistry, connection: *Connection) ?*Player {
        return self.byConnectionId(connection.id);
    }

    pub fn byConnectionId(self: *PlayerRegistry, connection_id: u64) ?*Player {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(self.io);
        if (self.by_connection.count() == 0) return null;
        return self.by_connection.get(connection_id);
    }

    pub fn byRuntimeId(self: *PlayerRegistry, runtime_id: i64) ?*Player {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(self.io);
        return self.by_runtime_id.get(runtime_id);
    }

    pub fn rebuild(self: *PlayerRegistry) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        self.snapshot.publish(self.allocator, self.by_runtime_id.valueIterator());
    }

    pub fn destroyPlayers(self: *PlayerRegistry) void {
        var it = self.by_runtime_id.valueIterator();
        while (it.next()) |player| {
            player.*.connection.release();
            player.*.deinit();
            self.allocator.destroy(player.*);
        }
    }

    pub fn list(self: *const PlayerRegistry) []const *Player {
        if (!self.publishing) return &.{};
        return self.snapshot.items();
    }

    pub fn count(self: *const PlayerRegistry) usize {
        return self.online_count.load(.acquire);
    }

    pub fn enqueueRemoval(self: *PlayerRegistry, player: *Player) void {
        self.pending_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.pending_mutex.unlock(self.io);
        self.pending_removals.append(self.allocator, player) catch {
            std.log.err("failed to enqueue player removal: {s}", .{player.username});
        };
    }

    pub fn takePendingRemovals(self: *PlayerRegistry) std.ArrayList(*Player) {
        self.pending_mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return .empty;
        };
        const pending = self.pending_removals;
        self.pending_removals = .empty;
        self.pending_mutex.unlock(self.io);
        return pending;
    }
};

/// Marks every player whose transport session is gone without a `closed` event reaching the
/// tick. The hand-off queue is bounded, so a dropped event is possible; the session state is
/// the backstop. It only marks and enqueues: the removal drain still frees the player.
pub fn reconcileClosedConnections(players: []const *Player) usize {
    var reconciled: usize = 0;
    for (players) |player| {
        if (player.pending_removal.load(.acquire)) continue;
        if (player.connection.isOpen()) continue;
        player.disconnectFromNetwork();
        reconciled += 1;
    }
    return reconciled;
}

const testing = std.testing;
const player_mod = @import("../player/player.zig");

const ReconcileProbe = struct {
    removals: usize = 0,
    mappings: usize = 0,

    fn removeConnectionMapping(ctx: *anyopaque, _: *anyopaque) void {
        const self: *ReconcileProbe = @ptrCast(@alignCast(ctx));
        self.mappings += 1;
    }

    fn enqueueRemoval(ctx: *anyopaque, _: *Player) void {
        const self: *ReconcileProbe = @ptrCast(@alignCast(ctx));
        self.removals += 1;
    }
};

fn fakeConnection(allocator: std.mem.Allocator, id: u64) !*Connection {
    const conn = try allocator.create(Connection);
    conn.* = .{
        .id = id,
        .backend = undefined,
        .allocator = allocator,
        .refs = std.atomic.Value(u32).init(1),
        .state = std.atomic.Value(connection_mod.State).init(.open),
    };
    return conn;
}

test "reconciliation marks only players whose session closed without an event" {
    const allocator = std.testing.allocator;
    var probe = ReconcileProbe{};
    var host: player_mod.Host = undefined;
    host.ctx = &probe;
    host.remove_connection_mapping = ReconcileProbe.removeConnectionMapping;
    host.enqueue_player_removal = ReconcileProbe.enqueueRemoval;

    const open_conn = try fakeConnection(allocator, 1);
    defer open_conn.release();
    const closed_conn = try fakeConnection(allocator, 2);
    defer closed_conn.release();
    closed_conn.markClosed();

    var open_player: Player = undefined;
    open_player.connection = open_conn;
    open_player.tecton = host;
    open_player.pending_removal = .init(false);

    var closed_player: Player = undefined;
    closed_player.connection = closed_conn;
    closed_player.tecton = host;
    closed_player.pending_removal = .init(false);

    const players = [_]*Player{ &open_player, &closed_player };
    try testing.expectEqual(@as(usize, 1), reconcileClosedConnections(&players));
    try testing.expect(!open_player.pending_removal.load(.acquire));
    try testing.expect(closed_player.pending_removal.load(.acquire));
    try testing.expectEqual(@as(usize, 1), probe.removals);
    try testing.expectEqual(@as(usize, 1), probe.mappings);

    try testing.expectEqual(@as(usize, 0), reconcileClosedConnections(&players));
    try testing.expectEqual(@as(usize, 1), probe.removals);
}

test "every `by_runtime_id` mutation refreshes the atomic count" {
    const source = @embedFile("players.zig");
    const mutating_calls = [_][]const u8{
        "self.by_runtime_id.put(",
        "self.by_runtime_id.putNoClobber(",
        "self.by_runtime_id.remove(",
        "self.by_runtime_id.fetchRemove(",
        "self.by_runtime_id.clearRetainingCapacity(",
        "self.by_runtime_id.clearAndFree(",
    };
    const refresh = "publishPlayerCountLocked()";
    const max_gap: usize = 4;

    var mutations: usize = 0;
    var missing: ?usize = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var last_mutation_line: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        var is_mutation = false;
        for (mutating_calls) |needle| {
            if (std.mem.indexOf(u8, line, needle) != null) is_mutation = true;
        }
        if (is_mutation) {
            mutations += 1;
            last_mutation_line = line_no;
            continue;
        }
        if (last_mutation_line != 0 and line_no - last_mutation_line <= max_gap) {
            if (std.mem.indexOf(u8, line, refresh) != null) last_mutation_line = 0;
        }
        if (last_mutation_line != 0 and line_no - last_mutation_line > max_gap and missing == null) {
            missing = last_mutation_line;
        }
    }

    if (missing) |at| {
        std.debug.print("players.zig:{d}: `by_runtime_id` mutation without refreshing the counter\n", .{at});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 0), last_mutation_line);
    try std.testing.expect(mutations >= 2);
}
