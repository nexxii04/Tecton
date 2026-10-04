const std = @import("std");

const Player = @import("../player/player.zig").Player;
const ChunkHash = @import("../world/dimension/dimension.zig").ChunkHash;
const WorldRegistry = @import("worlds.zig").WorldRegistry;

pub const chunks_per_tick: usize = 32;
pub const players_per_tick: usize = 2;
pub const ns_budget: u64 = 2_000_000;

const Group = struct {
    world: []u8,
    dim: []u8,
    hashes: []ChunkHash,
};

pub const SaveScheduler = struct {
    in_flight: bool = false,
    plan: std.ArrayListUnmanaged(Group) = .empty,
    cursor: struct { group: usize = 0, chunk: usize = 0 } = .{},
    players_pending: bool = false,
    player_cursor: usize = 0,

    pub fn deinit(self: *SaveScheduler, allocator: std.mem.Allocator) void {
        self.freePlan(allocator);
    }

    pub fn begin(self: *SaveScheduler, allocator: std.mem.Allocator, worlds: *const WorldRegistry) void {
        self.freePlan(allocator);
        self.cursor = .{};
        self.player_cursor = 0;
        self.players_pending = true;
        self.in_flight = true;

        var worlds_it = worlds.valueIterator();
        while (worlds_it.next()) |world| {
            var dims_it = world.*.dimensions.valueIterator();
            while (dims_it.next()) |dim| {
                var hashes = std.ArrayListUnmanaged(ChunkHash).empty;
                var chunk_it = dim.*.chunks.keyIterator();
                while (chunk_it.next()) |hash| hashes.append(allocator, hash.*) catch break;
                if (hashes.items.len == 0) {
                    hashes.deinit(allocator);
                    continue;
                }
                const owned = hashes.toOwnedSlice(allocator) catch {
                    hashes.deinit(allocator);
                    continue;
                };
                const world_name = allocator.dupe(u8, world.*.identifier) catch {
                    allocator.free(owned);
                    continue;
                };
                const dim_name = allocator.dupe(u8, dim.*.identifier) catch {
                    allocator.free(owned);
                    allocator.free(world_name);
                    continue;
                };
                self.plan.append(allocator, .{ .world = world_name, .dim = dim_name, .hashes = owned }) catch {
                    allocator.free(owned);
                    allocator.free(world_name);
                    allocator.free(dim_name);
                    continue;
                };
            }
        }
    }

    pub fn tick(
        self: *SaveScheduler,
        io: std.Io,
        allocator: std.mem.Allocator,
        worlds: *const WorldRegistry,
        players: []const *Player,
    ) void {
        if (!self.in_flight) return;

        const started = std.Io.Timestamp.now(io, .awake);
        var budget = chunks_per_tick;
        while (budget > 0 and self.cursor.group < self.plan.items.len) {
            const group = self.plan.items[self.cursor.group];
            if (self.cursor.chunk >= group.hashes.len) {
                self.cursor.group += 1;
                self.cursor.chunk = 0;
                continue;
            }
            const hash = group.hashes[self.cursor.chunk];
            self.cursor.chunk += 1;
            budget -= 1;
            saveOneChunk(worlds, group, hash);
            if (started.durationTo(.now(io, .awake)).nanoseconds >= ns_budget) break;
        }

        if (self.cursor.group < self.plan.items.len) return;

        if (self.players_pending) {
            var saved: usize = 0;
            while (saved < players_per_tick and self.player_cursor < players.len) : (saved += 1) {
                players[self.player_cursor].savePlayerData();
                self.player_cursor += 1;
            }
            if (self.player_cursor < players.len) return;
            self.players_pending = false;
        }

        self.in_flight = false;
        self.freePlan(allocator);
    }

    fn freePlan(self: *SaveScheduler, allocator: std.mem.Allocator) void {
        for (self.plan.items) |group| {
            allocator.free(group.hashes);
            allocator.free(group.world);
            allocator.free(group.dim);
        }
        self.plan.deinit(allocator);
        self.plan = .empty;
    }
};

fn saveOneChunk(worlds: *const WorldRegistry, group: Group, hash: ChunkHash) void {
    const world = worlds.get(group.world) orelse return;
    const dim = world.getDimension(group.dim) orelse return;
    const chunk = dim.chunks.get(hash) orelse return;
    world.provider.writeChunkEntities(chunk, dim) catch {};
    world.provider.writeBlockEntities(chunk, dim) catch {};
    if (chunk.dirty) world.provider.writeChunk(chunk, dim) catch {};
}
