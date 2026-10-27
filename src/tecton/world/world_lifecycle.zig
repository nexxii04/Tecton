const std = @import("std");
const log = @import("../core/log.zig");
const Host = @import("../player/player.zig").Host;
const World = @import("./world.zig").World;
const Player = @import("../player/player.zig").Player;

pub const TaskKind = enum { create, load, unload };

const Stage = enum { build, register, wait_idle, save_destroy, finish };

const UNLOAD_IDLE_TIMEOUT_TICKS: u32 = 400;
const TASK_NAME = "world_lifecycle";

const WorldLifecycleTask = struct {
    tecton: Host,
    kind: TaskKind,
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
        self.tecton.replyTo(self.sender_runtime_id, self.origin_type, self.uuid, self.request_id, success, message);
    }
};

fn allocateState(
    tecton: Host,
    kind: TaskKind,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !*WorldLifecycleTask {
    const allocator = tecton.allocator;
    const state = try allocator.create(WorldLifecycleTask);
    errdefer allocator.destroy(state);

    const origin_copy = try allocator.dupe(u8, origin_type);
    errdefer allocator.free(origin_copy);
    const request_copy = try allocator.dupe(u8, request_id);
    errdefer allocator.free(request_copy);

    state.* = .{
        .tecton = tecton,
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

fn freeStateContainer(tecton: Host, state: *WorldLifecycleTask) void {
    tecton.allocator.free(state.origin_type);
    tecton.allocator.free(state.request_id);
    tecton.allocator.destroy(state);
}

fn queueBuild(
    tecton: Host,
    kind: TaskKind,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    const state = try allocateState(tecton, kind, name, sender, origin_type, uuid, request_id);
    errdefer freeStateContainer(tecton, state);
    try tecton.tasks.enqueue(.{
        .func = runTask,
        .ctx = @ptrCast(state),
        .name = TASK_NAME,
        .cleanup = destroyTask,
    });
}

pub fn queueCreate(
    tecton: Host,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    return queueBuild(tecton, .create, name, sender, origin_type, uuid, request_id);
}

pub fn queueLoad(
    tecton: Host,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    return queueBuild(tecton, .load, name, sender, origin_type, uuid, request_id);
}

pub fn queueUnload(
    tecton: Host,
    world: *World,
    name: []u8,
    sender: ?*Player,
    origin_type: []const u8,
    uuid: [16]u8,
    request_id: []const u8,
) !void {
    const state = try allocateState(tecton, .unload, name, sender, origin_type, uuid, request_id);
    errdefer freeStateContainer(tecton, state);
    state.world = world;
    try tecton.tasks.enqueue(.{
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
        state.tecton.allocator.destroy(world);
    }
    state.tecton.worlds.endOp(state.name);
    state.tecton.allocator.free(state.name);
    freeStateContainer(state.tecton, state);
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
            const world = state.tecton.worlds.build(state.name) catch |err| {
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
            state.tecton.worlds.adopt(world) catch |err| {
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
            state.tecton.refreshWorldCommandEnums();
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

                state.tecton.worlds.adopt(world) catch |err| {
                    log.err("Failed to restore world '{s}' after unload timeout: {any}", .{ state.name, err });
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
            state.tecton.worlds.destroy(world);
            state.tecton.refreshFloatingTextCommandEnums();
            state.world = null;
            if (state.abandoned) return true;
            state.stage = .finish;
            return false;
        },
        .finish => {
            state.tecton.refreshWorldCommandEnums();
            var buf: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "World '{s}' unloaded", .{state.name}) catch "World unloaded";
            state.reply(true, message);
            return true;
        },
        else => return true,
    }
}
