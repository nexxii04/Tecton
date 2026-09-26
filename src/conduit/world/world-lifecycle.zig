const std = @import("std");
const Raknet = @import("Raknet");
const Conduit = @import("../conduit.zig").Conduit;
const World = @import("./world.zig").World;
const Player = @import("../player/player.zig").Player;
const CommandContext = @import("../command/context.zig").CommandContext;

pub const TaskKind = enum { create, load, unload };

const Stage = enum { build, register, wait_idle, save_destroy, finish };

/// How long an unload waits for dimension worker batches to drain before it
/// gives the world back to the map instead of freeing it under them.
const UNLOAD_IDLE_TIMEOUT_TICKS: u32 = 400;
const TASK_NAME = "world_lifecycle";

/// Staged world create/load/unload. The command handler owns validation and,
/// for unload, detaches the world from Conduit.worlds before enqueueing; this
/// task only runs on the tick thread through TaskQueue.runUntil.
const WorldLifecycleTask = struct {
    conduit: *Conduit,
    kind: TaskKind,
    /// Owned; also the key in conduit.world_ops. Freed by the task cleanup.
    name: []u8,
    sender_runtime_id: ?i64,
    origin_type: []u8,
    uuid: [16]u8,
    request_id: []u8,
    stage: Stage,
    world: ?*World = null,
    ticks_waited: u32 = 0,
    abandoned: bool = false,

    fn reply(self: *WorldLifecycleTask, success: bool, message: []const u8) void {
        var sender: ?*Player = null;
        if (self.sender_runtime_id) |runtime_id| {
            sender = self.conduit.players.get(runtime_id) orelse return;
            if (sender.?.pending_removal.load(.acquire)) return;
        }
        var ctx = CommandContext{
            .player = sender,
            .args = "",
            .network = self.conduit.network,
            .allocator = self.conduit.allocator,
            .origin_type = self.origin_type,
            .uuid = self.uuid,
            .request_id = self.request_id,
        };
        defer ctx.deinit();
        ctx.sendOutput(success, message);
    }
};

fn allocateState(
    conduit: *Conduit,
    kind: TaskKind,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !*WorldLifecycleTask {
    const allocator = conduit.allocator;
    const state = try allocator.create(WorldLifecycleTask);
    errdefer allocator.destroy(state);

    const origin_copy = try allocator.dupe(u8, origin_type);
    errdefer allocator.free(origin_copy);
    const request_copy = try allocator.dupe(u8, request_id);
    errdefer allocator.free(request_copy);

    state.* = .{
        .conduit = conduit,
        .kind = kind,
        .name = name,
        .sender_runtime_id = if (sender) |player| player.entity.runtime_id else null,
        .origin_type = origin_copy,
        .uuid = uuid,
        .request_id = request_copy,
        .stage = if (kind == .unload) .wait_idle else .build,
    };
    return state;
}

fn freeStateContainer(conduit: *Conduit, state: *WorldLifecycleTask) void {
    conduit.allocator.free(state.origin_type);
    conduit.allocator.free(state.request_id);
    conduit.allocator.destroy(state);
}

fn queueBuild(
    conduit: *Conduit,
    kind: TaskKind,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    const state = try allocateState(conduit, kind, name, sender, origin_type, uuid, request_id);
    errdefer freeStateContainer(conduit, state);
    try conduit.tasks.enqueue(.{
        .func = runTask,
        .ctx = @ptrCast(state),
        .name = TASK_NAME,
        .cleanup = destroyTask,
    });
}

pub fn queueCreate(
    conduit: *Conduit,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    return queueBuild(conduit, .create, name, sender, origin_type, uuid, request_id);
}

pub fn queueLoad(
    conduit: *Conduit,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    return queueBuild(conduit, .load, name, sender, origin_type, uuid, request_id);
}

pub fn queueUnload(
    conduit: *Conduit,
    world: *World,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    const state = try allocateState(conduit, .unload, name, sender, origin_type, uuid, request_id);
    errdefer freeStateContainer(conduit, state);
    state.world = world;
    try conduit.tasks.enqueue(.{
        .func = runTask,
        .ctx = @ptrCast(state),
        .name = TASK_NAME,
        .cleanup = destroyTask,
    });
}

fn destroyTask(ctx: *anyopaque) void {
    const state: *WorldLifecycleTask = @ptrCast(@alignCast(ctx));
    if (state.world) |world| {
        if (state.kind == .unload) world.save();
        world.deinit();
        state.conduit.allocator.destroy(world);
    }
    _ = state.conduit.world_ops.remove(state.name);
    state.conduit.allocator.free(state.name);
    freeStateContainer(state.conduit, state);
}

fn runTask(ctx: *anyopaque) bool {
    const state: *WorldLifecycleTask = @ptrCast(@alignCast(ctx));
    return switch (state.kind) {
        .create, .load => runBuildTask(state),
        .unload => runUnloadTask(state),
    };
}

fn buildVerb(kind: TaskKind) []const u8 {
    return switch (kind) {
        .create => "create",
        .load => "load",
        .unload => "unload",
    };
}

fn builtVerb(kind: TaskKind) []const u8 {
    return switch (kind) {
        .create => "created",
        .load => "loaded",
        .unload => "unloaded",
    };
}

fn runBuildTask(state: *WorldLifecycleTask) bool {
    switch (state.stage) {
        .build => {
            const world = state.conduit.buildWorld(state.name) catch |err| {
                var buf: [192]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &buf,
                    "Failed to {s} world '{s}': {s}",
                    .{ buildVerb(state.kind), state.name, @errorName(err) },
                ) catch "Failed to build world";
                state.reply(false, message);
                return true;
            };
            state.world = world;
            state.stage = .register;
            return false;
        },
        .register => {
            const world = state.world orelse return true;
            state.conduit.worlds.put(world.identifier, world) catch |err| {
                var buf: [192]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &buf,
                    "Failed to {s} world '{s}': {s}",
                    .{ buildVerb(state.kind), state.name, @errorName(err) },
                ) catch "Failed to build world";
                state.reply(false, message);
                return true;
            };

            state.world = null;
            state.stage = .finish;
            return false;
        },
        .finish => {
            state.conduit.refreshWorldCommandEnums();
            var buf: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "World '{s}' {s}", .{ state.name, builtVerb(state.kind) }) catch "World ready";
            state.reply(true, message);
            return true;
        },
        else => return true,
    }
}

fn runUnloadTask(state: *WorldLifecycleTask) bool {
    switch (state.stage) {
        .wait_idle => {
            const world = state.world orelse return true;
            if (state.abandoned) {
                if (world.hasInflightBatches()) return false;
                state.stage = .save_destroy;
                return false;
            }
            if (world.hasInflightBatches()) {
                state.ticks_waited += 1;
                if (state.ticks_waited < UNLOAD_IDLE_TIMEOUT_TICKS) return false;

                state.conduit.worlds.put(world.identifier, world) catch |err| {
                    Raknet.Logger.ERROR("Failed to restore world '{s}' after unload timeout: {any}", .{ state.name, err });
                    state.abandoned = true;
                    state.reply(false, "Failed to unload world: dimensions still busy");
                    return false;
                };
                world.unloading = false;
                state.world = null;
                state.reply(false, "Failed to unload world: dimensions still busy");
                return true;
            }
            state.stage = .save_destroy;
            return false;
        },
        .save_destroy => {
            const world = state.world orelse return true;
            world.save();
            state.conduit.destroyWorld(world);
            state.conduit.refreshFloatingTextCommandEnums();
            state.world = null;
            if (state.abandoned) return true;
            state.stage = .finish;
            return false;
        },
        .finish => {
            state.conduit.refreshWorldCommandEnums();
            var buf: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "World '{s}' unloaded", .{state.name}) catch "World unloaded";
            state.reply(true, message);
            return true;
        },
        else => return true,
    }
}
