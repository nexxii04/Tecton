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
const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
const ItemType = @import("../items/item_type.zig").ItemType;
const EntityTypeRegistry = @import("../entity/entity_type_registry.zig").EntityTypeRegistry;

const MAX_PLUGIN_PACKET_BYTES: usize = 1 << 20;
const event_count = std.meta.fields(Events.Event).len;
const custom_event_count: usize = abi.max_custom_events;
const bucket_count = event_count + custom_event_count;
const deferred_capacity: usize = 1024;
const timer_wheel_slots: usize = 4096;
const timer_capacity: usize = 4096;
const timer_none: u32 = std.math.maxInt(u32);
const max_emit_depth: u32 = 16;

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
    buckets: [bucket_count][3]std.ArrayList(Subscription),
    active: [bucket_count][3]u32,
    dead: [bucket_count][3]u32,
    bridges: [bucket_count][3]bool,
    bridge_priority: [bucket_count][3]i16,
    bridge_refresh: [bucket_count][3]bool = std.mem.zeroes([bucket_count][3]bool),
    bridge_refresh_total: u32 = 0,
    bridge_total: u32 = 0,
    retire_pending: [bucket_count * 3]u16 = std.mem.zeroes([bucket_count * 3]u16),
    retire_seen: [bucket_count][3]bool = std.mem.zeroes([bucket_count][3]bool),
    retire_count: usize = 0,
    dirty: [bucket_count][3]bool = std.mem.zeroes([bucket_count][3]bool),
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
    core_api: abi.CoreApi,
    logging_api: abi.LoggingApi,
    events_api: abi.EventsApi,
    scheduler_api: abi.SchedulerApi,
    world_api: abi.WorldApi,
    players_api: abi.PlayersApi,
    entities_api: abi.EntitiesApi,
    items_api: abi.ItemsApi,
    blocks_api: abi.BlocksApi,
    inventories_api: abi.InventoriesApi,
    registries_api: abi.RegistriesApi,
    network_api: abi.NetworkApi,
    commands_api: abi.CommandsApi,
    custom_schemas: std.ArrayList(CustomSchema),
    deferred_ring: ?[]DeferredEmit = null,
    deferred_head: usize = 0,
    deferred_tail: usize = 0,
    deferred_len: usize = 0,
    block_state_entries: ?[]abi.BlockStateEntry = null,
    block_state_entry_count: usize = 0,
    item_entries: ?[]abi.ItemEntry = null,
    item_entry_count: usize = 0,
    entity_type_entries: ?[]abi.EntityTypeEntry = null,
    entity_type_entry_count: usize = 0,
    timer_wheel: ?*TimerWheel = null,
    timer_tick: u64 = 0,
    timer_task_registered: bool = false,

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
        scope: [64]u8 = undefined,
        scope_len: u8 = 0,
        log_level: u32 = abi.log_trace,

        fn logEnabled(self: *const HostSlot, level: u32) bool {
            if (level < self.log_level) return false;
            return switch (level) {
                abi.log_trace, abi.log_debug => logger.enabled(.debug),
                abi.log_info => logger.enabled(.info),
                abi.log_warn => logger.enabled(.warn),
                else => logger.enabled(.err),
            };
        }
    };

    const CustomSchema = struct {
        name: ?[]u8,
        schema: u32,
        plugin_id: u32,
    };

    const DeferredEmit = extern struct {
        schema: u32,
        size: u16,
        flags: u16,
        payload: [abi.custom_payload_max]u8,
    };

    const TimerSlot = struct {
        next_tick: u64 = 0,
        callback: ?abi.TimerCallbackFn = null,
        userdata: ?*anyopaque = null,
        plugin_id: u32 = 0,
        interval: u32 = 0,
        generation: u32 = 1,
        next: u32 = timer_none,
        prev: u32 = timer_none,
        active: bool = false,
        firing: bool = false,
    };

    const TimerWheel = struct {
        slots: std.ArrayList(TimerSlot),
        free: std.ArrayList(u32),
        garbage: std.ArrayList(u32),
        heads: []u32,
        live: u32 = 0,
        dispatching: bool = false,
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
            .active = std.mem.zeroes([bucket_count][3]u32),
            .dead = std.mem.zeroes([bucket_count][3]u32),
            .bridges = std.mem.zeroes([bucket_count][3]bool),
            .bridge_priority = std.mem.zeroes([bucket_count][3]i16),
            .pending_unloads = .empty,
            .custom_schemas = .empty,
            .core_api = undefined,
            .logging_api = undefined,
            .events_api = undefined,
            .scheduler_api = undefined,
            .world_api = undefined,
            .players_api = undefined,
            .entities_api = undefined,
            .items_api = undefined,
            .blocks_api = undefined,
            .inventories_api = undefined,
            .registries_api = undefined,
            .network_api = undefined,
            .commands_api = undefined,
        };
        for (0..bucket_count) |event_index| {
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
        runtime.logging_api = .{
            .header = .{ .struct_size = @sizeOf(abi.LoggingApi), .major = 1, .minor = 0, .interface_id = abi.interface_logging, .reserved = 0, .features = abi.feature_logging },
            .log = log,
            .is_enabled = logIsEnabled,
            .set_level = logSetLevel,
            .set_scope = logSetScope,
        };
        runtime.events_api = .{
            .header = .{ .struct_size = @sizeOf(abi.EventsApi), .major = 1, .minor = 0, .interface_id = abi.interface_events, .reserved = 0, .features = abi.feature_events },
            .subscribe = eventSubscribe,
            .unsubscribe = eventUnsubscribe,
            .emit = emitCustom,
            .emit_immediate = emitImmediate,
            .schema_of = schemaOf,
        };
        runtime.scheduler_api = .{
            .header = .{ .struct_size = @sizeOf(abi.SchedulerApi), .major = 1, .minor = 0, .interface_id = abi.interface_scheduler, .reserved = 0, .features = abi.feature_scheduler },
            .after = schedulerAfter,
            .every = schedulerEvery,
            .cancel = schedulerCancel,
            .cancel_owner = schedulerCancelOwner,
        };
        runtime.network_api = .{
            .header = .{ .struct_size = @sizeOf(abi.NetworkApi), .major = 1, .minor = 0, .interface_id = abi.interface_network, .reserved = 0, .features = abi.feature_network },
            .send = networkSend,
            .broadcast = networkBroadcast,
        };
        runtime.registries_api = .{
            .header = .{ .struct_size = @sizeOf(abi.RegistriesApi), .major = 1, .minor = 0, .interface_id = abi.interface_registries, .reserved = 0, .features = abi.feature_registries },
            .block_states = registriesBlockStates,
            .items = registriesItems,
            .entity_types = registriesEntityTypes,
        };
        runtime.commands_api = .{
            .header = .{ .struct_size = @sizeOf(abi.CommandsApi), .major = 1, .minor = 0, .interface_id = abi.interface_commands, .reserved = 0, .features = abi.feature_commands },
            .register_command = commandRegister,
            .unregister = commandUnregister,
            .mark_dirty = commandMarkDirty,
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
        _ = self.ensureDeferredRing() catch {};
        _ = self.ensureTimerWheel() catch {};
        self.registerTimerTask();
    }

    pub fn attachEvents(self: *PluginRuntime, events: *Events.Events) void {
        if (self.events) |previous| previous.setIdleHook(null, null);
        self.events = events;
        if (self.bridge_refresh_total > 0) events.setIdleHook(bridgeIdle, self);
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
        for (0..bucket_count) |event_index| {
            for (0..3) |phase| self.buckets[event_index][phase].deinit(self.allocator);
        }
        for (self.custom_schemas.items) |schema| {
            if (schema.name) |name| self.allocator.free(name);
        }
        self.custom_schemas.deinit(self.allocator);
        if (self.deferred_ring) |ring| self.allocator.free(ring);
        if (self.block_state_entries) |entries| {
            if (entries.len > 0) self.allocator.free(entries);
        }
        if (self.item_entries) |entries| {
            if (entries.len > 0) self.allocator.free(entries);
        }
        if (self.entity_type_entries) |entries| {
            if (entries.len > 0) self.allocator.free(entries);
        }
        if (self.timer_wheel) |wheel| {
            wheel.slots.deinit(self.allocator);
            wheel.free.deinit(self.allocator);
            wheel.garbage.deinit(self.allocator);
            self.allocator.free(wheel.heads);
            self.allocator.destroy(wheel);
            self.timer_wheel = null;
        }
        self.pending_unloads.deinit(self.allocator);
        self.plugins.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.handles.deinit();
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
        self.cancelTimersFor(slot.plugin_id);
        self.releaseSchemas(slot.plugin_id);
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
        if (self.tasks) |tasks| tasks.drainByOwner("plugin", @intCast(plugin_id), null);
    }

    fn removeSubscriptions(self: *PluginRuntime, plugin_id: u32) void {
        for (0..bucket_count) |event_index| {
            for (0..3) |phase| {
                var changed = false;
                for (self.buckets[event_index][phase].items) |*subscription| {
                    if (subscription.plugin_id != plugin_id or !subscription.active) continue;
                    subscription.active = false;
                    self.dead[event_index][phase] += 1;
                    self.dead_total += 1;
                    if (self.active[event_index][phase] > 0) self.active[event_index][phase] -= 1;
                    if (self.depth > 0 and self.active[event_index][phase] == 0) self.markRetire(event_index, phase);
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
        const event_index: usize = if (event_id >= abi.event_custom_base) blk: {
            const custom = event_id - abi.event_custom_base;
            if (custom >= abi.max_custom_events) return abi.result_not_found;
            if (custom >= self.custom_schemas.items.len or self.custom_schemas.items[custom].name == null) return abi.result_not_found;
            break :blk event_count + custom;
        } else blk: {
            if (event_id >= event_count) return abi.result_not_found;
            const internal = internalEvent(event_id) orelse return abi.result_not_found;
            if (externalEventId(internal) == null) return abi.result_not_found;
            break :blk @intCast(event_id);
        };
        const core_event = event_index < event_count;
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
                if (core_event) self.maybeRemoveEmptyBridge(event_index, phase_index);
                return abi.result_out_of_memory;
            };
            item_index = self.buckets[event_index][phase_index].items.len - 1;
            self.markDirty(event_index, phase_index);
        } else {
            var index: usize = 0;
            while (index < self.buckets[event_index][phase_index].items.len and self.buckets[event_index][phase_index].items[index].priority >= priority) : (index += 1) {}
            self.buckets[event_index][phase_index].insert(self.allocator, index, item) catch {
                if (core_event) self.maybeRemoveEmptyBridge(event_index, phase_index);
                return abi.result_out_of_memory;
            };
            item_index = index;
        }
        self.active[event_index][phase_index] += 1;
        if (core_event) {
            self.ensureBridge(event_id, phase, priority) catch {
                self.active[event_index][phase_index] -= 1;
                self.buckets[event_index][phase_index].items[item_index].active = false;
                self.dead[event_index][phase_index] += 1;
                self.dead_total += 1;
                if (self.depth > 0 and self.active[event_index][phase_index] == 0) self.markRetire(event_index, phase_index);
                if (self.depth == 0) self.compactBucket(event_index, phase_index, true);
                return abi.result_unsupported;
            };
        }
        output.* = id;
        return abi.result_ok;
    }

    fn eventUnsubscribe(context: ?*anyopaque, subscription: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        if (subscription == 0) return abi.result_invalid_argument;
        for (0..bucket_count) |event_index| {
            for (0..3) |phase| {
                for (self.buckets[event_index][phase].items) |*item| {
                    if (item.subscription_id != subscription or !item.active) continue;
                    if (item.plugin_id != slot.plugin_id) return abi.result_not_found;
                    item.active = false;
                    self.dead[event_index][phase] += 1;
                    self.dead_total += 1;
                    if (self.active[event_index][phase] > 0) self.active[event_index][phase] -= 1;
                    if (self.depth > 0 and self.active[event_index][phase] == 0) self.markRetire(event_index, phase);
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
        if (self.bridge_refresh_total == 0) {
            if (self.events) |events| events.setIdleHook(bridgeIdle, self);
        }
        self.bridge_refresh_total += 1;
    }

    fn clearBridgeRefresh(self: *PluginRuntime, event_index: usize, phase_index: usize) void {
        if (!self.bridge_refresh[event_index][phase_index]) return;
        self.bridge_refresh[event_index][phase_index] = false;
        if (self.bridge_refresh_total > 0) self.bridge_refresh_total -= 1;
        if (self.bridge_refresh_total == 0) {
            if (self.events) |events| events.setIdleHook(null, null);
        }
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

    fn markRetire(self: *PluginRuntime, event_index: usize, phase: usize) void {
        if (self.retire_seen[event_index][phase]) return;
        self.retire_seen[event_index][phase] = true;
        self.retire_pending[self.retire_count] = @intCast(event_index * 3 + phase);
        self.retire_count += 1;
    }

    fn retireEmptyBridges(self: *PluginRuntime) void {
        if (self.in_emit) return;
        if (self.retire_count == 0) return;
        var index: usize = 0;
        while (index < self.retire_count) : (index += 1) {
            const encoded = self.retire_pending[index];
            const event_index: usize = encoded / 3;
            const phase: usize = encoded % 3;
            self.retire_seen[event_index][phase] = false;
            if (self.active[event_index][phase] != 0) continue;
            if (self.bridges[event_index][phase] or self.bridge_refresh[event_index][phase]) {
                self.removeBridge(event_index, phase);
            }
        }
        self.retire_count = 0;
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
            if (event_index < event_count and retire_bridge and !self.in_emit and self.active[event_index][phase] == 0) {
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
        if (event_index >= event_count) return;
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
        for (0..bucket_count) |event_index| {
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

    fn dispatchMeta(comptime event: Events.Event) ?abi.EventMeta {
        const external = externalEventId(event) orelse return null;
        return abi.eventMeta(external);
    }

    fn dispatch(self: *PluginRuntime, comptime event: Events.Event, context: *Events.EventContext, data: *Events.Event.DataType(event)) Events.EventResult {
        const maybe_meta = comptime dispatchMeta(event);
        const meta = maybe_meta orelse return .continue_;
        const external_event_id = meta.external_id;
        const event_index: usize = external_event_id;
        const phase: usize = @intFromEnum(context.phase);
        if (self.active[event_index][phase] == 0) return .continue_;

        var result: i32 = @intFromEnum(abi.EventResult.continue_);
        var payload: abi.ServerTickEvent = undefined;
        var player_payload: abi.PlayerEvent = undefined;
        var payload_ptr: ?*const anyopaque = null;
        var payload_size: usize = 0;
        switch (meta.payload) {
            .tick => {
                payload.tick = data.tick;
                payload_ptr = @ptrCast(&payload);
                payload_size = @sizeOf(abi.ServerTickEvent);
            },
            .player_join => {
                player_payload.handle = self.playerHandle(data.player);
                if (player_payload.handle != 0) {
                    payload_ptr = @ptrCast(&player_payload);
                    payload_size = @sizeOf(abi.PlayerEvent);
                }
            },
            .player_disconnect => {
                player_payload.handle = self.handles.handleFor(.player, @intFromPtr(data.player)) orelse 0;
                if (player_payload.handle != 0) {
                    payload_ptr = @ptrCast(&player_payload);
                    payload_size = @sizeOf(abi.PlayerEvent);
                }
            },
            .none => {},
        }

        const view = abi.EventView{
            .data = payload_ptr,
            .data_size = payload_size,
            .result = &result,
            .schema = meta.schema,
            .event_id = external_event_id,
            .phase = @intCast(phase),
            .flags = meta.flags,
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
            if (result != @intFromEnum(abi.EventResult.continue_) and (meta.flags & abi.event_flag_cancelable) != 0) return .cancel;
        }
        return .continue_;
    }

    fn playerHandle(self: *PluginRuntime, player: *Player) u64 {
        if (self.handles.handleFor(.player, @intFromPtr(player))) |handle| return handle;
        return self.handles.put(.player, @intFromPtr(player), 0, &self.handles.runtime_head) catch 0;
    }

    const InterfaceSpec = struct {
        id: u32,
        major: u16,
        minor: u16,
        field: []const u8,
    };

    const interface_specs = [_]InterfaceSpec{
        .{ .id = abi.interface_core, .major = 1, .minor = 0, .field = "core_api" },
        .{ .id = abi.interface_logging, .major = 1, .minor = 0, .field = "logging_api" },
        .{ .id = abi.interface_events, .major = 1, .minor = 0, .field = "events_api" },
        .{ .id = abi.interface_scheduler, .major = 1, .minor = 0, .field = "scheduler_api" },
        .{ .id = abi.interface_world, .major = 1, .minor = 0, .field = "world_api" },
        .{ .id = abi.interface_players, .major = 1, .minor = 0, .field = "players_api" },
        .{ .id = abi.interface_entities, .major = 1, .minor = 0, .field = "entities_api" },
        .{ .id = abi.interface_items, .major = 1, .minor = 0, .field = "items_api" },
        .{ .id = abi.interface_blocks, .major = 1, .minor = 0, .field = "blocks_api" },
        .{ .id = abi.interface_inventories, .major = 1, .minor = 0, .field = "inventories_api" },
        .{ .id = abi.interface_registries, .major = 1, .minor = 0, .field = "registries_api" },
        .{ .id = abi.interface_network, .major = 1, .minor = 0, .field = "network_api" },
        .{ .id = abi.interface_commands, .major = 1, .minor = 0, .field = "commands_api" },
    };

    fn getInterface(context: ?*anyopaque, interface_id: u32, major: u16, minor: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = interface orelse return abi.result_invalid_argument;
        output.* = null;
        inline for (interface_specs) |spec| {
            if (spec.id == interface_id) {
                if (major != spec.major or minor > spec.minor) return abi.result_version;
                output.* = @ptrCast(&@field(self, spec.field));
                return abi.result_ok;
            }
        }
        return abi.result_unsupported;
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

    fn ensureTimerWheel(self: *PluginRuntime) !*TimerWheel {
        if (self.timer_wheel) |wheel| return wheel;
        const wheel = try self.allocator.create(TimerWheel);
        errdefer self.allocator.destroy(wheel);
        const heads = try self.allocator.alloc(u32, timer_wheel_slots);
        errdefer self.allocator.free(heads);
        @memset(heads, timer_none);
        wheel.* = .{ .slots = .empty, .free = .empty, .garbage = .empty, .heads = heads };
        errdefer {
            wheel.slots.deinit(self.allocator);
            wheel.free.deinit(self.allocator);
            wheel.garbage.deinit(self.allocator);
        }
        try wheel.slots.ensureTotalCapacity(self.allocator, timer_capacity);
        try wheel.free.ensureTotalCapacity(self.allocator, timer_capacity);
        try wheel.garbage.ensureTotalCapacity(self.allocator, timer_capacity);
        self.timer_wheel = wheel;
        return wheel;
    }

    fn registerTimerTask(self: *PluginRuntime) void {
        if (self.timer_task_registered) return;
        const tasks = self.tasks orelse return;
        tasks.enqueue(.{ .func = timerTask, .ctx = @ptrCast(self), .name = "plugin-timers", .owner_id = 0 }) catch return;
        self.timer_task_registered = true;
    }

    fn timerTask(context: *anyopaque) bool {
        const self: *PluginRuntime = @ptrCast(@alignCast(context));
        const tick = if (self.tecton) |tecton| tecton.tick_count else self.timer_tick + 1;
        self.runTimers(tick);
        return false;
    }

    pub fn runTimers(self: *PluginRuntime, tick: u64) void {
        const wheel = self.timer_wheel orelse {
            self.timer_tick = tick;
            return;
        };
        self.timer_tick = tick;
        wheel.dispatching = true;
        defer {
            wheel.dispatching = false;
            for (wheel.garbage.items) |index| recycleTimer(wheel, index);
            wheel.garbage.clearRetainingCapacity();
        }
        const head_index: usize = @intCast(tick % timer_wheel_slots);
        var current = wheel.heads[head_index];
        wheel.heads[head_index] = timer_none;
        while (current != timer_none) {
            const next = wheel.slots.items[current].next;
            const timer = &wheel.slots.items[current];
            timer.next = timer_none;
            timer.prev = timer_none;
            if (!timer.active) {
                current = next;
                continue;
            }
            if (timer.next_tick != tick) {
                self.linkTimer(wheel, current, timer.next_tick);
                current = next;
                continue;
            }
            timer.firing = true;
            const callback = timer.callback;
            const userdata = timer.userdata;
            const interval = timer.interval;
            if (self.slotFor(timer.plugin_id)) |slot| slot.tasks_run +%= 1;
            const handle = (@as(u64, timer.generation) << 32) | current;
            if (callback) |cb| cb(userdata, handle);
            timer.firing = false;
            if (!timer.active) {
                self.releaseTimer(wheel, current);
            } else if (interval > 0) {
                self.linkTimer(wheel, current, tick + interval);
            } else {
                self.releaseTimer(wheel, current);
            }
            current = next;
        }
    }

    fn schedulerAfter(context: ?*anyopaque, delay: u32, callback: ?abi.TimerCallbackFn, callback_userdata: ?*anyopaque, timer: ?*u64) callconv(.c) i32 {
        return scheduleTimer(context, @max(delay, 1), 0, callback, callback_userdata, timer);
    }

    fn schedulerEvery(context: ?*anyopaque, interval: u32, callback: ?abi.TimerCallbackFn, callback_userdata: ?*anyopaque, timer: ?*u64) callconv(.c) i32 {
        if (interval == 0) return abi.result_invalid_argument;
        return scheduleTimer(context, interval, interval, callback, callback_userdata, timer);
    }

    fn scheduleTimer(context: ?*anyopaque, delay: u32, interval: u32, callback: ?abi.TimerCallbackFn, callback_userdata: ?*anyopaque, timer: ?*u64) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const callback_value = callback orelse return abi.result_invalid_argument;
        const output = timer orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const wheel = self.timer_wheel orelse self.ensureTimerWheel() catch return abi.result_out_of_memory;
        const next_tick = self.timer_tick + @as(u64, delay);
        const handle = self.insertTimer(wheel, next_tick, interval, callback_value, callback_userdata, slot.plugin_id) catch return abi.result_busy;
        output.* = handle;
        return abi.result_ok;
    }

    fn schedulerCancel(context: ?*anyopaque, handle: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const wheel = self.timer_wheel orelse return abi.result_not_found;
        const index: u32 = @intCast(handle & 0xffff_ffff);
        const generation: u32 = @intCast(handle >> 32);
        if (index >= wheel.slots.items.len) return abi.result_not_found;
        const timer = &wheel.slots.items[index];
        if (!timer.active or timer.generation != generation or timer.plugin_id != slot.plugin_id) return abi.result_not_found;
        timer.active = false;
        if (!timer.firing) {
            self.unlinkTimer(wheel, index);
            self.releaseTimer(wheel, index);
        }
        return abi.result_ok;
    }

    fn schedulerCancelOwner(context: ?*anyopaque) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        return cancelOwnerTimers(slot.runtime, slot.plugin_id);
    }

    fn cancelOwnerTimers(self: *PluginRuntime, plugin_id: u32) i32 {
        const wheel = self.timer_wheel orelse return abi.result_not_found;
        var found = false;
        for (wheel.slots.items, 0..) |*timer, index| {
            if (!timer.active or timer.plugin_id != plugin_id) continue;
            timer.active = false;
            if (!timer.firing) {
                self.unlinkTimer(wheel, @intCast(index));
                self.releaseTimer(wheel, @intCast(index));
            }
            found = true;
        }
        return if (found) abi.result_ok else abi.result_not_found;
    }

    fn cancelTimersFor(self: *PluginRuntime, plugin_id: u32) void {
        _ = cancelOwnerTimers(self, plugin_id);
    }

    fn insertTimer(self: *PluginRuntime, wheel: *TimerWheel, next_tick: u64, interval: u32, callback: abi.TimerCallbackFn, userdata: ?*anyopaque, plugin_id: u32) !u64 {
        if (wheel.live >= @as(u32, timer_capacity)) return error.TimerLimit;
        var index: u32 = undefined;
        if (wheel.free.pop()) |value| {
            index = value;
        } else {
            index = @intCast(wheel.slots.items.len);
            wheel.slots.appendAssumeCapacity(.{});
        }
        const timer = &wheel.slots.items[index];
        const generation = if (timer.generation == 0) 1 else timer.generation;
        timer.* = .{ .next_tick = next_tick, .callback = callback, .userdata = userdata, .plugin_id = plugin_id, .interval = interval, .generation = generation };
        self.linkTimer(wheel, index, next_tick);
        wheel.live += 1;
        return (@as(u64, generation) << 32) | index;
    }

    fn linkTimer(_: *PluginRuntime, wheel: *TimerWheel, index: u32, next_tick: u64) void {
        const head_index: usize = @intCast(next_tick % timer_wheel_slots);
        const head = wheel.heads[head_index];
        const timer = &wheel.slots.items[index];
        timer.next_tick = next_tick;
        timer.next = head;
        timer.prev = timer_none;
        timer.active = true;
        if (head != timer_none) wheel.slots.items[head].prev = index;
        wheel.heads[head_index] = index;
    }

    fn unlinkTimer(_: *PluginRuntime, wheel: *TimerWheel, index: u32) void {
        const timer = wheel.slots.items[index];
        const head_index: usize = @intCast(timer.next_tick % timer_wheel_slots);
        if (timer.prev != timer_none) {
            wheel.slots.items[timer.prev].next = timer.next;
        } else if (wheel.heads[head_index] == index) {
            wheel.heads[head_index] = timer.next;
        }
        if (timer.next != timer_none) wheel.slots.items[timer.next].prev = timer.prev;
        wheel.slots.items[index].next = timer_none;
        wheel.slots.items[index].prev = timer_none;
    }

    fn releaseTimer(_: *PluginRuntime, wheel: *TimerWheel, index: u32) void {
        const timer = &wheel.slots.items[index];
        timer.active = false;
        timer.callback = null;
        timer.userdata = null;
        timer.next = timer_none;
        timer.prev = timer_none;
        if (wheel.live > 0) wheel.live -= 1;
        if (wheel.dispatching) {
            wheel.garbage.appendAssumeCapacity(index);
            return;
        }
        recycleTimer(wheel, index);
    }

    fn recycleTimer(wheel: *TimerWheel, index: u32) void {
        const timer = &wheel.slots.items[index];
        timer.generation +%= 1;
        if (timer.generation == 0) timer.generation = 1;
        wheel.free.appendAssumeCapacity(index);
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
        const slot = slotFrom(context) orelse return;
        if (!slot.logEnabled(level)) return;
        const text = message.slice();
        if (slot.scope_len == 0) {
            switch (level) {
                abi.log_trace, abi.log_debug => logger.debug("[plugin:{s}] {s}", .{ slot.name, text }),
                abi.log_info => logger.info("[plugin:{s}] {s}", .{ slot.name, text }),
                abi.log_warn => logger.warn("[plugin:{s}] {s}", .{ slot.name, text }),
                else => logger.err("[plugin:{s}] {s}", .{ slot.name, text }),
            }
            return;
        }
        const scope = slot.scope[0..slot.scope_len];
        switch (level) {
            abi.log_trace, abi.log_debug => logger.debug("[plugin:{s}/{s}] {s}", .{ slot.name, scope, text }),
            abi.log_info => logger.info("[plugin:{s}/{s}] {s}", .{ slot.name, scope, text }),
            abi.log_warn => logger.warn("[plugin:{s}/{s}] {s}", .{ slot.name, scope, text }),
            else => logger.err("[plugin:{s}/{s}] {s}", .{ slot.name, scope, text }),
        }
    }

    fn logIsEnabled(context: ?*anyopaque, level: u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return 0;
        return if (slot.logEnabled(level)) 1 else 0;
    }

    fn logSetLevel(context: ?*anyopaque, level: u32) callconv(.c) void {
        const slot = slotFrom(context) orelse return;
        slot.log_level = @min(level, abi.log_error);
    }

    fn logSetScope(context: ?*anyopaque, value: abi.StringView) callconv(.c) void {
        const slot = slotFrom(context) orelse return;
        const scope = value.slice();
        const length = @min(scope.len, slot.scope.len);
        if (length > 0) @memcpy(slot.scope[0..length], scope[0..length]);
        slot.scope_len = @intCast(length);
    }

    fn schemaOf(context: ?*anyopaque, name: abi.StringView, flags: u32, out_schema: ?*u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = out_schema orelse return abi.result_invalid_argument;
        const text = name.slice();
        if (text.len == 0 or text.len > 96) return abi.result_invalid_argument;
        for (self.custom_schemas.items) |schema| {
            if (schema.name) |existing| {
                if (std.mem.eql(u8, existing, text)) {
                    output.* = schema.schema;
                    return abi.result_ok;
                }
            }
        }
        var slot_index: ?usize = null;
        for (self.custom_schemas.items, 0..) |schema, index| {
            if (schema.name == null) {
                slot_index = index;
                break;
            }
        }
        const index = slot_index orelse blk: {
            if (self.custom_schemas.items.len >= abi.max_custom_events) return abi.result_limit;
            const new_index = self.custom_schemas.items.len;
            self.custom_schemas.append(self.allocator, .{ .name = null, .schema = 0, .plugin_id = 0 }) catch return abi.result_out_of_memory;
            break :blk new_index;
        };
        const copy = self.allocator.dupe(u8, text) catch return abi.result_out_of_memory;
        const version: u32 = if ((flags & 0xff) == 0) 1 else flags & 0xff;
        const schema = ((abi.event_custom_base + @as(u32, @intCast(index))) << 8) | version;
        self.custom_schemas.items[index] = .{ .name = copy, .schema = schema, .plugin_id = slot.plugin_id };
        output.* = schema;
        return abi.result_ok;
    }

    fn schemaLive(self: *PluginRuntime, schema: u32) bool {
        const event_id = schema >> 8;
        if (event_id < abi.event_custom_base) return false;
        const index = event_id - abi.event_custom_base;
        if (index >= self.custom_schemas.items.len) return false;
        return self.custom_schemas.items[index].name != null;
    }

    fn releaseSchemas(self: *PluginRuntime, plugin_id: u32) void {
        for (self.custom_schemas.items) |*schema| {
            if (schema.plugin_id != plugin_id) continue;
            if (schema.name) |name| self.allocator.free(name);
            schema.* = .{ .name = null, .schema = 0, .plugin_id = 0 };
        }
    }

    fn ensureDeferredRing(self: *PluginRuntime) ![]DeferredEmit {
        if (self.deferred_ring) |ring| return ring;
        const ring = try self.allocator.alloc(DeferredEmit, deferred_capacity);
        self.deferred_ring = ring;
        return ring;
    }

    fn emitCustom(context: ?*anyopaque, schema: u32, payload: ?*const anyopaque, payload_size: usize, flags: u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        if (!self.schemaLive(schema)) return abi.result_not_found;
        if (payload_size > abi.custom_payload_max) return abi.result_limit;
        if (payload_size > 0 and payload == null) return abi.result_invalid_argument;
        const ring = self.ensureDeferredRing() catch return abi.result_out_of_memory;
        if (self.deferred_len >= deferred_capacity) return abi.result_busy;
        const entry = &ring[self.deferred_tail];
        entry.schema = schema;
        entry.size = @intCast(payload_size);
        entry.flags = @truncate(flags);
        if (payload_size > 0) @memcpy(entry.payload[0..payload_size], @as([*]const u8, @ptrCast(payload.?))[0..payload_size]);
        self.deferred_tail = (self.deferred_tail + 1) % deferred_capacity;
        self.deferred_len += 1;
        return abi.result_ok;
    }

    fn emitImmediate(context: ?*anyopaque, schema: u32, payload: ?*const anyopaque, payload_size: usize, flags: u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        if (!self.schemaLive(schema)) return abi.result_not_found;
        if (payload_size > abi.custom_payload_max) return abi.result_limit;
        if (payload_size > 0 and payload == null) return abi.result_invalid_argument;
        if (self.depth >= max_emit_depth) return abi.result_busy;
        self.dispatchCustom(schema, payload, payload_size, @truncate(flags));
        return abi.result_ok;
    }

    fn dispatchCustom(self: *PluginRuntime, schema: u32, payload: ?*const anyopaque, payload_size: usize, flags: u16) void {
        const event_id = schema >> 8;
        if (event_id < abi.event_custom_base) return;
        const custom = event_id - abi.event_custom_base;
        if (custom >= abi.max_custom_events) return;
        const event_index: usize = event_count + custom;
        var result: i32 = @intFromEnum(abi.EventResult.continue_);
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
        inline for (0..3) |phase| {
            const view = abi.EventView{
                .data = if (payload_size == 0) null else payload,
                .data_size = payload_size,
                .result = &result,
                .schema = schema,
                .event_id = event_id,
                .phase = @intCast(phase),
                .flags = flags,
            };
            const captured = self.buckets[event_index][phase].items.len;
            var index: usize = 0;
            while (index < captured) : (index += 1) {
                const subscription = self.buckets[event_index][phase].items[index];
                if (!subscription.active or subscription.pending) continue;
                if (subscription.slot) |slot| slot.events_dispatched +%= 1;
                subscription.callback(subscription.userdata, &view);
            }
        }
    }

    pub fn endTick(self: *PluginRuntime) void {
        if (self.deferred_len == 0 or self.depth > 0) return;
        const ring = self.deferred_ring orelse return;
        const pending = self.deferred_len;
        var processed: usize = 0;
        while (processed < pending) : (processed += 1) {
            const entry = ring[self.deferred_head];
            self.deferred_head = (self.deferred_head + 1) % deferred_capacity;
            self.deferred_len -= 1;
            const payload: ?*const anyopaque = if (entry.size == 0) null else @ptrCast(&entry.payload);
            self.dispatchCustom(entry.schema, payload, entry.size, entry.flags);
        }
    }

    fn registriesBlockStates(context: ?*anyopaque, out_view: ?*abi.RegistryView) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = out_view orelse return abi.result_invalid_argument;
        if (self.block_state_entries == null) {
            const entry_count = BlockPermutation.count();
            if (entry_count == 0) {
                self.block_state_entries = &.{};
                self.block_state_entry_count = 0;
            } else {
                const entries = self.allocator.alloc(abi.BlockStateEntry, entry_count) catch return abi.result_out_of_memory;
                var written: usize = 0;
                var iterator = BlockPermutation.valueIterator();
                while (iterator.next()) |permutation| {
                    if (written >= entries.len) break;
                    const entry = permutation.*;
                    entries[written] = .{
                        .network_id = entry.network_id,
                        .reserved = 0,
                        .identifier = .{ .data = entry.identifier.ptr, .length = entry.identifier.len },
                    };
                    written += 1;
                }
                self.block_state_entries = entries;
                self.block_state_entry_count = written;
            }
        }
        const entries = self.block_state_entries.?;
        output.* = .{
            .data = @ptrCast(entries.ptr),
            .count = self.block_state_entry_count,
            .stride = @sizeOf(abi.BlockStateEntry),
            .element_version = 1,
            .reserved = 0,
        };
        return abi.result_ok;
    }

    fn registriesItems(context: ?*anyopaque, out_view: ?*abi.RegistryView) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = out_view orelse return abi.result_invalid_argument;
        if (self.item_entries == null) {
            const entry_count = ItemType.count();
            if (entry_count == 0) {
                self.item_entries = &.{};
                self.item_entry_count = 0;
            } else {
                const entries = self.allocator.alloc(abi.ItemEntry, entry_count) catch return abi.result_out_of_memory;
                var written: usize = 0;
                var iterator = ItemType.getAll().valueIterator();
                while (iterator.next()) |item| {
                    if (written >= entries.len) break;
                    const entry = item.*;
                    entries[written] = .{
                        .network_id = entry.network_id,
                        .max_stack_size = entry.max_stack_size,
                        .stackable = if (entry.stackable) 1 else 0,
                        .reserved = 0,
                        .identifier = .{ .data = entry.identifier.ptr, .length = entry.identifier.len },
                    };
                    written += 1;
                }
                self.item_entries = entries;
                self.item_entry_count = written;
            }
        }
        const entries = self.item_entries.?;
        output.* = .{
            .data = @ptrCast(entries.ptr),
            .count = self.item_entry_count,
            .stride = @sizeOf(abi.ItemEntry),
            .element_version = 1,
            .reserved = 0,
        };
        return abi.result_ok;
    }

    fn registriesEntityTypes(context: ?*anyopaque, out_view: ?*abi.RegistryView) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = out_view orelse return abi.result_invalid_argument;
        if (self.entity_type_entries == null) {
            const registry = EntityTypeRegistry.getRegistry();
            const entry_count = if (registry) |value| value.types.count() else 0;
            if (entry_count == 0) {
                self.entity_type_entries = &.{};
                self.entity_type_entry_count = 0;
            } else {
                const entries = self.allocator.alloc(abi.EntityTypeEntry, entry_count) catch return abi.result_out_of_memory;
                var written: usize = 0;
                var iterator = registry.?.types.valueIterator();
                while (iterator.next()) |entity_type| {
                    if (written >= entries.len) break;
                    entries[written] = .{
                        .network_id = entity_type.network_id,
                        .reserved = 0,
                        .identifier = .{ .data = entity_type.identifier.ptr, .length = entity_type.identifier.len },
                    };
                    written += 1;
                }
                self.entity_type_entries = entries;
                self.entity_type_entry_count = written;
            }
        }
        const entries = self.entity_type_entries.?;
        output.* = .{
            .data = @ptrCast(entries.ptr),
            .count = self.entity_type_entry_count,
            .stride = @sizeOf(abi.EntityTypeEntry),
            .element_version = 1,
            .reserved = 0,
        };
        return abi.result_ok;
    }

    fn commandRegister(_: ?*anyopaque, _: ?*const abi.CommandDesc, _: ?*u64) callconv(.c) i32 {
        return abi.result_unsupported;
    }

    fn commandUnregister(_: ?*anyopaque, _: u64) callconv(.c) i32 {
        return abi.result_unsupported;
    }

    fn commandMarkDirty(_: ?*anyopaque) callconv(.c) void {}

    pub fn timerLiveCount(self: *const PluginRuntime) u32 {
        const wheel = self.timer_wheel orelse return 0;
        return wheel.live;
    }

    pub fn deferredLen(self: *const PluginRuntime) usize {
        return self.deferred_len;
    }

    fn itemsCount(_: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        count_output.* = ItemType.getAll().count();
        return abi.result_ok;
    }

    fn itemsGetSnapshot(context: ?*anyopaque, index: usize, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.ItemSnapshot)) return abi.result_invalid_argument;
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

test "all thirteen interfaces negotiate major and minor versions" {
    try @import("runtime_test.zig").Suite(test_scope).case_002();
}

test "logging interface filters by level and truncates the scope" {
    try @import("runtime_test.zig").Suite(test_scope).case_003();
}

test "events interface shares subscribe and orders deferred custom emits" {
    try @import("runtime_test.zig").Suite(test_scope).case_004();
}

test "immediate custom emits stop at depth sixteen" {
    try @import("runtime_test.zig").Suite(test_scope).case_005();
}

test "registries return borrowed contiguous arrays" {
    try @import("runtime_test.zig").Suite(test_scope).case_006();
}

test "timer wheel fires every after and cancels by owner" {
    try @import("runtime_test.zig").Suite(test_scope).case_007();
}

test "custom subscription from a callback activates at depth zero" {
    try @import("runtime_test.zig").Suite(test_scope).case_008();
}

test "custom unsubscribe from a callback compacts at depth zero" {
    try @import("runtime_test.zig").Suite(test_scope).case_009();
}

test "cancel result respects the cancelable event flag" {
    try @import("runtime_test.zig").Suite(test_scope).case_010();
}

test "timer wheel reports busy at capacity and reuses freed slots" {
    try @import("runtime_test.zig").Suite(test_scope).case_011();
}

test "idle hook exists only while a bridge refresh is pending" {
    try @import("runtime_test.zig").Suite(test_scope).case_012();
}

test "hot paths do not allocate after cold materialization" {
    try @import("runtime_test.zig").Suite(test_scope).case_013();
}

test "core subscription from a custom callback installs the bridge at depth zero" {
    try @import("runtime_test.zig").Suite(test_scope).case_014();
}

test "core unsubscribe from a custom callback retires the bridge at depth zero" {
    try @import("runtime_test.zig").Suite(test_scope).case_015();
}

test "dispatch with zero subscribers installs no bridge" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 0), runtime.depth);
    try std.testing.expect(!events.hasListeners(.ServerTick));
    try std.testing.expectEqual(@as(u32, 0), runtime.active[@intFromEnum(abi.EventId.server_tick)][abi.event_phase_pre]);
    try std.testing.expectEqual(@as(u32, 0), runtime.bridge_total);
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
