const std = @import("std");
const logger = @import("../core/log.zig");
const builtin = @import("builtin");

const Tecton = @import("../tecton.zig").Tecton;
const Events = @import("../events/root.zig");
const World = @import("../world/world.zig").World;
const abi = @import("abi.zig");
const native_loader = @import("dynamic_loader.zig");
const NativePlugin = native_loader.NativePlugin;
const Handles = @import("handles.zig");
const TaskQueue = @import("../tasks/tasks.zig").TaskQueue;
const SendPriority = @import("../network/root.zig").SendPriority;
const Player = @import("../player/player.zig").Player;
const Entity = @import("../entity/entity.zig").Entity;
const EntityType = @import("../entity/entity_type.zig").EntityType;
const Dimension = @import("../world/dimension/dimension.zig").Dimension;
const entities_mod = @import("../world/dimension/entities.zig");

const MAX_PLUGIN_PACKET_BYTES: usize = 1 << 20;
const event_count = std.meta.fields(Events.Event).len;

pub const PluginState = enum(u8) {
    unloaded,
    loading,
    loaded,
    starting,
    running,
    stopping,
    failed,
};

pub const PluginRuntime = struct {
    allocator: std.mem.Allocator,
    tecton: ?*Tecton = null,
    events: ?*Events.Events = null,
    host: abi.HostApi,
    handles: Handles.Table,
    plugins: std.ArrayList(*HostSlot),
    slots: std.ArrayList(?*HostSlot),
    buckets: [event_count][3]std.ArrayList(Subscription),
    active: [event_count][3]u32,
    dead: [event_count][3]u32,
    bridges: [event_count][3]bool,
    bridge_priority: [event_count][3]i16,
    bridge_refresh: [event_count][3]bool = std.mem.zeroes([event_count][3]bool),
    bridge_refresh_total: u32 = 0,
    bridge_total: u32 = 0,
    dirty: [event_count][3]bool = std.mem.zeroes([event_count][3]bool),
    dirty_total: u32 = 0,
    pending_unloads: std.ArrayList(u32),
    unload_all_pending: bool = false,
    unload_all_reason: abi.ShutdownReason = .normal,
    tasks: ?*TaskQueue = null,
    dead_total: u32 = 0,
    next_id: u32 = 1,
    next_subscription: u64 = 1,
    next_order: u64 = 1,
    depth: u32 = 0,
    in_emit: bool = false,
    discovery_error_count: usize = 0,
    server_state: u32 = 0,
    next_task: u64 = 1,
    scheduled_tasks: std.ArrayList(*ScheduledTask),
    core_api: abi.CoreApi,
    scheduler_api: abi.SchedulerApi,
    world_api: abi.WorldApi,
    players_api: abi.PlayersApi,
    entities_api: abi.EntitiesApi,
    items_api: abi.ItemsApi,
    blocks_api: abi.BlocksApi,
    inventories_api: abi.InventoriesApi,
    network_api: abi.NetworkApi,

    pub const NATIVE_BRIDGE_OWNER_ID: u16 = 0xC001;

    pub const HostSlot = struct {
        runtime: *PluginRuntime,
        plugin_id: u32,
        state: PluginState = .unloaded,
        owns_handles: u32 = Handles.none,
        events_dispatched: u64 = 0,
        tasks_run: u64 = 0,
        host: abi.HostApi = undefined,
        name: []const u8 = "",
        load_reason: u32 = abi.load_ok,
        native: ?*NativePlugin = null,
    };

    const ScheduledTask = struct {
        runtime: *PluginRuntime,
        plugin_id: u32,
        timer_id: u64,
        callback: abi.SchedulerCallbackFn,
        userdata: ?*anyopaque,
        cancelled: bool = false,
    };

    const Subscription = struct {
        subscription_id: u64,
        order: u64,
        callback: abi.EventCallbackFn,
        userdata: ?*anyopaque,
        plugin_id: u32,
        priority: i16,
        slot: ?*HostSlot = null,
        active: bool = true,
        pending: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) PluginRuntime {
        var runtime = PluginRuntime{
            .allocator = allocator,
            .host = undefined,
            .handles = Handles.Table.init(allocator),
            .plugins = .empty,
            .slots = .empty,
            .buckets = undefined,
            .active = std.mem.zeroes([event_count][3]u32),
            .dead = std.mem.zeroes([event_count][3]u32),
            .bridges = std.mem.zeroes([event_count][3]bool),
            .bridge_priority = std.mem.zeroes([event_count][3]i16),
            .pending_unloads = .empty,
            .scheduled_tasks = .empty,
            .core_api = undefined,
            .scheduler_api = undefined,
            .world_api = undefined,
            .players_api = undefined,
            .entities_api = undefined,
            .items_api = undefined,
            .blocks_api = undefined,
            .inventories_api = undefined,
            .network_api = undefined,
        };
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                runtime.buckets[event_index][phase] = .empty;
                runtime.bridge_priority[event_index][phase] = std.math.minInt(i16);
            }
        }
        runtime.core_api = .{
            .header = .{ .struct_size = @sizeOf(abi.CoreApi), .major = 1, .minor = 0, .interface_id = abi.interface_core, .reserved = 0, .features = 0 },
            .get_tick = coreGetTick,
            .get_state = coreGetState,
        };
        runtime.world_api = .{
            .header = .{ .struct_size = @sizeOf(abi.WorldApi), .major = 1, .minor = 0, .interface_id = abi.interface_world, .reserved = 0, .features = 0 },
            .find = worldFind,
            .get_snapshot = worldGetSnapshot,
            .set_block = worldSetBlock,
        };
        runtime.players_api = .{
            .header = .{ .struct_size = @sizeOf(abi.PlayersApi), .major = 1, .minor = 0, .interface_id = abi.interface_players, .reserved = 0, .features = 0 },
            .count = playersCount,
            .get_snapshot = playersGetSnapshot,
        };
        runtime.entities_api = .{
            .header = .{ .struct_size = @sizeOf(abi.EntitiesApi), .major = 1, .minor = 0, .interface_id = abi.interface_entities, .reserved = 0, .features = 0 },
            .count = entitiesCount,
            .get_snapshot = entitiesGetSnapshot,
        };
        runtime.items_api = .{
            .header = .{ .struct_size = @sizeOf(abi.ItemsApi), .major = 1, .minor = 0, .interface_id = abi.interface_items, .reserved = 0, .features = 0 },
            .count = itemsCount,
            .get_snapshot = itemsGetSnapshot,
        };
        runtime.blocks_api = .{
            .header = .{ .struct_size = @sizeOf(abi.BlocksApi), .major = 1, .minor = 0, .interface_id = abi.interface_blocks, .reserved = 0, .features = 0 },
            .get_snapshot = blocksGetSnapshot,
        };
        runtime.inventories_api = .{
            .header = .{ .struct_size = @sizeOf(abi.InventoriesApi), .major = 1, .minor = 0, .interface_id = abi.interface_inventories, .reserved = 0, .features = 0 },
            .get_size = inventoryGetSize,
            .get_item = inventoryGetItem,
        };
        runtime.scheduler_api = .{
            .header = .{ .struct_size = @sizeOf(abi.SchedulerApi), .major = 1, .minor = 0, .interface_id = abi.interface_scheduler, .reserved = 0, .features = 0 },
            .schedule = schedulerSchedule,
            .cancel = schedulerCancel,
            .cancel_owner = schedulerCancelOwner,
        };
        runtime.network_api = .{
            .header = .{ .struct_size = @sizeOf(abi.NetworkApi), .major = 1, .minor = 0, .interface_id = abi.interface_network, .reserved = 0, .features = 0 },
            .send = networkSend,
            .broadcast = networkBroadcast,
        };
        runtime.host = .{
            .struct_size = @sizeOf(abi.HostApi),
            .abi_major = abi.abi_major,
            .abi_minor = abi.abi_minor,
            .plugin_id = 0,
            .userdata = null,
            .allocator = .{ .userdata = null, .alloc = allocate, .free = free, .realloc = reallocate, .alloc_zeroed = allocateZeroed },
            .log = log,
            .event_subscribe = eventSubscribe,
            .event_unsubscribe = eventUnsubscribe,
            .emit_custom = emitCustom,
            .get_interface = getInterface,
            .every = schedulerEvery,
            .features = abi.host_features,
        };
        return runtime;
    }

    pub fn attach(self: *PluginRuntime, tecton: *Tecton, events: *Events.Events) void {
        self.tecton = tecton;
        self.tasks = &tecton.tasks;
        self.attachEvents(events);
        self.server_state = 0;
    }

    pub fn attachEvents(self: *PluginRuntime, events: *Events.Events) void {
        if (self.events) |previous| previous.setIdleHook(null, null);
        self.events = events;
        events.setIdleHook(bridgeIdle, self);
    }

    pub fn discover(self: *PluginRuntime, io: std.Io, directory_path: []const u8) void {
        const directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
            std.Io.Dir.cwd().createDir(io, directory_path, .default_dir) catch {};
            if (err != error.FileNotFound) logger.warn("Unable to open plugins directory: {s}", .{@errorName(err)});
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
                logger.err("Unable to allocate plugin name for {s}", .{entry.name});
                continue;
            };
            names.append(self.allocator, name) catch {
                self.allocator.free(name);
                logger.err("Unable to register plugin name for {s}", .{entry.name});
            };
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);

        for (names.items) |name| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory_path, name }) catch {
                logger.err("Unable to allocate plugin path for {s}", .{name});
                continue;
            };
            defer self.allocator.free(path);
            self.loadPath(path);
        }

        self.readyAll();
    }

    pub fn deinit(self: *PluginRuntime) void {
        self.unloadAll(.server_exit);
        self.cancelAllScheduled();
        for (self.slots.items) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            self.teardownSlot(slot, .server_exit);
            if (slot.name.len > 0) self.allocator.free(slot.name);
            slot.state = .unloaded;
            self.allocator.destroy(slot);
        }
        self.slots.clearRetainingCapacity();
        if (self.events) |events| {
            events.setIdleHook(null, null);
            events.removeOwner(NATIVE_BRIDGE_OWNER_ID);
        }
        for (0..event_count) |event_index| {
            for (0..3) |phase| self.buckets[event_index][phase].deinit(self.allocator);
        }
        self.pending_unloads.deinit(self.allocator);
        self.plugins.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.handles.deinit();
        self.scheduled_tasks.deinit(self.allocator);
        self.tasks = null;
        self.events = null;
        self.tecton = null;
    }

    pub fn count(self: *const PluginRuntime) usize {
        return self.plugins.items.len;
    }

    pub fn failedCount(self: *const PluginRuntime) usize {
        var total: usize = 0;
        for (self.slots.items) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            if (slot.state == .failed) total += 1;
        }
        return total;
    }

    pub fn stateFor(self: *PluginRuntime, plugin_id: u32) ?PluginState {
        const slot = self.slotFor(plugin_id) orelse return null;
        return slot.state;
    }

    pub fn loadReasonFor(self: *PluginRuntime, plugin_id: u32) ?u32 {
        const slot = self.slotFor(plugin_id) orelse return null;
        return slot.load_reason;
    }

    pub fn setServerState(self: *PluginRuntime, state: u32) void {
        self.server_state = state;
        self.flushPendingUnloads();
    }

    pub fn notePlayerRemoved(self: *PluginRuntime, player: *Player) void {
        _ = self.handles.removePointer(.player, @intFromPtr(player));
    }

    pub fn noteEntityRemoved(self: *PluginRuntime, entity: *Entity) void {
        _ = self.handles.removePointer(.entity, @intFromPtr(entity));
    }

    pub fn unloadPlugin(self: *PluginRuntime, plugin_id: u32) void {
        if (plugin_id == 0) return;
        if (self.depth > 0) {
            self.pending_unloads.append(self.allocator, plugin_id) catch {};
            return;
        }
        const slot = self.slotFor(plugin_id) orelse return;
        self.unloadSlot(slot, .normal);
    }

    pub fn unloadAll(self: *PluginRuntime, reason: abi.ShutdownReason) void {
        if (self.depth > 0) {
            self.unload_all_pending = true;
            self.unload_all_reason = reason;
            return;
        }
        self.unload_all_pending = false;
        while (self.plugins.items.len > 0) {
            const slot = self.plugins.items[self.plugins.items.len - 1];
            self.unloadSlot(slot, reason);
        }
        self.pending_unloads.clearRetainingCapacity();
    }

    fn flushPendingUnloads(self: *PluginRuntime) void {
        if (self.depth > 0) return;
        while (self.pending_unloads.pop()) |plugin_id| {
            const slot = self.slotFor(plugin_id) orelse continue;
            self.unloadSlot(slot, .normal);
        }
        if (self.unload_all_pending) {
            self.unload_all_pending = false;
            self.unloadAll(self.unload_all_reason);
        }
    }

    pub fn loadPath(self: *PluginRuntime, path: []const u8) void {
        const slot = self.allocator.create(HostSlot) catch {
            self.discovery_error_count += 1;
            logger.err("Unable to allocate plugin slot for {s}", .{path});
            return;
        };
        slot.* = .{ .runtime = self, .plugin_id = self.next_id, .state = .loading, .host = self.host };
        slot.host.userdata = @ptrCast(slot);
        slot.host.plugin_id = slot.plugin_id;
        slot.host.allocator.userdata = @ptrCast(slot);

        self.registerLoadingSlot(slot) catch {
            self.discovery_error_count += 1;
            logger.err("Unable to allocate plugin slot for {s}", .{path});
            self.allocator.destroy(slot);
            return;
        };

        const native = self.allocator.create(NativePlugin) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "out_of_memory");
            return;
        };
        native.* = NativePlugin.open(self.allocator, path, &slot.host, slot.plugin_id) catch |err| {
            self.allocator.destroy(native);
            self.failSlot(slot, path, native_loader.reasonCode(err), @errorName(err));
            return;
        };
        slot.native = native;

        const label = self.allocator.dupe(u8, abi.metadataName(native.descriptor)) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "out_of_memory");
            return;
        };
        slot.name = label;

        for (self.plugins.items) |existing| {
            if (std.mem.eql(u8, existing.name, label)) {
                self.failSlot(slot, path, abi.load_duplicate_name, "duplicate_name");
                return;
            }
        }

        native.load() catch |err| {
            self.failSlot(slot, path, native_loader.reasonCode(err), @errorName(err));
            return;
        };
        slot.state = .loaded;

        slot.state = .starting;
        native.start() catch |err| {
            self.failSlot(slot, path, native_loader.reasonCode(err), @errorName(err));
            return;
        };

        slot.state = .running;
        self.plugins.append(self.allocator, slot) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "out_of_memory");
            return;
        };
        logger.info("Loading native plugin: {s}", .{path});
    }

    fn readyAll(self: *PluginRuntime) void {
        for (self.plugins.items) |slot| {
            if (slot.state != .running) continue;
            if (slot.native) |native| native.ready();
        }
    }

    fn registerLoadingSlot(self: *PluginRuntime, slot: *HostSlot) !void {
        try self.slots.ensureTotalCapacity(self.allocator, slot.plugin_id);
        self.slots.appendAssumeCapacity(slot);
        self.next_id += 1;
    }

    fn failSlot(self: *PluginRuntime, slot: *HostSlot, path: []const u8, reason: u32, reason_name: []const u8) void {
        self.removeFromPlugins(slot);
        self.teardownSlot(slot, .fault);
        slot.state = .failed;
        slot.load_reason = reason;
        self.discovery_error_count += 1;
        if (builtin.is_test) {
            logger.warn("Unable to load plugin {s}: {s} ({s})", .{ path, reason_name, native_loader.reasonNameCode(reason) });
        } else {
            logger.err("Unable to load plugin {s}: {s} ({s})", .{ path, reason_name, native_loader.reasonNameCode(reason) });
        }
    }

    fn removeFromPlugins(self: *PluginRuntime, slot: *HostSlot) void {
        for (self.plugins.items, 0..) |candidate, index| {
            if (candidate == slot) {
                _ = self.plugins.orderedRemove(index);
                return;
            }
        }
    }

    fn teardownSlot(self: *PluginRuntime, slot: *HostSlot, reason: abi.ShutdownReason) void {
        if (slot.native) |native| native.shutdown(reason);
        self.cancelTasksFor(slot.plugin_id);
        self.removeSubscriptions(slot.plugin_id);
        _ = self.handles.removeOwner(slot.plugin_id, &slot.owns_handles);
        if (slot.native) |native| {
            native.deinit();
            self.allocator.destroy(native);
            slot.native = null;
        }
    }

    fn unloadSlot(self: *PluginRuntime, slot: *HostSlot, reason: abi.ShutdownReason) void {
        if (slot.state == .unloaded or slot.state == .failed) return;
        slot.state = .stopping;
        self.teardownSlot(slot, reason);
        self.removeFromPlugins(slot);
        if (slot.plugin_id > 0 and slot.plugin_id <= self.slots.items.len) {
            self.slots.items[@intCast(slot.plugin_id - 1)] = null;
        }
        if (slot.name.len > 0) self.allocator.free(slot.name);
        slot.state = .unloaded;
        self.allocator.destroy(slot);
    }

    fn cancelTasksFor(self: *PluginRuntime, plugin_id: u32) void {
        if (self.tasks) |tasks| {
            tasks.drainByOwner("plugin", @intCast(plugin_id), null);
            return;
        }
        var index = self.scheduled_tasks.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scheduled_tasks.items[index].plugin_id != plugin_id) continue;
            const scheduled = self.scheduled_tasks.swapRemove(index);
            self.allocator.destroy(scheduled);
        }
    }

    fn removeSubscriptions(self: *PluginRuntime, plugin_id: u32) void {
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                var changed = false;
                for (self.buckets[event_index][phase].items) |*subscription| {
                    if (subscription.plugin_id != plugin_id or !subscription.active) continue;
                    subscription.active = false;
                    self.dead[event_index][phase] += 1;
                    self.dead_total += 1;
                    if (self.active[event_index][phase] > 0) self.active[event_index][phase] -= 1;
                    changed = true;
                }
                if (changed and self.depth == 0) self.compactBucket(event_index, phase, true);
            }
        }
    }

    fn slotFor(self: *PluginRuntime, plugin_id: u32) ?*HostSlot {
        if (plugin_id == 0) return null;
        const index = plugin_id - 1;
        if (index >= self.slots.items.len) return null;
        return self.slots.items[index];
    }

    fn eventSubscribe(context: ?*anyopaque, event_id: u32, phase: u16, priority: i16, callback: ?abi.EventCallbackFn, userdata: ?*anyopaque, subscription: ?*u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        if (phase >= 3) return abi.result_invalid_argument;
        const callback_value = callback orelse return abi.result_invalid_argument;
        const output = subscription orelse return abi.result_invalid_argument;
        const internal = internalEvent(event_id) orelse return abi.result_not_found;
        if (externalEventId(internal) == null) return abi.result_not_found;

        const event_index: usize = @intCast(event_id);
        const phase_index: usize = @intCast(phase);
        const id = self.next_subscription;
        self.next_subscription += 1;
        const deferred = self.depth > 0;
        const item = Subscription{
            .subscription_id = id,
            .order = self.next_order,
            .callback = callback_value,
            .userdata = userdata,
            .plugin_id = slot.plugin_id,
            .priority = priority,
            .slot = slot,
            .pending = deferred,
        };
        self.next_order += 1;

        var item_index: usize = undefined;
        if (deferred) {
            self.buckets[event_index][phase_index].append(self.allocator, item) catch {
                self.maybeRemoveEmptyBridge(event_index, phase_index);
                return abi.result_out_of_memory;
            };
            item_index = self.buckets[event_index][phase_index].items.len - 1;
            self.markDirty(event_index, phase_index);
        } else {
            var index: usize = 0;
            while (index < self.buckets[event_index][phase_index].items.len and self.buckets[event_index][phase_index].items[index].priority >= priority) : (index += 1) {}
            self.buckets[event_index][phase_index].insert(self.allocator, index, item) catch {
                self.maybeRemoveEmptyBridge(event_index, phase_index);
                return abi.result_out_of_memory;
            };
            item_index = index;
        }
        self.active[event_index][phase_index] += 1;
        self.ensureBridge(event_id, phase, priority) catch {
            self.active[event_index][phase_index] -= 1;
            self.buckets[event_index][phase_index].items[item_index].active = false;
            self.dead[event_index][phase_index] += 1;
            self.dead_total += 1;
            if (self.depth == 0) self.compactBucket(event_index, phase_index, true);
            return abi.result_unsupported;
        };
        output.* = id;
        return abi.result_ok;
    }

    fn eventUnsubscribe(context: ?*anyopaque, subscription: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        if (subscription == 0) return abi.result_invalid_argument;
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                for (self.buckets[event_index][phase].items) |*item| {
                    if (item.subscription_id != subscription or !item.active) continue;
                    if (item.plugin_id != slot.plugin_id) return abi.result_not_found;
                    item.active = false;
                    self.dead[event_index][phase] += 1;
                    self.dead_total += 1;
                    if (self.active[event_index][phase] > 0) self.active[event_index][phase] -= 1;
                    if (self.depth == 0) self.compactBucket(event_index, phase, true);
                    return abi.result_ok;
                }
            }
        }
        return abi.result_not_found;
    }

    fn ensureBridge(self: *PluginRuntime, event_id: u32, phase: u16, priority: i16) !void {
        const event_index: usize = @intCast(event_id);
        const phase_index: usize = @intCast(phase);
        if (event_index >= event_count or phase_index >= 3) return error.UnknownEvent;
        const events = self.events orelse return error.EventBusUnavailable;
        if (self.bridges[event_index][phase_index]) {
            if (priority <= self.bridge_priority[event_index][phase_index]) return;
            self.bridge_priority[event_index][phase_index] = priority;
        } else if (priority > self.bridge_priority[event_index][phase_index]) {
            self.bridge_priority[event_index][phase_index] = priority;
        }
        self.markBridgeRefresh(event_index, phase_index);
        if (self.depth > 0 or events.isEmitting()) return;
        try self.installBridge(event_index, phase_index);
    }

    fn installBridge(self: *PluginRuntime, event_index: usize, phase_index: usize) !void {
        const events = self.events orelse return error.EventBusUnavailable;
        if (self.active[event_index][phase_index] == 0) {
            self.removeBridge(event_index, phase_index);
            return;
        }
        if (self.bridges[event_index][phase_index]) self.uninstallBridgeListener(event_index, phase_index);
        const internal = internalEvent(@intCast(event_index)) orelse return error.UnknownEvent;
        const event_phase: Events.EventPhase = @enumFromInt(phase_index);
        switch (internal) {
            inline else => |tag| _ = try events.subscribeWithContext(tag, event_phase, self.bridge_priority[event_index][phase_index], NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag), self),
        }
        self.bridges[event_index][phase_index] = true;
        self.bridge_total += 1;
        self.clearBridgeRefresh(event_index, phase_index);
    }

    fn uninstallBridgeListener(self: *PluginRuntime, event_index: usize, phase_index: usize) void {
        if (!self.bridges[event_index][phase_index]) return;
        self.bridges[event_index][phase_index] = false;
        if (self.bridge_total > 0) self.bridge_total -= 1;
        const events = self.events orelse return;
        const internal = internalEvent(@intCast(event_index)) orelse return;
        const event_phase: Events.EventPhase = @enumFromInt(phase_index);
        switch (internal) {
            inline else => |tag| events.removeOwnerFor(tag, event_phase, NATIVE_BRIDGE_OWNER_ID),
        }
    }

    fn removeBridge(self: *PluginRuntime, event_index: usize, phase_index: usize) void {
        self.uninstallBridgeListener(event_index, phase_index);
        self.bridge_priority[event_index][phase_index] = std.math.minInt(i16);
        self.clearBridgeRefresh(event_index, phase_index);
    }

    fn markBridgeRefresh(self: *PluginRuntime, event_index: usize, phase_index: usize) void {
        if (self.bridge_refresh[event_index][phase_index]) return;
        self.bridge_refresh[event_index][phase_index] = true;
        self.bridge_refresh_total += 1;
    }

    fn clearBridgeRefresh(self: *PluginRuntime, event_index: usize, phase_index: usize) void {
        if (!self.bridge_refresh[event_index][phase_index]) return;
        self.bridge_refresh[event_index][phase_index] = false;
        if (self.bridge_refresh_total > 0) self.bridge_refresh_total -= 1;
    }

    fn refreshBridges(self: *PluginRuntime) void {
        if (self.depth > 0 or self.in_emit or self.bridge_refresh_total == 0) return;
        const events = self.events orelse return;
        if (events.isEmitting()) return;
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                if (!self.bridge_refresh[event_index][phase]) continue;
                self.installBridge(event_index, phase) catch {};
            }
        }
    }

    fn bridgeIdle(context: ?*anyopaque) void {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return));
        self.refreshBridges();
    }

    fn retireEmptyBridges(self: *PluginRuntime) void {
        if (self.in_emit) return;
        if (self.bridge_total == 0 and self.bridge_refresh_total == 0) return;
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                if (self.active[event_index][phase] != 0) continue;
                if (self.bridges[event_index][phase] or self.bridge_refresh[event_index][phase]) {
                    self.removeBridge(event_index, phase);
                }
            }
        }
    }

    fn maybeRemoveEmptyBridge(self: *PluginRuntime, event_index: usize, phase: usize) void {
        if (self.active[event_index][phase] != 0) return;
        if (self.depth != 0) return;
        self.removeBridge(event_index, phase);
    }

    fn markDirty(self: *PluginRuntime, event_index: usize, phase: usize) void {
        if (self.dirty[event_index][phase]) return;
        self.dirty[event_index][phase] = true;
        self.dirty_total += 1;
    }

    fn compactBucket(self: *PluginRuntime, event_index: usize, phase: usize, retire_bridge: bool) void {
        const dead = self.dead[event_index][phase];
        const dirty = self.dirty[event_index][phase];
        if (dead == 0 and !dirty) {
            if (retire_bridge and !self.in_emit and self.active[event_index][phase] == 0) {
                self.removeBridge(event_index, phase);
            }
            return;
        }
        const bucket = &self.buckets[event_index][phase];
        var write: usize = 0;
        for (bucket.items) |subscription| {
            if (!subscription.active) continue;
            var copy = subscription;
            copy.pending = false;
            bucket.items[write] = copy;
            write += 1;
        }
        bucket.shrinkRetainingCapacity(write);
        self.dead[event_index][phase] = 0;
        self.dead_total = if (self.dead_total >= dead) self.dead_total - dead else 0;
        if (dirty) {
            self.dirty[event_index][phase] = false;
            if (self.dirty_total > 0) self.dirty_total -= 1;
        }
        std.mem.sort(Subscription, bucket.items, {}, subscriptionBefore);
        const priority: i16 = if (bucket.items.len > 0) bucket.items[0].priority else std.math.minInt(i16);
        const priority_changed = priority != self.bridge_priority[event_index][phase];
        if (priority_changed) {
            self.bridge_priority[event_index][phase] = priority;
            self.markBridgeRefresh(event_index, phase);
        }
        if (!retire_bridge or self.in_emit) return;
        if (self.active[event_index][phase] == 0) {
            self.removeBridge(event_index, phase);
            return;
        }
        if ((priority_changed or !self.bridges[event_index][phase]) and self.depth == 0) {
            self.installBridge(event_index, phase) catch {};
        }
    }

    fn compactAll(self: *PluginRuntime) void {
        if (self.dead_total == 0 and self.dirty_total == 0) return;
        for (0..event_count) |event_index| {
            for (0..3) |phase| {
                if (self.dead[event_index][phase] != 0 or self.dirty[event_index][phase]) {
                    self.compactBucket(event_index, phase, false);
                }
            }
        }
    }

    fn subscriptionBefore(_: void, left: Subscription, right: Subscription) bool {
        if (left.priority != right.priority) return left.priority > right.priority;
        return left.order < right.order;
    }

    fn bridgeCallback(comptime event: Events.Event) *const fn (*Events.EventContext, *Events.Event.DataType(event)) Events.EventResult {
        return struct {
            fn callback(context: *Events.EventContext, data: *Events.Event.DataType(event)) Events.EventResult {
                const runtime_pointer = context.listener_userdata orelse return .continue_;
                const runtime: *PluginRuntime = @ptrCast(@alignCast(runtime_pointer));
                return runtime.dispatch(event, context, data);
            }
        }.callback;
    }

    fn dispatch(self: *PluginRuntime, comptime event: Events.Event, context: *Events.EventContext, data: *Events.Event.DataType(event)) Events.EventResult {
        const external_event_id = @intFromEnum(externalEventId(event) orelse return .continue_);
        const event_index: usize = external_event_id;
        const phase: usize = @intFromEnum(context.phase);

        var result: i32 = @intFromEnum(abi.EventResult.continue_);
        var payload: abi.ServerTickEvent = undefined;
        var player_payload: abi.PlayerEvent = undefined;
        var payload_ptr: ?*const anyopaque = null;
        var payload_size: usize = 0;
        if (event == .ServerTick) {
            payload.tick = data.tick;
            payload_ptr = @ptrCast(&payload);
            payload_size = @sizeOf(abi.ServerTickEvent);
        } else if (event == .PlayerJoin) {
            player_payload.handle = self.playerHandle(data.player);
            if (player_payload.handle != 0) {
                payload_ptr = @ptrCast(&player_payload);
                payload_size = @sizeOf(abi.PlayerEvent);
            }
        } else if (event == .PlayerDisconnect) {
            player_payload.handle = self.handles.handleFor(.player, @intFromPtr(data.player)) orelse 0;
            if (player_payload.handle != 0) {
                payload_ptr = @ptrCast(&player_payload);
                payload_size = @sizeOf(abi.PlayerEvent);
            }
        }

        const payload_version: u32 = if (event == .ServerTick or event == .PlayerJoin or event == .PlayerDisconnect) 1 else 0;
        const view = abi.EventView{
            .data = payload_ptr,
            .data_size = payload_size,
            .result = &result,
            .schema = (external_event_id << 8) | payload_version,
            .event_id = external_event_id,
            .phase = @intCast(phase),
            .flags = if (event == .ServerTick or event == .PlayerJoin or event == .PlayerDisconnect) abi.event_flag_cancelable | abi.event_flag_callback_only | abi.event_flag_borrowed else abi.event_flag_callback_only | abi.event_flag_borrowed,
        };

        const previous_emit = self.in_emit;
        self.in_emit = true;
        self.depth += 1;
        defer {
            self.depth -= 1;
            self.in_emit = previous_emit;
            if (self.depth == 0 and !self.in_emit) {
                self.compactAll();
                self.retireEmptyBridges();
                self.refreshBridges();
                self.flushPendingUnloads();
                self.retireEmptyBridges();
            }
        }

        const captured = self.buckets[event_index][phase].items.len;
        var index: usize = 0;
        while (index < captured) : (index += 1) {
            const subscription = self.buckets[event_index][phase].items[index];
            if (!subscription.active or subscription.pending) continue;
            if (subscription.slot) |slot| slot.events_dispatched +%= 1;
            subscription.callback(subscription.userdata, &view);
            if (result != @intFromEnum(abi.EventResult.continue_)) return .cancel;
        }
        return .continue_;
    }

    fn playerHandle(self: *PluginRuntime, player: *Player) u64 {
        if (self.handles.handleFor(.player, @intFromPtr(player))) |handle| return handle;
        return self.handles.put(.player, @intFromPtr(player), 0, &self.handles.runtime_head) catch 0;
    }

    fn getInterface(context: ?*anyopaque, interface_id: u32, major: u16, minor: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = interface orelse return abi.result_invalid_argument;
        output.* = null;
        if (major != 1 or minor > 0) return abi.result_version;
        switch (interface_id) {
            abi.interface_core => {
                output.* = @ptrCast(&self.core_api);
                return abi.result_ok;
            },
            abi.interface_scheduler => {
                output.* = @ptrCast(&self.scheduler_api);
                return abi.result_ok;
            },
            abi.interface_world => {
                output.* = @ptrCast(&self.world_api);
                return abi.result_ok;
            },
            abi.interface_players => {
                output.* = @ptrCast(&self.players_api);
                return abi.result_ok;
            },
            abi.interface_entities => {
                output.* = @ptrCast(&self.entities_api);
                return abi.result_ok;
            },
            abi.interface_items => {
                output.* = @ptrCast(&self.items_api);
                return abi.result_ok;
            },
            abi.interface_blocks => {
                output.* = @ptrCast(&self.blocks_api);
                return abi.result_ok;
            },
            abi.interface_inventories => {
                output.* = @ptrCast(&self.inventories_api);
                return abi.result_ok;
            },
            abi.interface_network => {
                output.* = @ptrCast(&self.network_api);
                return abi.result_ok;
            },
            else => return abi.result_unsupported,
        }
    }

    fn coreGetTick(context: ?*anyopaque, tick: ?*u64) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = tick orelse return abi.result_invalid_argument;
        output.* = (self.tecton orelse return abi.result_not_found).tick_count;
        return abi.result_ok;
    }

    fn coreGetState(context: ?*anyopaque, state: ?*u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = state orelse return abi.result_invalid_argument;
        output.* = self.server_state;
        return abi.result_ok;
    }

    fn schedulerSchedule(context: ?*anyopaque, _: u32, callback: ?abi.SchedulerCallbackFn, callback_userdata: ?*anyopaque, task: ?*u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const callback_value = callback orelse return abi.result_invalid_argument;
        const output = task orelse return abi.result_invalid_argument;
        if (output.* != 0) return abi.result_invalid_argument;
        const tasks = self.tasks orelse return abi.result_not_found;
        const scheduled = self.allocator.create(ScheduledTask) catch return abi.result_out_of_memory;
        scheduled.* = .{ .runtime = self, .plugin_id = slot.plugin_id, .timer_id = self.next_task, .callback = callback_value, .userdata = callback_userdata };
        self.next_task += 1;
        self.scheduled_tasks.append(self.allocator, scheduled) catch {
            self.allocator.destroy(scheduled);
            return abi.result_out_of_memory;
        };
        tasks.enqueue(.{ .func = runScheduledTask, .ctx = @ptrCast(scheduled), .name = "plugin", .owner_id = @intCast(slot.plugin_id), .cleanup = cleanupScheduledTask }) catch {
            _ = self.scheduled_tasks.pop();
            self.allocator.destroy(scheduled);
            return abi.result_busy;
        };
        output.* = scheduled.timer_id;
        return abi.result_ok;
    }

    fn schedulerCancel(context: ?*anyopaque, handle: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        for (self.scheduled_tasks.items) |scheduled| {
            if (scheduled.timer_id == handle and scheduled.plugin_id == slot.plugin_id and !scheduled.cancelled) {
                scheduled.cancelled = true;
                return abi.result_ok;
            }
        }
        return abi.result_not_found;
    }

    fn schedulerCancelOwner(context: ?*anyopaque, owner_id: u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        if (owner_id != slot.plugin_id) return abi.result_not_found;
        return cancelScheduledOwner(slot.runtime, slot.plugin_id);
    }

    fn cancelScheduledOwner(self: *PluginRuntime, plugin_id: u32) i32 {
        var found = false;
        for (self.scheduled_tasks.items) |scheduled| {
            if (scheduled.plugin_id == plugin_id and !scheduled.cancelled) {
                scheduled.cancelled = true;
                found = true;
            }
        }
        return if (found) abi.result_ok else abi.result_not_found;
    }

    fn runScheduledTask(context: *anyopaque) bool {
        const scheduled: *ScheduledTask = @ptrCast(@alignCast(context));
        if (!scheduled.cancelled) {
            if (scheduled.runtime.slotFor(scheduled.plugin_id)) |slot| slot.tasks_run +%= 1;
            _ = scheduled.callback(scheduled.userdata);
        }
        return true;
    }

    fn cleanupScheduledTask(context: *anyopaque) void {
        const scheduled: *ScheduledTask = @ptrCast(@alignCast(context));
        const runtime = scheduled.runtime;
        for (runtime.scheduled_tasks.items, 0..) |candidate, index| {
            if (candidate == scheduled) {
                _ = runtime.scheduled_tasks.swapRemove(index);
                break;
            }
        }
        runtime.allocator.destroy(scheduled);
    }

    fn cancelAllScheduled(self: *PluginRuntime) void {
        for (self.scheduled_tasks.items) |scheduled| scheduled.cancelled = true;
    }

    fn internalEvent(event_id: u32) ?Events.Event {
        return switch (event_id) {
            @intFromEnum(abi.EventId.server_start) => .ServerStart,
            @intFromEnum(abi.EventId.server_shutdown) => .ServerShutdown,
            @intFromEnum(abi.EventId.server_tick) => .ServerTick,
            @intFromEnum(abi.EventId.player_join) => .PlayerJoin,
            @intFromEnum(abi.EventId.player_disconnect) => .PlayerDisconnect,
            @intFromEnum(abi.EventId.player_chat) => .PlayerChat,
            @intFromEnum(abi.EventId.item_use) => .ItemUse,
            @intFromEnum(abi.EventId.player_move) => .PlayerMove,
            @intFromEnum(abi.EventId.damage) => .Damage,
            @intFromEnum(abi.EventId.block_place) => .BlockPlace,
            @intFromEnum(abi.EventId.block_break) => .BlockBreak,
            @intFromEnum(abi.EventId.inventory_open) => .InventoryOpen,
            @intFromEnum(abi.EventId.inventory_click) => .InventoryClick,
            @intFromEnum(abi.EventId.inventory_close) => .InventoryClose,
            @intFromEnum(abi.EventId.transaction_prepare) => .TransactionPrepare,
            @intFromEnum(abi.EventId.transaction_commit) => .TransactionCommit,
            @intFromEnum(abi.EventId.transaction_abort) => .TransactionAbort,
            else => null,
        };
    }

    fn externalEventId(event: Events.Event) ?abi.EventId {
        return switch (event) {
            .EntityCombust, .EnchantmentApply, .EnchantmentRemove, .EntitySpawn, .EntityDespawn, .EntityDamage, .EntityDeath, .EntityInteract => null,
            .ServerStart => .server_start,
            .ServerShutdown => .server_shutdown,
            .ServerTick => .server_tick,
            .PlayerJoin => .player_join,
            .PlayerDisconnect => .player_disconnect,
            .PlayerChat => .player_chat,
            .ItemUse => .item_use,
            .PlayerMove => .player_move,
            .Damage => .damage,
            .BlockPlace => .block_place,
            .BlockBreak => .block_break,
            .InventoryOpen => .inventory_open,
            .InventoryClick => .inventory_click,
            .InventoryClose => .inventory_close,
            .TransactionPrepare => .transaction_prepare,
            .TransactionCommit => .transaction_commit,
            .TransactionAbort => .transaction_abort,
        };
    }

    fn isPluginFile(name: []const u8) bool {
        if (builtin.os.tag == .windows) return std.mem.endsWith(u8, name, ".dll");
        if (builtin.os.tag == .macos) return std.mem.endsWith(u8, name, ".dylib");
        return std.mem.endsWith(u8, name, ".so");
    }

    fn allocate(context: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self = runtimeFrom(context) orelse return null;
        if (size == 0) return null;
        return self.allocator.rawAlloc(size, .fromByteUnits(@max(alignment, 1)), @returnAddress());
    }

    fn free(context: ?*anyopaque, memory: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self = runtimeFrom(context) orelse return;
        if (size == 0) return;
        const ptr = memory orelse return;
        self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..size], .fromByteUnits(@max(alignment, 1)), @returnAddress());
    }

    fn reallocate(context: ?*anyopaque, memory: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self = runtimeFrom(context) orelse return null;
        if (new_size == 0) {
            if (memory) |ptr| self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..old_size], .fromByteUnits(@max(alignment, 1)), @returnAddress());
            return null;
        }
        const replacement = self.allocator.rawAlloc(new_size, .fromByteUnits(@max(alignment, 1)), @returnAddress()) orelse return null;
        if (memory) |ptr| {
            const copy_size = @min(old_size, new_size);
            @memcpy(@as([*]u8, @ptrCast(replacement))[0..copy_size], @as([*]const u8, @ptrCast(ptr))[0..copy_size]);
            self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..old_size], .fromByteUnits(@max(alignment, 1)), @returnAddress());
        }
        return replacement;
    }

    fn allocateZeroed(context: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const memory = allocate(context, size, alignment) orelse return null;
        @memset(@as([*]u8, @ptrCast(memory))[0..size], 0);
        return memory;
    }

    fn log(context: ?*anyopaque, level: u32, message: abi.StringView) callconv(.c) void {
        const slot: *HostSlot = @ptrCast(@alignCast(context orelse return));
        const text = message.slice();
        switch (level) {
            abi.log_trace, abi.log_debug => logger.debug("[plugin:{s}] {s}", .{ slot.name, text }),
            abi.log_info => logger.info("[plugin:{s}] {s}", .{ slot.name, text }),
            abi.log_warn => logger.warn("[plugin:{s}] {s}", .{ slot.name, text }),
            else => logger.err("[plugin:{s}] {s}", .{ slot.name, text }),
        }
    }

    fn emitCustom(_: ?*anyopaque, _: u32, _: ?*const anyopaque, _: usize, _: u32) callconv(.c) i32 {
        return abi.result_unsupported;
    }

    fn schedulerEvery(_: ?*anyopaque, _: u32, _: ?abi.SchedulerCallbackFn, _: ?*anyopaque, _: ?*u64) callconv(.c) i32 {
        return abi.result_unsupported;
    }

    fn itemsCount(_: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        const ItemType = @import("../items/item_type.zig").ItemType;
        count_output.* = ItemType.getAll().count();
        return abi.result_ok;
    }

    fn itemsGetSnapshot(context: ?*anyopaque, index: usize, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.ItemSnapshot)) return abi.result_invalid_argument;
        const ItemType = @import("../items/item_type.zig").ItemType;
        var iterator = ItemType.getAll().valueIterator();
        var current: usize = 0;
        while (iterator.next()) |item_ptr| {
            if (current != index) {
                current += 1;
                continue;
            }
            const item = item_ptr.*;
            const handle = self.handles.put(.item, @intFromPtr(item), slot.plugin_id, &slot.owns_handles) catch return abi.result_out_of_memory;
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.ItemSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .network_id = item.network_id, .max_stack_size = item.max_stack_size, .stackable = if (item.stackable) 1 else 0, .reserved = .{0} ** 5, .identifier = .{ .data = item.identifier.ptr, .length = item.identifier.len } };
            return abi.result_ok;
        }
        return abi.result_not_found;
    }

    fn blocksGetSnapshot(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, x: i32, y: i32, z: i32, snapshot: ?*abi.BlockSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.BlockSnapshot)) return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        const permutation = dimension.getPermutation(.{ .x = x, .y = y, .z = z }, 0) catch return abi.result_not_found;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.BlockSnapshot), .version = 1, .reserved = 0 }, .world = world_handle, .dimension = .{ .data = dimension.identifier.ptr, .length = dimension.identifier.len }, .x = x, .y = y, .z = z, .network_id = permutation.network_id, .identifier = .{ .data = permutation.identifier.ptr, .length = permutation.identifier.len } };
        return abi.result_ok;
    }

    fn playerFromHandle(self: *PluginRuntime, handle: u64) ?*Player {
        const pointer = self.handles.get(.player, handle) orelse return null;
        return @ptrFromInt(pointer);
    }

    fn worldFromHandle(self: *PluginRuntime, handle: u64) ?*World {
        const pointer = self.handles.get(.world, handle) orelse return null;
        return @ptrFromInt(pointer);
    }

    fn inventoryState(self: *PluginRuntime, handle: u64) ?*@import("../entity/traits/inventory.zig").State {
        const player = self.playerFromHandle(handle) orelse return null;
        return player.entity.getTraitState(@import("../entity/traits/inventory.zig").InventoryTrait);
    }

    fn inventoryGetSize(context: ?*anyopaque, player_handle: u64, size_output: *u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const state = self.inventoryState(player_handle) orelse return abi.result_invalid_handle;
        size_output.* = state.container.base.getSize();
        return abi.result_ok;
    }

    fn inventoryGetItem(context: ?*anyopaque, player_handle: u64, slot_index: u32, snapshot: ?*abi.InventoryItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.InventoryItemSnapshot)) return abi.result_invalid_argument;
        const state = self.inventoryState(player_handle) orelse return abi.result_invalid_handle;
        if (slot_index >= state.container.base.getSize()) return abi.result_not_found;
        const item = state.container.base.getItem(slot_index);
        if (item) |value| {
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 1, .reserved = .{0} ** 3, .count = value.stack_size, .reserved_count = 0, .network_id = value.item_type.network_id, .metadata = value.metadata, .identifier = .{ .data = value.item_type.identifier.ptr, .length = value.item_type.identifier.len } };
        } else {
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 0, .reserved = .{0} ** 3, .count = 0, .reserved_count = 0, .network_id = 0, .metadata = 0, .identifier = .{} };
        }
        return abi.result_ok;
    }

    fn worldGetSnapshot(context: ?*anyopaque, handle: u64, snapshot: ?*abi.WorldSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.WorldSnapshot)) return abi.result_invalid_argument;
        const world = self.worldFromHandle(handle) orelse return abi.result_invalid_handle;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.WorldSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .name = .{ .data = world.identifier.ptr, .length = world.identifier.len } };
        return abi.result_ok;
    }

    fn playersCount(context: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        count_output.* = tecton.getPlayerCount();
        return abi.result_ok;
    }

    fn playersGetSnapshot(context: ?*anyopaque, index: usize, snapshot: ?*abi.PlayerSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.PlayerSnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const players = tecton.getPlayerSnapshots();
        if (index >= players.len) return abi.result_not_found;
        const player = players[index];
        const world_handle = if (player.entity.dimension) |dimension| self.handles.put(.world, @intFromPtr(dimension.world), slot.plugin_id, &slot.owns_handles) catch return abi.result_out_of_memory else 0;
        const dimension_name = if (player.entity.dimension) |dimension| dimension.identifier else "";
        const handle = self.handles.put(.player, @intFromPtr(player), slot.plugin_id, &slot.owns_handles) catch return abi.result_out_of_memory;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.PlayerSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .runtime_id = player.entity.runtime_id, .name = .{ .data = player.username.ptr, .length = player.username.len }, .uuid = .{ .data = player.uuid.ptr, .length = player.uuid.len }, .world = world_handle, .dimension = .{ .data = dimension_name.ptr, .length = dimension_name.len }, .x = player.entity.position.x, .y = player.entity.position.y, .z = player.entity.position.z };
        return abi.result_ok;
    }

    fn entitiesCount(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, count_output: *usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        count_output.* = dimension.entities.count();
        return abi.result_ok;
    }

    fn entitiesGetSnapshot(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, index: usize, snapshot: ?*abi.EntitySnapshot, snapshot_size: usize) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.EntitySnapshot)) return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        var iterator = dimension.entities.valueIterator();
        var current: usize = 0;
        while (iterator.next()) |entity_ptr| {
            if (current != index) {
                current += 1;
                continue;
            }
            const entity = entity_ptr.*;
            const handle = self.handles.put(.entity, @intFromPtr(entity), slot.plugin_id, &slot.owns_handles) catch return abi.result_out_of_memory;
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.EntitySnapshot), .version = 1, .reserved = 0 }, .handle = handle, .runtime_id = entity.runtime_id, .type = .{ .data = entity.entity_type.identifier.ptr, .length = entity.entity_type.identifier.len }, .world = world_handle, .dimension = .{ .data = dimension.identifier.ptr, .length = dimension.identifier.len }, .x = entity.position.x, .y = entity.position.y, .z = entity.position.z };
            return abi.result_ok;
        }
        return abi.result_not_found;
    }

    fn worldFind(context: ?*anyopaque, name: abi.StringView, handle: *u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const tecton = self.tecton orelse return abi.result_not_found;
        const world = tecton.worlds.get(name.slice()) orelse return abi.result_not_found;
        handle.* = self.handles.put(.world, @intFromPtr(world), slot.plugin_id, &slot.owns_handles) catch return abi.result_out_of_memory;
        return abi.result_ok;
    }

    fn worldSetBlock(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, x: i32, y: i32, z: i32, block: abi.StringView) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension_value = world.getDimension(dimension.slice()) orelse return abi.result_not_found;
        const permutation = @import("../world/block/block_permutation.zig").BlockPermutation.resolve(self.allocator, block.slice(), null) catch return abi.result_not_found;
        dimension_value.setPermutation(.{ .x = x, .y = y, .z = z }, permutation, 0) catch return abi.result_not_found;
        return abi.result_ok;
    }

    fn networkSend(context: ?*anyopaque, player_handle: u64, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const send_priority = sendPriority(priority) orelse return abi.result_invalid_argument;
        const payload = bytes.slice();
        if (payload.len == 0 or payload.len > MAX_PLUGIN_PACKET_BYTES) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        if (!isTickThread(tecton)) return abi.result_wrong_thread;
        const player = self.playerFromHandle(player_handle) orelse return abi.result_invalid_handle;
        tecton.network.sendPacketWith(player.connection, payload, send_priority) catch return abi.result_out_of_memory;
        return abi.result_ok;
    }

    fn networkBroadcast(context: ?*anyopaque, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const send_priority = sendPriority(priority) orelse return abi.result_invalid_argument;
        const payload = bytes.slice();
        if (payload.len == 0 or payload.len > MAX_PLUGIN_PACKET_BYTES) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        if (!isTickThread(tecton)) return abi.result_wrong_thread;
        for (tecton.getPlayerSnapshots()) |player| {
            if (!player.spawned) continue;
            tecton.network.sendPacketWith(player.connection, payload, send_priority) catch {};
        }
        return abi.result_ok;
    }

    fn isTickThread(tecton: *Tecton) bool {
        const tick_thread = tecton.tick_thread_id.load(.acquire);
        return tick_thread != 0 and tick_thread == @as(usize, @intCast(std.Thread.getCurrentId()));
    }

    fn sendPriority(value: u32) ?SendPriority {
        return switch (value) {
            abi.packet_priority_normal => .normal,
            abi.packet_priority_immediate => .immediate,
            else => null,
        };
    }
};

fn slotFrom(context: ?*anyopaque) ?*PluginRuntime.HostSlot {
    const slot: *PluginRuntime.HostSlot = @ptrCast(@alignCast(context orelse return null));
    return slot;
}

fn runtimeFrom(context: ?*anyopaque) ?*PluginRuntime {
    const slot: *PluginRuntime.HostSlot = @ptrCast(@alignCast(context orelse return null));
    return slot.runtime;
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const abi = test_owner.abi;
    pub const Events = test_owner.Events;
    pub const SendPriority = test_owner.SendPriority;
    pub const MAX_PLUGIN_PACKET_BYTES = test_owner.MAX_PLUGIN_PACKET_BYTES;
    pub const PluginRuntime = test_owner.PluginRuntime;
    pub const HostSlot = test_owner.PluginRuntime.HostSlot;
    pub const private_pluginruntime_getInterface = test_owner.PluginRuntime.getInterface;
    pub const private_pluginruntime_networkBroadcast = test_owner.PluginRuntime.networkBroadcast;
    pub const private_pluginruntime_networkSend = test_owner.PluginRuntime.networkSend;
    pub const private_pluginruntime_sendPriority = test_owner.PluginRuntime.sendPriority;
};

test "core and scheduler interfaces are independently discoverable" {
    try @import("runtime_test.zig").Suite(test_scope).case_000();
}

test "network send validates priority and payload before resolving anything else" {
    try @import("runtime_test.zig").Suite(test_scope).case_001();
}

test "unsubscribe is owner scoped and compacts the bucket" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    const callback = struct {
        fn call(_: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {}
    }.call;
    try runtime.buckets[event_index][phase_index].append(runtime.allocator, .{
        .subscription_id = 7,
        .order = runtime.next_order,
        .callback = callback,
        .userdata = null,
        .plugin_id = 3,
        .priority = 0,
    });
    runtime.next_order += 1;
    runtime.active[event_index][phase_index] = 1;

    var owner = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 3 };
    var foreign = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 4 };
    try std.testing.expectEqual(abi.result_not_found, PluginRuntime.eventUnsubscribe(@ptrCast(&foreign), 7));
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventUnsubscribe(@ptrCast(&owner), 7));
    try std.testing.expectEqual(@as(usize, 0), runtime.buckets[event_index][phase_index].items.len);
    try std.testing.expectEqual(abi.result_not_found, PluginRuntime.eventUnsubscribe(@ptrCast(&owner), 7));
}

test "nested dispatch restores depth and does not duplicate the bucket" {
    const Probe = struct {
        runtime: *PluginRuntime,
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.calls += 1;
            if (probe.calls != 1) return;
            var context = Events.EventContext{ .event = .ServerTick, .phase = .pre };
            var data = Events.types.ServerTickEvent{ .tick = 2 };
            _ = probe.runtime.dispatch(.ServerTick, &context, &data);
        }
    };

    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var probe = Probe{ .runtime = &runtime };

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    try runtime.buckets[event_index][phase_index].append(runtime.allocator, .{
        .subscription_id = 9,
        .order = runtime.next_order,
        .callback = Probe.callback,
        .userdata = &probe,
        .plugin_id = 1,
        .priority = 0,
    });
    runtime.next_order += 1;
    runtime.active[event_index][phase_index] = 1;

    var context = Events.EventContext{ .event = .ServerTick, .phase = .pre };
    var data = Events.types.ServerTickEvent{ .tick = 1 };
    try std.testing.expectEqual(Events.EventResult.continue_, runtime.dispatch(.ServerTick, &context, &data));
    try std.testing.expectEqual(@as(u32, 2), probe.calls);
    try std.testing.expectEqual(@as(u32, 0), runtime.depth);
}

test "unsubscribe from a callback retires the bridge" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 7, .state = .running };
    const Probe = struct {
        slot: *PluginRuntime.HostSlot,
        sub: u64 = 0,
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.calls += 1;
            _ = PluginRuntime.eventUnsubscribe(@ptrCast(probe.slot), probe.sub);
        }
    };
    var probe = Probe{ .slot = &slot };
    var sub: u64 = 0;
    try std.testing.expectEqual(
        abi.result_ok,
        PluginRuntime.eventSubscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );
    probe.sub = sub;
    try std.testing.expect(events.hasListeners(.ServerTick));

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expectEqual(@as(u32, 0), runtime.active[event_index][phase_index]);
    try std.testing.expectEqual(@as(usize, 0), runtime.buckets[event_index][phase_index].items.len);
    try std.testing.expect(!events.hasListeners(.ServerTick));

    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
}

test "unload requested from a callback drains at depth zero" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    const slot = try std.testing.allocator.create(PluginRuntime.HostSlot);
    slot.* = .{ .runtime = &runtime, .plugin_id = 1, .state = .running };
    try runtime.slots.append(std.testing.allocator, slot);
    try runtime.plugins.append(std.testing.allocator, slot);

    const Probe = struct {
        runtime: *PluginRuntime,
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.calls += 1;
            probe.runtime.unloadPlugin(1);
        }
    };
    var probe = Probe{ .runtime = &runtime };
    var sub: u64 = 0;
    try std.testing.expectEqual(
        abi.result_ok,
        PluginRuntime.eventSubscribe(@ptrCast(slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expect(runtime.slotFor(1) == null);
    try std.testing.expectEqual(@as(u32, 0), runtime.active[event_index][phase_index]);
    try std.testing.expectEqual(@as(usize, 0), runtime.buckets[event_index][phase_index].items.len);
    try std.testing.expect(!events.hasListeners(.ServerTick));
}

test "subscription during dispatch is ordered at depth zero" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 9, .state = .running };
    const Probe = struct {
        runtime: *PluginRuntime,
        slot: *PluginRuntime.HostSlot,
        calls: [4]u8 = undefined,
        len: usize = 0,
        sub: u64 = 0,

        fn push(self: *@This(), value: u8) void {
            self.calls[self.len] = value;
            self.len += 1;
        }

        fn first(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.push(1);
            if (probe.len == 1) {
                _ = PluginRuntime.eventSubscribe(@ptrCast(probe.slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 100, second, probe, &probe.sub);
            }
        }

        fn second(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.push(2);
        }
    };
    var probe = Probe{ .runtime = &runtime, .slot = &slot };

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    try runtime.buckets[event_index][phase_index].append(runtime.allocator, .{
        .subscription_id = 1,
        .order = runtime.next_order,
        .callback = Probe.first,
        .userdata = &probe,
        .plugin_id = 9,
        .priority = 0,
        .slot = &slot,
    });
    runtime.next_order += 1;
    runtime.active[event_index][phase_index] = 1;

    var context = Events.EventContext{ .event = .ServerTick, .phase = .pre };
    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = runtime.dispatch(.ServerTick, &context, &tick);
    try std.testing.expectEqual(@as(usize, 1), probe.len);
    try std.testing.expectEqual(@as(u8, 1), probe.calls[0]);
    try std.testing.expectEqual(@as(usize, 2), runtime.buckets[event_index][phase_index].items.len);
    try std.testing.expectEqual(@as(i16, 100), runtime.buckets[event_index][phase_index].items[0].priority);
    try std.testing.expect(!runtime.buckets[event_index][phase_index].items[0].pending);
    try std.testing.expectEqual(@as(u32, 0), runtime.dirty_total);

    _ = runtime.dispatch(.ServerTick, &context, &tick);
    try std.testing.expectEqual(@as(usize, 3), probe.len);
    try std.testing.expectEqual(@as(u8, 2), probe.calls[1]);
    try std.testing.expectEqual(@as(u8, 1), probe.calls[2]);
}

test "bridge priority upgrade applies after the outermost emit" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 5, .state = .running };
    const Probe = struct {
        slot: *PluginRuntime.HostSlot,
        added: bool = false,
        calls: [4]u8 = undefined,
        len: usize = 0,

        fn push(self: *@This(), value: u8) void {
            self.calls[self.len] = value;
            self.len += 1;
        }

        fn first(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.push(1);
            if (!probe.added) {
                probe.added = true;
                var second_sub: u64 = 0;
                _ = PluginRuntime.eventSubscribe(@ptrCast(probe.slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 100, second, probe, &second_sub);
            }
        }

        fn second(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.push(2);
        }
    };
    var probe = Probe{ .slot = &slot };
    var sub: u64 = 0;
    try std.testing.expectEqual(
        abi.result_ok,
        PluginRuntime.eventSubscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.first, &probe, &sub),
    );

    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(usize, 1), probe.len);
    try std.testing.expect(events.hasListeners(.ServerTick));

    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(usize, 3), probe.len);
    try std.testing.expectEqual(@as(u8, 2), probe.calls[1]);
    try std.testing.expectEqual(@as(u8, 1), probe.calls[2]);
}

test "unloadAll requested from a callback is not lost" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    const slot = try std.testing.allocator.create(PluginRuntime.HostSlot);
    slot.* = .{ .runtime = &runtime, .plugin_id = 1, .state = .running };
    try runtime.slots.append(std.testing.allocator, slot);
    try runtime.plugins.append(std.testing.allocator, slot);

    const Probe = struct {
        runtime: *PluginRuntime,
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.calls += 1;
            probe.runtime.unloadAll(.server_exit);
        }
    };
    var probe = Probe{ .runtime = &runtime };
    var sub: u64 = 0;
    try std.testing.expectEqual(
        abi.result_ok,
        PluginRuntime.eventSubscribe(@ptrCast(slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), runtime.count());
    try std.testing.expect(runtime.slotFor(1) == null);
    try std.testing.expectEqual(@as(u32, 0), runtime.active[event_index][phase_index]);
    try std.testing.expect(!events.hasListeners(.ServerTick));
}

test "bridge priority follows the highest active subscriber after compaction" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    const Trace = struct {
        calls: [4]u8 = undefined,
        len: usize = 0,

        fn push(self: *@This(), value: u8) void {
            self.calls[self.len] = value;
            self.len += 1;
        }

        fn core(context: *Events.EventContext, _: *Events.types.ServerTickEvent) Events.EventResult {
            const trace: *@This() = @ptrCast(@alignCast(context.listener_userdata.?));
            trace.push('c');
            return .continue_;
        }

        fn pluginHigh(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const trace: *@This() = @ptrCast(@alignCast(userdata.?));
            trace.push('h');
        }

        fn pluginLow(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const trace: *@This() = @ptrCast(@alignCast(userdata.?));
            trace.push('p');
        }
    };

    var trace = Trace{};
    _ = try events.subscribeWithContext(.ServerTick, .pre, 50, 0x50, Trace.core, &trace);

    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 2, .state = .running };
    var high: u64 = 0;
    var low: u64 = 0;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventSubscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 100, Trace.pluginHigh, &trace, &high));
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventSubscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Trace.pluginLow, &trace, &low));

    const event_index = @intFromEnum(abi.EventId.server_tick);
    const phase_index = abi.event_phase_pre;
    try std.testing.expectEqual(@as(i16, 100), runtime.bridge_priority[event_index][phase_index]);

    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventUnsubscribe(@ptrCast(&slot), high));
    try std.testing.expectEqual(@as(i16, 0), runtime.bridge_priority[event_index][phase_index]);

    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(usize, 2), trace.len);
    try std.testing.expectEqual(@as(u8, 'c'), trace.calls[0]);
    try std.testing.expectEqual(@as(u8, 'p'), trace.calls[1]);
}

test "removing an entity invalidates the handle taken from the snapshot" {
    const allocator = std.testing.allocator;
    const Host = @import("../player/player.zig").Host;

    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();

    const Probe = struct {
        runtime: *PluginRuntime,

        fn snapshots(_: *anyopaque) []const *Player {
            return &.{};
        }

        fn unregister(_: *anyopaque, _: *Entity) void {}

        fn noteEntityRemoved(context: *anyopaque, entity: *Entity) void {
            const probe: *@This() = @ptrCast(@alignCast(context));
            probe.runtime.noteEntityRemoved(entity);
        }
    };
    var probe = Probe{ .runtime = &runtime };

    var host: Host = undefined;
    host.ctx = &probe;
    host.get_player_snapshots = Probe.snapshots;
    host.unregister_ecs_entity = Probe.unregister;
    host.note_entity_removed = Probe.noteEntityRemoved;

    var world: World = undefined;
    world.tecton = host;
    world.allocator = allocator;
    world.identifier = "test";
    world.dimensions = std.StringHashMap(*Dimension).init(allocator);
    defer world.dimensions.deinit();

    var dimension = Dimension.init(&world, allocator, "overworld", .Overworld, null);
    var dimension_deinited = false;
    defer if (!dimension_deinited) dimension.deinit();
    try world.dimensions.put("overworld", &dimension);

    const entity_type = EntityType.init("minecraft:test", 1, &.{}, &.{});
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1, .state = .running };
    const world_handle = try runtime.handles.put(.world, @intFromPtr(&world), slot.plugin_id, &slot.owns_handles);
    const dimension_view = abi.StringView{ .data = dimension.identifier.ptr, .length = dimension.identifier.len };

    const first = try allocator.create(Entity);
    first.* = Entity.init(allocator, &entity_type, &dimension);
    try dimension.entities.put(first.runtime_id, first);
    var first_removed = false;
    defer if (!first_removed) {
        _ = dimension.entities.remove(first.runtime_id);
        first.deinit();
        allocator.destroy(first);
    };

    var first_snapshot: abi.EntitySnapshot = undefined;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.entitiesGetSnapshot(@ptrCast(&slot), world_handle, dimension_view, 0, &first_snapshot, @sizeOf(abi.EntitySnapshot)));
    try std.testing.expectEqual(@as(?usize, @intFromPtr(first)), runtime.handles.get(.entity, first_snapshot.handle));

    try entities_mod.removeEntity(&dimension, first);
    first_removed = true;
    try std.testing.expect(runtime.handles.get(.entity, first_snapshot.handle) == null);

    const second = try allocator.create(Entity);
    second.* = Entity.init(allocator, &entity_type, &dimension);
    try dimension.entities.put(second.runtime_id, second);
    var second_snapshot: abi.EntitySnapshot = undefined;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.entitiesGetSnapshot(@ptrCast(&slot), world_handle, dimension_view, 0, &second_snapshot, @sizeOf(abi.EntitySnapshot)));

    dimension.deinit();
    dimension_deinited = true;
    try std.testing.expect(runtime.handles.get(.entity, second_snapshot.handle) == null);
}
