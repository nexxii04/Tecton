const std = @import("std");
const Raknet = @import("Raknet");

const Player = @import("../player/player.zig").Player;
const PlayerSnapshot = @import("../player/player_snapshot.zig").PlayerSnapshot;
const MovementBroadcast = @import("../network/movement_broadcast.zig");

pub const PlayerRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    by_runtime_id: std.AutoHashMap(i64, *Player),
    by_connection: std.AutoHashMap(usize, *Player),
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
            .by_connection = std.AutoHashMap(usize, *Player).init(allocator),
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
        try self.by_connection.put(@intFromPtr(player.connection), player);
    }

    pub fn remove(self: *PlayerRegistry, player: *Player) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        _ = self.by_runtime_id.remove(player.entity.runtime_id);
        self.publishPlayerCountLocked();
        _ = self.by_connection.remove(@intFromPtr(player.connection));
    }

    pub fn removeConnection(self: *PlayerRegistry, connection: *Raknet.Connection) void {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return;
        };
        defer self.mutex.unlock(self.io);
        _ = self.by_connection.remove(@intFromPtr(connection));
        self.publishPlayerCountLocked();
    }

    pub fn byConnection(self: *PlayerRegistry, connection: *Raknet.Connection) ?*Player {
        self.mutex.lock(self.io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(self.io);
        if (self.by_connection.count() == 0) return null;
        return self.by_connection.get(@intFromPtr(connection));
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
