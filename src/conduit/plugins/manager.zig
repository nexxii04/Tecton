const std = @import("std");
const Conduit = @import("../conduit.zig").Conduit;
const Events = @import("../events/root.zig");
const api = @import("api.zig");
const HandleRegistry = @import("handles.zig").HandleRegistry;
const Player = @import("../player/player.zig").Player;

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    conduit: ?*Conduit = null,
    plugins: std.ArrayList(LoadedPlugin),
    handles: HandleRegistry,
    host: api.HostApi,
    next_id: api.PluginId = 1,

    const LoadedPlugin = struct {
        id: api.PluginId,
        descriptor: api.PluginDescriptor,
        manifest: api.PluginManifest,
        context: api.PluginContext,
        state: api.PluginState = .discovered,
    };

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        var manager = PluginManager{
            .allocator = allocator,
            .plugins = .empty,
            .handles = HandleRegistry.init(allocator),
            .host = undefined,
        };
        manager.host = .{
            .api = .{ .protocol = 0 },
            .userdata = @ptrCast(&manager),
            .allocator = .{
                .userdata = @ptrCast(&manager),
                .allocFn = allocatePluginMemory,
                .freeFn = freePluginMemory,
            },
            .core_allocator = undefined,
            .io = undefined,
            .max_players = 0,
            .worldSetBlockFn = hostWorldSetBlock,
            .logFn = hostLog,
            .playerSnapshotFn = hostPlayerSnapshot,
            .worldFindFn = hostWorldFind,
            .scheduleFn = hostSchedule,
        };
        return manager;
    }

    pub fn attach(self: *PluginManager, conduit: *Conduit, events: *Events.Events, protocol: u32) void {
        self.conduit = conduit;
        self.host.userdata = @ptrCast(self);
        self.host.allocator.userdata = @ptrCast(self);
        self.host.api.protocol = protocol;
        self.host.core_allocator = self.allocator;
        self.host.io = conduit.io;
        self.host.max_players = conduit.config.max_players;
        self.host.events = events;
        var worlds = conduit.worlds.valueIterator();
        while (worlds.next()) |world| {
            _ = self.handles.insert(.world, @ptrCast(world.*)) catch {};
        }
    }

    pub fn deinit(self: *PluginManager) void {
        self.stopAll(.shutdown);
        self.plugins.deinit(self.allocator);
        self.handles.deinit();
    }

    pub fn register(self: *PluginManager, descriptor: api.PluginDescriptor) !api.PluginId {
        const manifest = descriptor.manifest();
        if (manifest.api.major != api.api_major or manifest.api.protocol != self.host.api.protocol) {
            return error.IncompatiblePlugin;
        }
        if (manifest.name.len == 0) return error.InvalidManifest;
        for (self.plugins.items) |plugin| {
            if (std.mem.eql(u8, plugin.manifest.name, manifest.name)) return error.DuplicatePlugin;
        }

        const id = self.next_id;
        self.next_id += 1;
        try self.plugins.append(self.allocator, .{
            .id = id,
            .descriptor = descriptor,
            .manifest = manifest,
            .context = .{
                .host = &self.host,
                .plugin_id = id,
                .allocator = self.host.allocator,
            },
        });
        self.plugins.items[self.plugins.items.len - 1].state = .validated;
        return id;
    }

    pub fn startAll(self: *PluginManager) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (plugin.state != .validated) continue;
            if (!self.dependenciesReady(plugin.manifest.dependencies)) {
                plugin.state = .disabled;
                logPlugin(plugin, "disabled because a dependency is unavailable");
                continue;
            }
            plugin.descriptor.init(&plugin.context) catch |err| {
                plugin.state = .failed;
                logPluginError(plugin, "init", err);
                _ = index;
                continue;
            };
            plugin.state = .initialized;
            plugin.descriptor.start() catch |err| {
                plugin.state = .failed;
                logPluginError(plugin, "start", err);
                plugin.descriptor.stop(.fault);
                continue;
            };
            plugin.state = .started;
        }
    }

    pub fn stopAll(self: *PluginManager, reason: api.StopReason) void {
        var index = self.plugins.items.len;
        while (index > 0) {
            index -= 1;
            const plugin = &self.plugins.items[index];
            if (plugin.state != .started and plugin.state != .initialized) continue;
            plugin.state = .stopping;
            if (self.host.events) |events| events.removeOwner(plugin.id);
            plugin.descriptor.stop(reason);
            plugin.state = .stopped;
        }
    }

    pub fn pluginCount(self: *const PluginManager) usize {
        return self.plugins.items.len;
    }

    pub fn registerPlayer(self: *PluginManager, player: *Player) void {
        _ = self.handles.insert(.player, @ptrCast(player)) catch {};
    }

    pub fn unregisterPlayer(self: *PluginManager, player: *Player) void {
        if (self.handles.findPtr(.player, @ptrCast(player))) |handle| self.handles.remove(handle);
    }

    fn dependenciesReady(self: *const PluginManager, dependencies: []const []const u8) bool {
        for (dependencies) |dependency| {
            var found = false;
            for (self.plugins.items) |plugin| {
                if (std.mem.eql(u8, plugin.manifest.name, dependency) and plugin.state == .started) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn allocatePluginMemory(ctx: *anyopaque, len: usize, _: u8) ?[*]u8 {
        const self: *PluginManager = @ptrCast(@alignCast(ctx));
        const memory = self.allocator.alloc(u8, len) catch return null;
        return memory.ptr;
    }

    fn freePluginMemory(ctx: *anyopaque, ptr: [*]u8, len: usize, _: u8) void {
        const self: *PluginManager = @ptrCast(@alignCast(ctx));
        self.allocator.free(ptr[0..len]);
    }

    fn hostLog(_: *anyopaque, level: api.LogLevel, message: api.StringView) void {
        const text = message.ptr[0..message.len];
        switch (level) {
            .debug => std.log.debug("[plugin] {s}", .{text}),
            .info => std.log.info("[plugin] {s}", .{text}),
            .warn => std.log.warn("[plugin] {s}", .{text}),
            .err => std.log.err("[plugin] {s}", .{text}),
        }
    }

    fn hostPlayerSnapshot(ctx: *anyopaque, handle: api.Handle, snapshot: *api.PlayerSnapshot) api.ApiError!void {
        const self: *PluginManager = @ptrCast(@alignCast(ctx));
        const ptr = self.handles.resolve(handle, .player) orelse return error.InvalidHandle;
        const player: *Player = @ptrCast(@alignCast(ptr));
        const dimension = player.entity.dimension orelse return error.InvalidHandle;
        snapshot.* = .{
            .handle = handle,
            .runtime_id = player.entity.runtime_id,
            .username = player.username,
            .world = dimension.world.identifier,
            .dimension = dimension.identifier,
        };
    }

    fn hostWorldFind(ctx: *anyopaque, name: api.StringView) ?api.Handle {
        const self: *PluginManager = @ptrCast(@alignCast(ctx));
        const conduit = self.conduit orelse return null;
        const requested = name.ptr[0..name.len];
        var worlds = conduit.worlds.valueIterator();
        while (worlds.next()) |world| {
            if (std.mem.eql(u8, world.*.identifier, requested)) {
                return self.handles.findPtr(.world, @ptrCast(world.*));
            }
        }
        return null;
    }

    fn hostSchedule(_: *anyopaque, _: u32, _: Events.Event, _: *anyopaque) api.ApiError!api.TaskHandle {
        return error.Unsupported;
    }

    fn hostWorldSetBlock(
        ctx: *anyopaque,
        world_name: api.StringView,
        dimension_name: api.StringView,
        position: @import("protocol").BlockPosition,
        identifier: api.StringView,
    ) api.ApiError!void {
        const self: *PluginManager = @ptrCast(@alignCast(ctx));
        const conduit = self.conduit orelse return error.Unsupported;
        const world = conduit.getWorld(world_name.ptr[0..world_name.len]) orelse return error.WrongWorld;
        const dimension = world.getDimension(dimension_name.ptr[0..dimension_name.len]) orelse return error.WrongWorld;
        const permutation = @import("../world/block/block-permutation.zig").BlockPermutation.resolve(
            conduit.allocator,
            identifier.ptr[0..identifier.len],
            null,
        ) catch return error.Unsupported;
        dimension.setPermutation(position, permutation, 0) catch return error.Unsupported;
    }

    fn logPlugin(plugin: *const LoadedPlugin, message: []const u8) void {
        std.log.warn("Plugin {s}: {s}", .{ plugin.manifest.name, message });
    }

    fn logPluginError(plugin: *const LoadedPlugin, phase: []const u8, err: anyerror) void {
        std.log.err("Plugin {s} {s} failed: {s}", .{ plugin.manifest.name, phase, @errorName(err) });
    }
};
