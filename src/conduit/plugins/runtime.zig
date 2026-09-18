const std = @import("std");
const builtin = @import("builtin");

const Conduit = @import("../conduit.zig").Conduit;
const Events = @import("../events/root.zig");
const World = @import("../world/world.zig").World;
const abi = @import("abi.zig");
const NativePlugin = @import("dynamic_loader.zig").NativePlugin;

const native_io = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn OutputDebugStringA(message: [*:0]const u8) callconv(.winapi) void;
} else struct {
    extern "c" fn write(fd: c_int, buffer: [*]const u8, length: usize) isize;
};

var active_runtime: ?*PluginRuntime = null;

pub const PluginRuntime = struct {
    allocator: std.mem.Allocator,
    conduit: ?*Conduit = null,
    events: ?*Events.Events = null,
    host: abi.HostApi,
    plugins: std.ArrayList(NativePlugin),
    plugin_labels: std.ArrayList(PluginLabel),
    subscriptions: std.ArrayList(Subscription),
    bridges: [17][3]bool,
    next_id: u32 = 1,
    next_subscription: u64 = 1,
    discovery_error_count: usize = 0,
    dispatching: bool = false,

    pub const NATIVE_BRIDGE_OWNER_ID: u16 = 0xC001;

    const PluginLabel = struct {
        id: u32,
        name: []u8,
    };

    const Subscription = struct {
        id: u64,
        event_id: u32,
        phase: u32,
        priority: i16,
        callback: abi.EventCallbackFn,
        userdata: ?*anyopaque,
        active: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator) PluginRuntime {
        var runtime = PluginRuntime{
            .allocator = allocator,
            .host = undefined,
            .plugins = .empty,
            .plugin_labels = .empty,
            .subscriptions = .empty,
            .bridges = std.mem.zeroes([17][3]bool),
        };
        runtime.host = .{
            .struct_size = @sizeOf(abi.HostApi),
            .api = .{ .major = abi.abi_major, .minor = abi.abi_minor, .protocol = 0 },
            .userdata = null,
            .allocator = .{ .userdata = null, .alloc = allocate, .free = free },
            .log = log,
            .world_find = worldFind,
            .player_snapshot = playerSnapshot,
            .world_set_block = worldSetBlock,
            .event_subscribe = eventSubscribe,
            .event_unsubscribe = eventUnsubscribe,
            .features = abi.feature_events | abi.feature_world | abi.feature_logging | abi.feature_allocator,
            .log_debug = logDebug,
            .log_info = logInfo,
            .log_warn = logWarn,
            .log_error = logError,
        };
        return runtime;
    }

    pub fn attach(self: *PluginRuntime, conduit: *Conduit, events: *Events.Events, protocol: u32) void {
        self.conduit = conduit;
        self.events = events;
        self.host.userdata = @ptrCast(self);
        self.host.allocator.userdata = @ptrCast(self);
        self.host.api.protocol = protocol;
        active_runtime = self;
    }

    pub fn discover(self: *PluginRuntime, io: std.Io, protocol: u32) void {
        const directory = std.Io.Dir.cwd().openDir(io, "plugins", .{ .iterate = true }) catch |err| {
            std.Io.Dir.cwd().createDir(io, "plugins", .default_dir) catch {};
            if (err != error.FileNotFound) std.log.warn("Unable to open plugins directory: {s}", .{@errorName(err)});
            return;
        };
        var plugins_dir = directory;
        defer plugins_dir.close(io);
        var iterator = plugins_dir.iterate();

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }

        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file or !isPluginFile(entry.name)) continue;
            const name = self.allocator.dupe(u8, entry.name) catch {
                std.log.err("Unable to allocate plugin name for {s}", .{entry.name});
                continue;
            };
            names.append(self.allocator, name) catch {
                self.allocator.free(name);
                std.log.err("Unable to register plugin name for {s}", .{entry.name});
            };
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);

        for (names.items) |name| {
            const path = std.fmt.allocPrint(self.allocator, "plugins/{s}", .{name}) catch {
                std.log.err("Unable to allocate plugin path for {s}", .{name});
                continue;
            };
            defer self.allocator.free(path);
            self.load(path, protocol);
        }
    }

    pub fn deinit(self: *PluginRuntime) void {
        if (self.events) |events| events.removeOwner(NATIVE_BRIDGE_OWNER_ID);
        var index = self.plugins.items.len;
        while (index > 0) {
            index -= 1;
            self.plugins.items[index].deinit();
        }
        self.plugins.deinit(self.allocator);
        for (self.plugin_labels.items) |label| self.allocator.free(label.name);
        self.plugin_labels.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
        self.events = null;
        self.conduit = null;
        if (active_runtime == self) active_runtime = null;
    }

    pub fn count(self: *const PluginRuntime) usize {
        return self.plugins.items.len;
    }

    fn load(self: *PluginRuntime, path: []const u8, protocol: u32) void {
        const plugin_id = self.next_id;
        var plugin = NativePlugin.open(self.allocator, path, &self.host, plugin_id, protocol) catch |err| {
            self.discovery_error_count += 1;
            std.log.err("Unable to load plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };

        self.next_id += 1;
        const label = self.allocator.dupe(u8, abi.metadataName(plugin.descriptor)) catch {
            self.discovery_error_count += 1;
            plugin.deinit();
            std.log.err("Unable to allocate plugin label for {s}", .{path});
            return;
        };

        self.plugin_labels.append(self.allocator, .{ .id = plugin_id, .name = label }) catch {
            self.allocator.free(label);
            self.discovery_error_count += 1;
            plugin.deinit();
            std.log.err("Unable to register plugin label for {s}", .{path});
            return;
        };

        std.log.info("Loading native plugin: {s}", .{path});
        plugin.start() catch |err| {
            plugin.deinit();
            std.log.err("Unable to start plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };

        self.plugins.append(self.allocator, plugin) catch |err| {
            plugin.deinit();
            std.log.err("Unable to register plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };
    }

    fn eventSubscribe(context: ?*anyopaque, event_id: u32, phase: u32, priority: i16, callback: abi.EventCallbackFn, userdata: ?*anyopaque, subscription: *u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        if (event_id >= 17 or phase >= 3 or self.dispatching) return -1;
        self.ensureBridge(event_id, phase) catch return -2;

        const id = self.next_subscription;
        self.next_subscription += 1;
        const item = Subscription{
            .id = id,
            .event_id = event_id,
            .phase = phase,
            .priority = priority,
            .callback = callback,
            .userdata = userdata,
        };

        var index: usize = 0;
        while (index < self.subscriptions.items.len and self.subscriptions.items[index].priority >= priority) : (index += 1) {}
        self.subscriptions.insert(self.allocator, index, item) catch return -3;
        subscription.* = id;
        return 0;
    }

    fn eventUnsubscribe(context: ?*anyopaque, subscription: u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        for (self.subscriptions.items) |*item| {
            if (item.id == subscription and item.active) {
                item.active = false;
                return 0;
            }
        }
        return -1;
    }

    fn ensureBridge(self: *PluginRuntime, event_id: u32, phase: u32) !void {
        if (self.bridges[event_id][phase]) return;
        const events = self.events orelse return error.EventBusUnavailable;
        const event: Events.Event = @enumFromInt(event_id);
        const event_phase: Events.EventPhase = @enumFromInt(phase);
        switch (event) {
            inline else => |tag| {
                switch (event_phase) {
                    .pre => _ = try events.subscribe(tag, .pre, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag)),
                    .commit => _ = try events.subscribe(tag, .commit, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag)),
                    .post => _ = try events.subscribe(tag, .post, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag)),
                }
            },
        }
        self.bridges[event_id][phase] = true;
    }

    fn bridgeCallback(comptime event: Events.Event) *const fn (*Events.EventContext, *Events.Event.DataType(event)) Events.EventResult {
        return struct {
            fn callback(context: *Events.EventContext, data: *Events.Event.DataType(event)) Events.EventResult {
                const runtime = active_runtime orelse return .continue_;
                return runtime.dispatch(event, context, data);
            }
        }.callback;
    }

    fn dispatch(self: *PluginRuntime, comptime event: Events.Event, context: *Events.EventContext, data: *Events.Event.DataType(event)) Events.EventResult {
        const event_id = @intFromEnum(event);
        const phase = @intFromEnum(context.phase);
        self.dispatching = true;
        defer self.dispatching = false;

        var result: u32 = @intFromEnum(abi.EventResult.continue_);
        var payload: abi.ServerTickEvent = undefined;
        var player_payload: abi.PlayerEvent = undefined;
        var payload_ptr: ?*const anyopaque = null;
        var payload_size: usize = 0;
        if (event == .ServerTick) {
            payload.tick = data.tick;
            payload_ptr = @ptrCast(&payload);
            payload_size = @sizeOf(abi.ServerTickEvent);
        } else if (event == .PlayerJoin or event == .PlayerDisconnect) {
            player_payload.handle = @intFromPtr(data.player);
            payload_ptr = @ptrCast(&player_payload);
            payload_size = @sizeOf(abi.PlayerEvent);
        }

        const payload_version: u32 = if (event == .ServerTick or event == .PlayerJoin or event == .PlayerDisconnect) 1 else 0;
        const view = abi.EventView{ .event_id = event_id, .phase = phase, .data = payload_ptr, .data_size = payload_size, .result = &result, .payload_version = payload_version };
        for (self.subscriptions.items) |subscription| {
            if (!subscription.active or subscription.event_id != event_id or subscription.phase != phase) continue;
            subscription.callback(subscription.userdata, &view);
            if (result != @intFromEnum(abi.EventResult.continue_)) return .cancel;
        }
        return .continue_;
    }

    fn isPluginFile(name: []const u8) bool {
        if (builtin.os.tag == .windows) return std.mem.endsWith(u8, name, ".dll");
        if (builtin.os.tag == .macos) return std.mem.endsWith(u8, name, ".dylib");
        return std.mem.endsWith(u8, name, ".so");
    }

    fn allocate(context: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        return self.allocator.rawAlloc(size, .fromByteUnits(@max(alignment, 1)), @returnAddress());
    }

    fn free(context: ?*anyopaque, memory: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        const ptr = memory orelse return;
        self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..size], .fromByteUnits(@max(alignment, 1)), @returnAddress());
    }

    fn log(context: ?*anyopaque, level: u32, message: abi.StringView) callconv(.c) void {
        const label = switch (level) {
            0 => "DEBUG",
            1 => "INFO",
            2 => "WARN",
            else => "ERROR",
        };
        writePluginLog(context, 0, label, message);
    }

    fn logDebug(context: ?*anyopaque, plugin_id: u32, message: abi.StringView) callconv(.c) void {
        writePluginLog(context, plugin_id, "DEBUG", message);
    }

    fn logInfo(context: ?*anyopaque, plugin_id: u32, message: abi.StringView) callconv(.c) void {
        writePluginLog(context, plugin_id, "INFO", message);
    }

    fn logWarn(context: ?*anyopaque, plugin_id: u32, message: abi.StringView) callconv(.c) void {
        writePluginLog(context, plugin_id, "WARN", message);
    }

    fn logError(context: ?*anyopaque, plugin_id: u32, message: abi.StringView) callconv(.c) void {
        writePluginLog(context, plugin_id, "ERROR", message);
    }

    fn writePluginLog(context: ?*anyopaque, plugin_id: u32, level: []const u8, message: abi.StringView) void {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return));
        const text = message.data orelse return;
        const name = for (self.plugin_labels.items) |label| {
            if (label.id == plugin_id) break label.name;
        } else "unknown";
        var buffer: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "[plugin:{s}] [{s}] {s}\n", .{ name, level, text[0..message.length] }) catch return;
        if (builtin.os.tag == .windows) {
            buffer[formatted.len] = 0;
            native_io.OutputDebugStringA(buffer[0..formatted.len :0].ptr);
        } else {
            _ = native_io.write(2, formatted.ptr, formatted.len);
        }
    }

    fn worldFind(context: ?*anyopaque, name: abi.StringView, handle: *u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        const conduit = self.conduit orelse return -1;
        const world = conduit.getWorld(name.slice()) orelse return -1;
        handle.* = @intFromPtr(world);
        return 0;
    }

    fn playerSnapshot(_: ?*anyopaque, _: u64, _: ?*anyopaque, _: usize) callconv(.c) i32 {
        return -3;
    }

    fn worldSetBlock(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, x: i32, y: i32, z: i32, block: abi.StringView) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        const conduit = self.conduit orelse return -1;
        const world = findWorldByHandle(conduit, world_handle) orelse return -1;
        const dimension_value = world.getDimension(dimension.slice()) orelse return -2;
        const permutation = @import("../world/block/block-permutation.zig").BlockPermutation.resolve(self.allocator, block.slice(), null) catch return -3;
        dimension_value.setPermutation(.{ .x = x, .y = y, .z = z }, permutation, 0) catch return -3;
        return 0;
    }

    fn findWorldByHandle(conduit: *Conduit, handle: u64) ?*World {
        var worlds = conduit.worlds.valueIterator();
        while (worlds.next()) |world| {
            if (@intFromPtr(world.*) == handle) return world.*;
        }
        return null;
    }
};
