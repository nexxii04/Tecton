const std = @import("std");
const logger = @import("../core/log.zig");
const builtin = @import("builtin");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");
const Tecton = @import("../tecton.zig").Tecton;
const Events = @import("../events/root.zig");
const World = @import("../world/world.zig").World;
const Command = @import("../command/command.zig").Command;
const CommandContext = @import("../command/context.zig").CommandContext;
const CommandRegistry = @import("../command/registry.zig").CommandRegistry;
const applyTraitsForBlock = @import("../world/block/traits/trait.zig").applyTraitsForBlock;
const block_broadcast = @import("../world/dimension/broadcast.zig");
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
const BlockType = @import("../world/block/block_type.zig").BlockType;
const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
const ItemType = @import("../items/item_type.zig").ItemType;
const EntityTypeRegistry = @import("../entity/entity_type_registry.zig").EntityTypeRegistry;

const MAX_PLUGIN_PACKET_BYTES: usize = 1 << 20;
const event_count = @typeInfo(Events.Event).@"enum".field_names.len;
const custom_event_count: usize = abi.max_custom_events;
const bucket_count = event_count + custom_event_count;
const deferred_capacity: usize = 1024;
const timer_wheel_slots: usize = 4096;
const timer_capacity: usize = 4096;
const timer_none: u32 = std.math.maxInt(u32);
const max_emit_depth: u32 = 16;
const allocation_checks = builtin.mode == .debug or builtin.mode == .release_safe;

const LiveBlock = struct {
    size: usize,
    alignment: usize,
    plugin_id: u32,
};

pub const PluginState = enum(u8) {
    unloaded,
    loading,
    loaded,
    starting,
    running,
    stopping,
    failed,
};

pub const LoadCounters = struct {
    loaded: u32 = 0,
    failed: u32 = 0,
    unloaded: u32 = 0,
    by_reason: [abi.load_reason_count]u32 = @splat(0),
};

pub const PluginSnapshot = struct {
    name: []const u8,
    state: PluginState,
    previous_state: PluginState,
    abi_major: u16,
    abi_minor: u16,
    fingerprint: u64,
    required_features: u64,
    optional_features: u64,
    load_reason: u32,
    load_detail: []const u8,
    events_dispatched: u64,
    tasks_run: u64,
    handles_owned: u32,
    commands_owned: u32,
};

pub const PluginRuntime = struct {
    allocator: std.mem.Allocator,
    tecton: ?*Tecton = null,
    events: ?*Events.Events = null,
    host: abi.HostApi,
    handles: Handles.Table,
    live_blocks: if (allocation_checks) std.AutoHashMapUnmanaged(usize, LiveBlock) else void = if (allocation_checks) .empty else {},
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
    counters: LoadCounters = .{},
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
    command_dirty: bool = false,
    command_broadcasts: u32 = 0,
    command_registry: ?*CommandRegistry = null,
    /// Snapshot cache for entities.get_by_index. It mirrors the dimension's hash
    /// map instead of acting as a stable dense cursor: the first access after
    /// `entity_serial` changes rebuilds it in O(n) and may allocate.
    entity_cache: std.ArrayList(*Entity) = .empty,
    entity_cache_dimension: ?*Dimension = null,
    entity_cache_serial: u64 = 0,

    pub const NATIVE_BRIDGE_OWNER_ID: u16 = 0xC001;

    pub const HostDiagnostics = struct {
        host: abi.HostApi,
        load_detail: [128]u8 = undefined,
        load_detail_len: u8 = 0,
        scope: [64]u8 = undefined,
        scope_len: u8 = 0,
        load_reason: u32 = abi.load_ok,
        abi_major: u16 = 0,
        abi_minor: u16 = 0,
        fingerprint: u64 = 0,
        required_features: u64 = 0,
        optional_features: u64 = 0,
        native: ?*NativePlugin = null,
    };

    pub const HostSlot = struct {
        runtime: *PluginRuntime,
        plugin_id: u32,
        state: PluginState = .unloaded,
        previous_state: PluginState = .unloaded,
        owns_handles: u32 = Handles.none,
        handles_owned: u32 = 0,
        commands_owned: u32 = 0,
        events_dispatched: u64 = 0,
        tasks_run: u64 = 0,
        host: *abi.HostApi = undefined,
        name: []const u8 = "",
        diagnostics: ?*HostDiagnostics = null,
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
        version: u8,
        live: bool,
        refs: u32 = 0,
        owners: [8]u32 = std.mem.zeroes([8]u32),
        owner_len: u8 = 0,

        fn hasOwner(self: *const CustomSchema, plugin_id: u32) bool {
            for (self.owners[0..self.owner_len]) |owner| {
                if (owner == plugin_id) return true;
            }
            return false;
        }

        fn addOwner(self: *CustomSchema, plugin_id: u32) void {
            if (self.hasOwner(plugin_id)) return;
            if (self.owner_len < self.owners.len) {
                self.owners[self.owner_len] = plugin_id;
                self.owner_len += 1;
            }
        }

        fn removeOwner(self: *CustomSchema, plugin_id: u32) void {
            for (self.owners[0..self.owner_len], 0..) |owner, index| {
                if (owner != plugin_id) continue;
                const last = self.owner_len - 1;
                self.owners[index] = self.owners[last];
                self.owner_len = last;
                return;
            }
        }
    };

    const DeferredEmit = extern struct {
        schema: u32,
        size: u16,
        flags: u16,
        payload: [abi.custom_payload_max]u8 align(8),
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
            .header = .{ .struct_size = @sizeOf(abi.WorldApi), .major = 1, .minor = 1, .interface_id = abi.interface_world, .reserved = 0, .features = abi.feature_world },
            .find = worldFind,
            .get_snapshot = worldGetSnapshot,
            .set_block = worldSetBlock,
            .get_block_state = worldGetBlockState,
            .set_block_state = worldSetBlockState,
            .for_each_in_box = worldForEachInBox,
        };
        runtime.players_api = .{
            .header = .{ .struct_size = @sizeOf(abi.PlayersApi), .major = 1, .minor = 1, .interface_id = abi.interface_players, .reserved = 0, .features = abi.feature_players },
            .count = playersCount,
            .get_snapshot = playersGetSnapshot,
            .get_by_index = playersGetByIndex,
            .get_by_runtime = playersGetByRuntime,
            .for_each = playersForEach,
        };
        runtime.entities_api = .{
            .header = .{ .struct_size = @sizeOf(abi.EntitiesApi), .major = 1, .minor = 1, .interface_id = abi.interface_entities, .reserved = 0, .features = abi.feature_entities },
            .count = entitiesCount,
            .get_snapshot = entitiesGetSnapshot,
            .get_by_index = entitiesGetByIndex,
            .get_by_runtime = entitiesGetByRuntime,
            .for_each = entitiesForEach,
        };
        runtime.items_api = .{
            .header = .{ .struct_size = @sizeOf(abi.ItemsApi), .major = 1, .minor = 1, .interface_id = abi.interface_items, .reserved = 0, .features = abi.feature_items },
            .count = itemsCount,
            .get_snapshot = itemsGetSnapshot,
            .get_by_index = itemsGetByIndex,
            .get_by_network_id = itemsGetByNetworkId,
            .for_each = itemsForEach,
        };
        runtime.blocks_api = .{
            .header = .{ .struct_size = @sizeOf(abi.BlocksApi), .major = 1, .minor = 1, .interface_id = abi.interface_blocks, .reserved = 0, .features = abi.feature_blocks },
            .get_snapshot = blocksGetSnapshot,
            .resolve_name = blocksResolveName,
        };
        runtime.inventories_api = .{
            .header = .{ .struct_size = @sizeOf(abi.InventoriesApi), .major = 1, .minor = 0, .interface_id = abi.interface_inventories, .reserved = 0, .features = abi.interfaceFeature(abi.interface_inventories) },
            .get_size = inventoryGetSize,
            .get_item = inventoryGetItem,
        };
        runtime.logging_api = .{
            .header = .{ .struct_size = @sizeOf(abi.LoggingApi), .major = 1, .minor = 0, .interface_id = abi.interface_logging, .reserved = 0, .features = abi.interfaceFeature(abi.interface_logging) },
            .log = log,
            .is_enabled = logIsEnabled,
            .set_level = logSetLevel,
            .set_scope = logSetScope,
        };
        runtime.events_api = .{
            .header = .{ .struct_size = @sizeOf(abi.EventsApi), .major = 1, .minor = 0, .interface_id = abi.interface_events, .reserved = 0, .features = abi.interfaceFeature(abi.interface_events) },
            .subscribe = eventSubscribe,
            .unsubscribe = eventUnsubscribe,
            .emit = emitCustom,
            .emit_immediate = emitImmediate,
            .schema_of = schemaOf,
        };
        runtime.scheduler_api = .{
            .header = .{ .struct_size = @sizeOf(abi.SchedulerApi), .major = 1, .minor = 0, .interface_id = abi.interface_scheduler, .reserved = 0, .features = abi.interfaceFeature(abi.interface_scheduler) },
            .after = schedulerAfter,
            .every = schedulerEvery,
            .cancel = schedulerCancel,
            .cancel_owner = schedulerCancelOwner,
        };
        runtime.network_api = .{
            .header = .{ .struct_size = @sizeOf(abi.NetworkApi), .major = 1, .minor = 0, .interface_id = abi.interface_network, .reserved = 0, .features = abi.interfaceFeature(abi.interface_network) },
            .send = networkSend,
            .broadcast = networkBroadcast,
        };
        runtime.registries_api = .{
            .header = .{ .struct_size = @sizeOf(abi.RegistriesApi), .major = 1, .minor = 0, .interface_id = abi.interface_registries, .reserved = 0, .features = abi.interfaceFeature(abi.interface_registries) },
            .block_states = registriesBlockStates,
            .items = registriesItems,
            .entity_types = registriesEntityTypes,
        };
        runtime.commands_api = .{
            .header = .{ .struct_size = @sizeOf(abi.CommandsApi), .major = 1, .minor = 1, .interface_id = abi.interface_commands, .reserved = 0, .features = abi.interfaceFeature(abi.interface_commands) },
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
        self.command_registry = &tecton.command_registry;
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
            const path = self.allocator.print("{s}/{s}", .{ directory_path, name }) catch {
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
            if (slot.diagnostics) |diagnostics| self.allocator.destroy(diagnostics);
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
        self.entity_cache.deinit(self.allocator);
        self.plugins.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.handles.deinit();
        if (comptime allocation_checks) self.live_blocks.deinit(self.allocator);
        self.tasks = null;
        self.command_registry = null;
        self.events = null;
        self.tecton = null;
    }

    pub fn count(self: *const PluginRuntime) usize {
        return self.plugins.items.len;
    }

    pub fn failedCount(self: *const PluginRuntime) usize {
        return self.counters.failed;
    }

    pub fn stateFor(self: *PluginRuntime, plugin_id: u32) ?PluginState {
        const slot = self.slotFor(plugin_id) orelse return null;
        return slot.state;
    }

    pub fn loadReasonFor(self: *PluginRuntime, plugin_id: u32) ?u32 {
        const slot = self.slotFor(plugin_id) orelse return null;
        const diagnostics = slot.diagnostics orelse return abi.load_ok;
        return diagnostics.load_reason;
    }

    pub fn loadDetailFor(self: *PluginRuntime, plugin_id: u32) ?[]const u8 {
        const slot = self.slotFor(plugin_id) orelse return null;
        const diagnostics = slot.diagnostics orelse return "";
        return diagnostics.load_detail[0..diagnostics.load_detail_len];
    }

    pub fn snapshotPlugins(self: *PluginRuntime, allocator: std.mem.Allocator) ![]PluginSnapshot {
        var total: usize = 0;
        for (self.slots.items) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            if (slot.state == .unloaded) continue;
            total += 1;
        }
        if (total == 0) return &.{};
        const snapshots = try allocator.alloc(PluginSnapshot, total);
        var index: usize = 0;
        for (self.slots.items) |maybe_slot| {
            const slot = maybe_slot orelse continue;
            if (slot.state == .unloaded) continue;
            const diagnostics = slot.diagnostics;
            snapshots[index] = .{
                .name = slot.name,
                .state = slot.state,
                .previous_state = slot.previous_state,
                .abi_major = if (diagnostics) |value| value.abi_major else 0,
                .abi_minor = if (diagnostics) |value| value.abi_minor else 0,
                .fingerprint = if (diagnostics) |value| value.fingerprint else 0,
                .required_features = if (diagnostics) |value| value.required_features else 0,
                .optional_features = if (diagnostics) |value| value.optional_features else 0,
                .load_reason = if (diagnostics) |value| value.load_reason else abi.load_ok,
                .load_detail = if (diagnostics) |value| value.load_detail[0..value.load_detail_len] else "",
                .events_dispatched = slot.events_dispatched,
                .tasks_run = slot.tasks_run,
                .handles_owned = @intCast(self.handles.countOwner(&slot.owns_handles)),
                .commands_owned = slot.commands_owned,
            };
            index += 1;
        }
        return snapshots;
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
            self.recordFailure(path, abi.load_out_of_memory, "slot allocation");
            return;
        };
        const diagnostics = self.allocator.create(HostDiagnostics) catch {
            self.allocator.destroy(slot);
            self.recordFailure(path, abi.load_out_of_memory, "slot diagnostics allocation");
            return;
        };
        diagnostics.* = .{ .host = self.host };
        slot.* = .{ .runtime = self, .plugin_id = self.next_id, .state = .loading, .host = &diagnostics.host, .diagnostics = diagnostics };
        diagnostics.host.userdata = @ptrCast(slot);
        diagnostics.host.plugin_id = slot.plugin_id;
        diagnostics.host.allocator.userdata = @ptrCast(slot);

        self.registerLoadingSlot(slot) catch {
            self.recordFailure(path, abi.load_out_of_memory, "slot table allocation");
            self.allocator.destroy(diagnostics);
            self.allocator.destroy(slot);
            return;
        };

        const native = self.allocator.create(NativePlugin) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "native allocation");
            return;
        };
        var result: native_loader.LoadResult = .{};
        native.* = NativePlugin.openDetailed(self.allocator, path, slot.host, slot.plugin_id, &result) catch |err| {
            diagnostics.abi_major = result.abi_major;
            diagnostics.abi_minor = result.abi_minor;
            diagnostics.fingerprint = result.fingerprint;
            self.allocator.destroy(native);
            self.failSlot(slot, path, failureReason(&result, err), failureDetail(&result, err));
            return;
        };
        diagnostics.native = native;
        diagnostics.abi_major = native.abi_major;
        diagnostics.abi_minor = native.abi_minor;
        diagnostics.fingerprint = native.fingerprint;
        diagnostics.required_features = native.required_features;
        diagnostics.optional_features = native.optional_features;

        const label = self.allocator.dupe(u8, abi.metadataName(native.descriptor)) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "name allocation");
            return;
        };
        slot.name = label;

        for (self.plugins.items) |existing| {
            if (std.mem.eql(u8, existing.name, label)) {
                self.failSlot(slot, path, abi.load_duplicate_name, "duplicate metadata name");
                return;
            }
        }

        native.loadWithDetail(&result) catch |err| {
            self.failSlot(slot, path, failureReason(&result, err), failureDetail(&result, err));
            return;
        };
        slot.state = .loaded;

        slot.state = .starting;
        result = .{};
        native.startWithDetail(&result) catch |err| {
            self.failSlot(slot, path, failureReason(&result, err), failureDetail(&result, err));
            return;
        };

        slot.state = .running;
        self.plugins.append(self.allocator, slot) catch {
            self.failSlot(slot, path, abi.load_out_of_memory, "plugin list allocation");
            return;
        };
        self.counters.loaded +%= 1;
        logger.info("[plugin:{s}] load: ok abi={d}.{d} fingerprint=0x{x} features=0x{x} path={s}", .{
            slot.name,
            diagnostics.abi_major,
            diagnostics.abi_minor,
            diagnostics.fingerprint,
            diagnostics.required_features | diagnostics.optional_features,
            path,
        });
    }

    fn readyAll(self: *PluginRuntime) void {
        for (self.plugins.items) |slot| {
            if (slot.state != .running) continue;
            if (slot.diagnostics) |diagnostics| {
                if (diagnostics.native) |native| native.ready();
            }
        }
        self.flushCommands();
    }

    fn registerLoadingSlot(self: *PluginRuntime, slot: *HostSlot) !void {
        try self.slots.ensureTotalCapacity(self.allocator, slot.plugin_id);
        self.slots.appendAssumeCapacity(slot);
        self.next_id += 1;
    }

    fn setLoadDetail(slot: *HostSlot, detail: []const u8) void {
        const diagnostics = slot.diagnostics orelse return;
        const length = @min(detail.len, diagnostics.load_detail.len);
        if (length > 0) @memcpy(diagnostics.load_detail[0..length], detail[0..length]);
        diagnostics.load_detail_len = @intCast(length);
    }

    fn failureReason(result: *const native_loader.LoadResult, err: native_loader.Error) u32 {
        if (result.reason != abi.load_ok) return result.reason;
        return native_loader.reasonCode(err);
    }

    fn failureDetail(result: *const native_loader.LoadResult, err: native_loader.Error) []const u8 {
        if (result.detail_len > 0) return result.detailSlice();
        return @errorName(err);
    }

    fn recordFailure(self: *PluginRuntime, path: []const u8, reason: u32, detail: []const u8) void {
        self.counters.failed +%= 1;
        if (reason < self.counters.by_reason.len) self.counters.by_reason[reason] +%= 1;
        self.logLoadFailure(std.fs.path.basename(path), path, reason, detail);
    }

    fn logLoadFailure(self: *PluginRuntime, name: []const u8, path: []const u8, reason: u32, detail: []const u8) void {
        _ = self;
        const text = if (detail.len == 0) "-" else detail;
        if (builtin.is_test) {
            logger.warn("[plugin:{s}] load: {s} ({s}) path={s}", .{ name, abi.loadReasonName(reason), text, path });
        } else {
            logger.err("[plugin:{s}] load: {s} ({s}) path={s}", .{ name, abi.loadReasonName(reason), text, path });
        }
    }

    fn failSlot(self: *PluginRuntime, slot: *HostSlot, path: []const u8, reason: u32, detail: []const u8) void {
        self.removeFromPlugins(slot);
        slot.previous_state = slot.state;
        self.teardownSlot(slot, .fault);
        slot.state = .failed;
        if (slot.diagnostics) |diagnostics| diagnostics.load_reason = reason;
        setLoadDetail(slot, detail);
        self.counters.failed +%= 1;
        if (reason < self.counters.by_reason.len) self.counters.by_reason[reason] +%= 1;
        if (slot.name.len == 0) slot.name = self.allocator.dupe(u8, std.fs.path.basename(path)) catch "";
        const name = if (slot.name.len > 0) slot.name else std.fs.path.basename(path);
        const detail_text = if (slot.diagnostics) |diagnostics| diagnostics.load_detail[0..diagnostics.load_detail_len] else "";
        self.logLoadFailure(name, path, reason, detail_text);
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
        if (slot.diagnostics) |diagnostics| {
            if (diagnostics.native) |native| native.shutdown(reason);
        }
        self.unregisterCommandsFor(slot.plugin_id);
        self.cancelTasksFor(slot.plugin_id);
        self.cancelTimersFor(slot.plugin_id);
        self.releaseSchemas(slot.plugin_id);
        self.removeSubscriptions(slot.plugin_id);
        _ = self.handles.removeOwner(slot.plugin_id, &slot.owns_handles);
        slot.handles_owned = 0;
        if (slot.diagnostics) |diagnostics| {
            if (diagnostics.native) |native| {
                native.deinit();
                self.allocator.destroy(native);
                diagnostics.native = null;
            }
        }
        self.reclaimBlocks(slot);
    }

    fn unloadSlot(self: *PluginRuntime, slot: *HostSlot, reason: abi.ShutdownReason) void {
        if (slot.state == .unloaded or slot.state == .failed) return;
        slot.handles_owned = @intCast(self.handles.countOwner(&slot.owns_handles));
        const handles = slot.handles_owned;
        const timers = self.timerCountFor(slot.plugin_id);
        const commands = slot.commands_owned;
        slot.state = .stopping;
        self.teardownSlot(slot, reason);
        self.removeFromPlugins(slot);
        if (slot.plugin_id > 0 and slot.plugin_id <= self.slots.items.len) {
            self.slots.items[@intCast(slot.plugin_id - 1)] = null;
        }
        logger.info("[plugin:{s}] unload: {s} handles={d} timers={d} commands={d}", .{
            slot.name,
            abi.shutdownReasonName(@backingInt(reason)),
            handles,
            timers,
            commands,
        });
        if (slot.name.len > 0) self.allocator.free(slot.name);
        if (slot.diagnostics) |diagnostics| self.allocator.destroy(diagnostics);
        slot.state = .unloaded;
        self.counters.unloaded +%= 1;
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
            if (custom >= self.custom_schemas.items.len or !self.custom_schemas.items[custom].live) return abi.result_not_found;
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
        const event_phase: Events.EventPhase = @fromBackingInt(@intCast(phase_index));
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
        const event_phase: Events.EventPhase = @fromBackingInt(@intCast(phase_index));
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
        const phase: usize = @backingInt(context.phase);
        if (self.active[event_index][phase] == 0) return .continue_;

        var result: i32 = @backingInt(abi.EventResult.continue_);
        var payload: abi.EventPayload = undefined;
        var payload_ptr: ?*const anyopaque = null;
        var payload_size: usize = 0;
        switch (event) {
            .ServerStart, .ServerShutdown => {},
            .ServerTick => {
                payload = .{ .server_tick = .{ .tick = data.tick } };
                payload_ptr = @ptrCast(&payload.server_tick);
                payload_size = meta.payload_size;
            },
            .PlayerJoin => {
                payload = .{ .player_join = .{ .handle = self.playerHandle(data.player), .runtime_id = data.player.entity.runtime_id } };
                payload_ptr = @ptrCast(&payload.player_join);
                payload_size = meta.payload_size;
            },
            .PlayerDisconnect => {
                payload = .{ .player_ref = .{ .handle = self.handles.handleFor(.player, @intFromPtr(data.player)) orelse 0, .runtime_id = data.player.entity.runtime_id } };
                payload_ptr = @ptrCast(&payload.player_ref);
                payload_size = meta.payload_size;
            },
            .PlayerChat => {
                payload = .{ .player_chat = .{ .runtime_id = data.player.entity.runtime_id, .message = .{ .data = if (data.message.len == 0) null else data.message.ptr, .length = data.message.len }, .flags = 0, .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.player_chat);
                payload_size = meta.payload_size;
            },
            .ItemUse => {
                payload = .{ .item_use = .{ .runtime_id = data.player.entity.runtime_id, .identifier = .{ .data = if (data.identifier.len == 0) null else data.identifier.ptr, .length = data.identifier.len }, .flags = 0, .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.item_use);
                payload_size = meta.payload_size;
            },
            .PlayerMove => {
                payload = .{ .player_move = .{
                    .runtime_id = data.player.entity.runtime_id,
                    .from_x = data.from.x,
                    .from_y = data.from.y,
                    .from_z = data.from.z,
                    .to_x = data.to.x,
                    .to_y = data.to.y,
                    .to_z = data.to.z,
                    .on_ground = if (data.player.on_ground) 1 else 0,
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.player_move);
                payload_size = meta.payload_size;
            },
            .Damage => {
                payload = .{ .damage = .{
                    .victim_runtime = data.victim.runtime_id,
                    .attacker_runtime = if (data.attacker) |attacker| attacker.runtime_id else 0,
                    .amount = data.amount,
                    .cause = @backingInt(data.cause),
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.damage);
                payload_size = meta.payload_size;
            },
            .EntityCombust => {
                payload = .{ .entity_combust = .{
                    .runtime_id = data.entity.runtime_id,
                    .instigator_runtime = if (data.instigator) |instigator| instigator.runtime_id else 0,
                    .duration = data.duration,
                    .source = @backingInt(data.source),
                } };
                payload_ptr = @ptrCast(&payload.entity_combust);
                payload_size = meta.payload_size;
            },
            .BlockPlace => {
                payload = .{ .block_place = .{
                    .runtime_id = data.player.entity.runtime_id,
                    .x = data.position.x,
                    .y = data.position.y,
                    .z = data.position.z,
                    .network_id = data.permutation.network_id,
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.block_place);
                payload_size = meta.payload_size;
            },
            .BlockBreak => {
                payload = .{ .block_break = .{
                    .runtime_id = data.player.entity.runtime_id,
                    .x = data.position.x,
                    .y = data.position.y,
                    .z = data.position.z,
                    .network_id = data.permutation.network_id,
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.block_break);
                payload_size = meta.payload_size;
            },
            .InventoryOpen, .InventoryClose => {
                payload = .{ .inventory = .{ .handle = self.playerHandle(data.player), .container_id = data.container_id, .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.inventory);
                payload_size = meta.payload_size;
            },
            .InventoryClick => {
                payload = .{ .inventory_click = .{ .handle = self.playerHandle(data.player), .slot = data.slot, .button = data.button, .reserved = 0, .reserved2 = 0 } };
                payload_ptr = @ptrCast(&payload.inventory_click);
                payload_size = meta.payload_size;
            },
            .TransactionPrepare, .TransactionCommit, .TransactionAbort => {
                payload = .{ .transaction = .{ .handle = self.playerHandle(data.player), .transaction_id = data.transaction_id, .committed = if (data.committed) 1 else 0, .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.transaction);
                payload_size = meta.payload_size;
            },
            .EnchantmentApply => {
                payload = .{ .enchant = .{
                    .item_handle = self.itemHandle(@ptrCast(data.stack)),
                    .actor_runtime = if (data.actor) |actor| actor.entity.runtime_id else 0,
                    .enchantment_id = data.definition.id,
                    .previous_level = data.previous_level orelse 0,
                    .level = data.level,
                    .source = @backingInt(data.source),
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.enchant);
                payload_size = meta.payload_size;
            },
            .EnchantmentRemove => {
                payload = .{ .enchant = .{
                    .item_handle = self.itemHandle(@ptrCast(data.stack)),
                    .actor_runtime = if (data.actor) |actor| actor.entity.runtime_id else 0,
                    .enchantment_id = if (data.definition) |definition| definition.id else data.definition_id,
                    .previous_level = data.previous_level,
                    .level = 0,
                    .source = @backingInt(data.source),
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.enchant);
                payload_size = meta.payload_size;
            },
            .EntitySpawn => {
                payload = .{ .entity_spawn = .{ .runtime_id = data.runtime_id, .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.entity_spawn);
                payload_size = meta.payload_size;
            },
            .EntityDespawn => {
                payload = .{ .entity_despawn = .{ .runtime_id = data.runtime_id, .cause = @backingInt(data.cause), .reserved = 0 } };
                payload_ptr = @ptrCast(&payload.entity_despawn);
                payload_size = meta.payload_size;
            },
            .EntityDamage => {
                payload = .{ .entity_damage = .{
                    .target_runtime = data.target_runtime,
                    .source_runtime = data.source_runtime orelse 0,
                    .amount = data.amount,
                    .cause = @backingInt(data.cause),
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.entity_damage);
                payload_size = meta.payload_size;
            },
            .EntityDeath => {
                payload = .{ .entity_death = .{
                    .runtime_id = data.runtime_id,
                    .killer_runtime = data.killer_runtime orelse 0,
                    .x = data.position.x,
                    .y = data.position.y,
                    .z = data.position.z,
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.entity_death);
                payload_size = meta.payload_size;
            },
            .EntityInteract => {
                payload = .{ .entity_interact = .{
                    .target_runtime = data.target_runtime,
                    .player_runtime = data.player.entity.runtime_id,
                    .action = @backingInt(data.action),
                    .reserved = 0,
                } };
                payload_ptr = @ptrCast(&payload.entity_interact);
                payload_size = meta.payload_size;
            },
        }

        defer if (builtin.mode == .debug and payload_ptr != null) @memset(@as([*]u8, @ptrCast(&payload))[0..payload_size], 0xDD);

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
            if (context.phase == .pre and (meta.flags & abi.event_flag_mutable) != 0) {
                switch (event) {
                    .PlayerChat => self.applyChatWriteBack(data, &payload.player_chat),
                    .PlayerMove => {
                        data.to.x = payload.player_move.to_x;
                        data.to.y = payload.player_move.to_y;
                        data.to.z = payload.player_move.to_z;
                    },
                    .Damage => data.amount = payload.damage.amount,
                    .EntityCombust => data.duration = payload.entity_combust.duration,
                    .EnchantmentApply => data.level = payload.enchant.level,
                    .EntityDamage => data.amount = payload.entity_damage.amount,
                    else => {},
                }
            }
            if (result != @backingInt(abi.EventResult.continue_) and (meta.flags & abi.event_flag_cancelable) != 0) return .cancel;
        }
        return .continue_;
    }

    // text.zig frees owned_message with network.allocator, which is the same allocator the runtime holds.
    fn applyChatWriteBack(self: *PluginRuntime, data: *Events.types.PlayerChatEvent, payload: *abi.PlayerChatEvent) void {
        const text = payload.message.slice();
        if (text.ptr == data.message.ptr and text.len == data.message.len) return;
        const copy = self.allocator.dupe(u8, text) catch return;
        if (data.owned_message) |previous| self.allocator.free(previous);
        data.message = copy;
        data.owned_message = copy;
        payload.message = .{ .data = copy.ptr, .length = copy.len };
    }

    fn playerHandle(self: *PluginRuntime, player: *Player) u64 {
        if (self.handles.handleFor(.player, @intFromPtr(player))) |handle| return handle;
        return self.handles.put(.player, @intFromPtr(player), 0, &self.handles.runtime_head) catch 0;
    }

    // Item handles are address-keyed and runtime-owned: ItemStack has no destruction hook in this
    // phase, so an address reused by a new stack resolves to that stack until the runtime exits.
    fn itemHandle(self: *PluginRuntime, item: *const anyopaque) u64 {
        if (self.handles.handleFor(.item, @intFromPtr(item))) |handle| return handle;
        return self.handles.put(.item, @intFromPtr(item), 0, &self.handles.runtime_head) catch 0;
    }

    const InterfaceSpec = struct {
        id: u32,
        field: []const u8,
    };

    const interface_specs = [_]InterfaceSpec{
        .{ .id = abi.interface_core, .field = "core_api" },
        .{ .id = abi.interface_logging, .field = "logging_api" },
        .{ .id = abi.interface_events, .field = "events_api" },
        .{ .id = abi.interface_scheduler, .field = "scheduler_api" },
        .{ .id = abi.interface_world, .field = "world_api" },
        .{ .id = abi.interface_players, .field = "players_api" },
        .{ .id = abi.interface_entities, .field = "entities_api" },
        .{ .id = abi.interface_items, .field = "items_api" },
        .{ .id = abi.interface_blocks, .field = "blocks_api" },
        .{ .id = abi.interface_inventories, .field = "inventories_api" },
        .{ .id = abi.interface_registries, .field = "registries_api" },
        .{ .id = abi.interface_network, .field = "network_api" },
        .{ .id = abi.interface_commands, .field = "commands_api" },
    };

    fn getInterface(context: ?*anyopaque, interface_id: u32, major: u16, minor: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = interface orelse return abi.result_invalid_argument;
        output.* = null;
        inline for (interface_specs) |spec| {
            if (spec.id == interface_id) {
                const served: *const abi.InterfaceHeader = @ptrCast(&@field(self, spec.field));
                if (major != served.major or minor > served.minor) return abi.result_version;
                output.* = served;
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
        if (interval == 0) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        return scheduleTimer(context, interval, interval, callback, callback_userdata, timer);
    }

    fn scheduleTimer(context: ?*anyopaque, delay: u32, interval: u32, callback: ?abi.TimerCallbackFn, callback_userdata: ?*anyopaque, timer: ?*u64) i32 {
        const slot = slotFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const callback_value = callback orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = timer orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const self = slot.runtime;
        const wheel = if (self.timer_wheel) |wheel| wheel else self.ensureTimerWheel() catch {
            @branchHint(.unlikely);
            return abi.result_out_of_memory;
        };
        const next_tick = self.timer_tick + @as(u64, delay);
        const handle = self.insertTimer(wheel, next_tick, interval, callback_value, callback_userdata, slot.plugin_id) catch {
            @branchHint(.unlikely);
            return abi.result_busy;
        };
        output.* = handle;
        return abi.result_ok;
    }

    fn schedulerCancel(context: ?*anyopaque, handle: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const self = slot.runtime;
        const wheel = self.timer_wheel orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const index: u32 = @intCast(handle & 0xffff_ffff);
        const generation: u32 = @intCast(handle >> 32);
        if (index >= wheel.slots.items.len) {
            @branchHint(.unlikely);
            return abi.result_not_found;
        }
        const timer = &wheel.slots.items[index];
        if (!timer.active or timer.generation != generation or timer.plugin_id != slot.plugin_id) {
            @branchHint(.unlikely);
            return abi.result_not_found;
        }
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
            @backingInt(abi.EventId.server_start) => .ServerStart,
            @backingInt(abi.EventId.server_shutdown) => .ServerShutdown,
            @backingInt(abi.EventId.server_tick) => .ServerTick,
            @backingInt(abi.EventId.player_join) => .PlayerJoin,
            @backingInt(abi.EventId.player_disconnect) => .PlayerDisconnect,
            @backingInt(abi.EventId.player_chat) => .PlayerChat,
            @backingInt(abi.EventId.item_use) => .ItemUse,
            @backingInt(abi.EventId.player_move) => .PlayerMove,
            @backingInt(abi.EventId.damage) => .Damage,
            @backingInt(abi.EventId.block_place) => .BlockPlace,
            @backingInt(abi.EventId.block_break) => .BlockBreak,
            @backingInt(abi.EventId.inventory_open) => .InventoryOpen,
            @backingInt(abi.EventId.inventory_click) => .InventoryClick,
            @backingInt(abi.EventId.inventory_close) => .InventoryClose,
            @backingInt(abi.EventId.transaction_prepare) => .TransactionPrepare,
            @backingInt(abi.EventId.transaction_commit) => .TransactionCommit,
            @backingInt(abi.EventId.transaction_abort) => .TransactionAbort,
            @backingInt(abi.EventId.entity_combust) => .EntityCombust,
            @backingInt(abi.EventId.enchantment_apply) => .EnchantmentApply,
            @backingInt(abi.EventId.enchantment_remove) => .EnchantmentRemove,
            @backingInt(abi.EventId.entity_spawn) => .EntitySpawn,
            @backingInt(abi.EventId.entity_despawn) => .EntityDespawn,
            @backingInt(abi.EventId.entity_damage) => .EntityDamage,
            @backingInt(abi.EventId.entity_death) => .EntityDeath,
            @backingInt(abi.EventId.entity_interact) => .EntityInteract,
            else => null,
        };
    }

    fn externalEventId(event: Events.Event) ?abi.EventId {
        return switch (event) {
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
            .EntityCombust => .entity_combust,
            .EnchantmentApply => .enchantment_apply,
            .EnchantmentRemove => .enchantment_remove,
            .EntitySpawn => .entity_spawn,
            .EntityDespawn => .entity_despawn,
            .EntityDamage => .entity_damage,
            .EntityDeath => .entity_death,
            .EntityInteract => .entity_interact,
        };
    }

    fn isPluginFile(name: []const u8) bool {
        if (builtin.os.tag == .windows) return std.mem.endsWith(u8, name, ".dll");
        if (builtin.os.tag == .macos) return std.mem.endsWith(u8, name, ".dylib");
        return std.mem.endsWith(u8, name, ".so");
    }

    const BlockSpan = struct {
        size: usize,
        alignment: usize,
    };

    fn trackBlock(self: *PluginRuntime, plugin_id: u32, memory: *anyopaque, size: usize, alignment: usize) bool {
        if (comptime allocation_checks) {
            self.live_blocks.put(self.allocator, @intFromPtr(memory), .{ .size = size, .alignment = alignment, .plugin_id = plugin_id }) catch return false;
        }
        return true;
    }

    fn blockSpan(self: *PluginRuntime, slot: *HostSlot, memory: *anyopaque, size: usize, alignment: usize) BlockSpan {
        if (comptime allocation_checks) {
            if (self.live_blocks.get(@intFromPtr(memory))) |entry| {
                if (entry.size != size or entry.alignment != alignment) {
                    logger.warn("[plugin:{s}] allocator: size={d} alignment={d} expected={d}/{d}", .{ slot.name, size, alignment, entry.size, entry.alignment });
                    return .{ .size = entry.size, .alignment = entry.alignment };
                }
                return .{ .size = size, .alignment = alignment };
            }
            logger.warn("[plugin:{s}] allocator: untracked block size={d} alignment={d}", .{ slot.name, size, alignment });
        }
        return .{ .size = size, .alignment = alignment };
    }

    fn reclaimBlocks(self: *PluginRuntime, slot: *HostSlot) void {
        if (comptime allocation_checks) {
            var live_count: usize = 0;
            var bytes: usize = 0;
            var scan = self.live_blocks.iterator();
            while (scan.next()) |entry| {
                if (entry.value_ptr.plugin_id != slot.plugin_id) continue;
                live_count += 1;
                bytes += entry.value_ptr.size;
            }
            if (live_count == 0) return;
            logger.warn("[plugin:{s}] allocator: reclaiming {d} live blocks ({d} bytes)", .{ slot.name, live_count, bytes });
            while (true) {
                var key: ?usize = null;
                var iterator = self.live_blocks.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.plugin_id != slot.plugin_id) continue;
                    key = entry.key_ptr.*;
                    break;
                }
                const found = key orelse return;
                const released = self.live_blocks.fetchRemove(found) orelse return;
                self.allocator.rawFree(@as([*]u8, @ptrFromInt(found))[0..released.value.size], .fromByteUnits(released.value.alignment), @returnAddress());
            }
        }
    }

    fn allocate(context: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const slot = slotFrom(context) orelse return null;
        const self = slot.runtime;
        if (size == 0) return null;

        const aligned = @max(alignment, 1);
        const memory = self.allocator.rawAlloc(size, .fromByteUnits(aligned), @returnAddress()) orelse return null;
        if (comptime allocation_checks) {
            if (!self.trackBlock(slot.plugin_id, memory, size, aligned)) {
                self.allocator.rawFree(@as([*]u8, @ptrCast(memory))[0..size], .fromByteUnits(aligned), @returnAddress());
                return null;
            }
        }
        return memory;
    }

    fn free(context: ?*anyopaque, memory: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const slot = slotFrom(context) orelse return;
        const self = slot.runtime;
        if (size == 0) return;

        const ptr = memory orelse return;
        const span = self.blockSpan(slot, ptr, size, @max(alignment, 1));
        if (comptime allocation_checks) _ = self.live_blocks.remove(@intFromPtr(ptr));
        self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..span.size], .fromByteUnits(span.alignment), @returnAddress());
    }

    fn reallocate(context: ?*anyopaque, memory: ?*anyopaque, old_size: usize, new_size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const slot = slotFrom(context) orelse return null;
        const self = slot.runtime;
        const aligned = @max(alignment, 1);
        if (new_size == 0) {
            if (memory) |ptr| {
                const span = self.blockSpan(slot, ptr, old_size, aligned);
                if (comptime allocation_checks) _ = self.live_blocks.remove(@intFromPtr(ptr));
                self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..span.size], .fromByteUnits(span.alignment), @returnAddress());
            }
            return null;
        }
        var source = BlockSpan{ .size = old_size, .alignment = aligned };
        if (memory) |ptr| source = self.blockSpan(slot, ptr, old_size, aligned);
        const replacement = self.allocator.rawAlloc(new_size, .fromByteUnits(aligned), @returnAddress()) orelse return null;
        if (comptime allocation_checks) {
            if (!self.trackBlock(slot.plugin_id, replacement, new_size, aligned)) {
                self.allocator.rawFree(@as([*]u8, @ptrCast(replacement))[0..new_size], .fromByteUnits(aligned), @returnAddress());
                return null;
            }
        }
        if (memory) |ptr| {
            const copy_size = @min(source.size, new_size);
            @memcpy(@as([*]u8, @ptrCast(replacement))[0..copy_size], @as([*]const u8, @ptrCast(ptr))[0..copy_size]);
            if (comptime allocation_checks) _ = self.live_blocks.remove(@intFromPtr(ptr));
            self.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..source.size], .fromByteUnits(source.alignment), @returnAddress());
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
        const diagnostics = slot.diagnostics;
        const scope_len: u8 = if (diagnostics) |value| value.scope_len else 0;
        if (scope_len == 0) {
            switch (level) {
                abi.log_trace, abi.log_debug => logger.debug("[plugin:{s}] {s}", .{ slot.name, text }),
                abi.log_info => logger.info("[plugin:{s}] {s}", .{ slot.name, text }),
                abi.log_warn => logger.warn("[plugin:{s}] {s}", .{ slot.name, text }),
                else => logger.err("[plugin:{s}] {s}", .{ slot.name, text }),
            }
            return;
        }
        const scope = diagnostics.?.scope[0..scope_len];
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
        const diagnostics = slot.diagnostics orelse return;
        const scope = value.slice();
        const length = @min(scope.len, diagnostics.scope.len);
        if (length > 0) @memcpy(diagnostics.scope[0..length], scope[0..length]);
        diagnostics.scope_len = @intCast(length);
    }

    // The low byte of flags is the version; the upper bits are reserved and rejected instead of truncated.
    fn schemaOf(context: ?*anyopaque, name: abi.StringView, flags: u32, out_schema: ?*u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const output = out_schema orelse return abi.result_invalid_argument;
        const text = name.slice();
        if (text.len == 0 or text.len > 96) return abi.result_invalid_argument;
        if ((flags & ~@as(u32, 0xff)) != 0) return abi.result_invalid_argument;
        const version: u8 = if ((flags & 0xff) == 0) 1 else @truncate(flags);
        for (self.custom_schemas.items) |*schema| {
            if (!schema.live) continue;
            const existing = schema.name orelse continue;
            if (schema.version != version or !std.mem.eql(u8, existing, text)) continue;
            if (!schema.hasOwner(slot.plugin_id)) {
                if (schema.owner_len == schema.owners.len) return abi.result_limit;
                schema.addOwner(slot.plugin_id);
                schema.refs += 1;
            }
            output.* = schema.schema;
            return abi.result_ok;
        }
        if (self.custom_schemas.items.len >= abi.max_custom_events) return abi.result_limit;
        const copy = self.allocator.dupe(u8, text) catch return abi.result_out_of_memory;
        const index = self.custom_schemas.items.len;
        const schema = ((abi.event_custom_base + @as(u32, @intCast(index))) << 8) | version;
        var entry = CustomSchema{ .name = copy, .schema = schema, .version = version, .live = true, .refs = 1 };
        entry.addOwner(slot.plugin_id);
        self.custom_schemas.append(self.allocator, entry) catch {
            self.allocator.free(copy);
            return abi.result_out_of_memory;
        };
        output.* = schema;
        return abi.result_ok;
    }

    fn schemaLive(self: *PluginRuntime, schema: u32) bool {
        const event_id = schema >> 8;
        if (event_id < abi.event_custom_base) return false;
        const index = event_id - abi.event_custom_base;
        if (index >= self.custom_schemas.items.len) return false;
        const entry = &self.custom_schemas.items[index];
        if (!entry.live or entry.schema != schema) return false;
        return entry.version == @as(u8, @truncate(schema));
    }

    fn releaseSchemas(self: *PluginRuntime, plugin_id: u32) void {
        for (self.custom_schemas.items, 0..) |*schema, index| {
            if (!schema.live or !schema.hasOwner(plugin_id)) continue;
            schema.removeOwner(plugin_id);
            schema.refs -= 1;
            if (schema.refs > 0) continue;
            const schema_id = schema.schema;
            self.allocator.free(schema.name.?);
            schema.name = null;
            schema.live = false;
            self.retireCustom(index, schema_id);
        }
    }

    fn retireCustom(self: *PluginRuntime, index: usize, schema: u32) void {
        const event_index = event_count + index;
        for (0..3) |phase| {
            var changed = false;
            for (self.buckets[event_index][phase].items) |*subscription| {
                if (!subscription.active) continue;
                subscription.active = false;
                self.dead[event_index][phase] += 1;
                self.dead_total += 1;
                if (self.active[event_index][phase] > 0) self.active[event_index][phase] -= 1;
                if (self.depth > 0 and self.active[event_index][phase] == 0) self.markRetire(event_index, phase);
                changed = true;
            }
            if (changed and self.depth == 0) self.compactBucket(event_index, phase, false);
        }
        const ring = self.deferred_ring orelse return;
        for (ring) |*entry| {
            if (entry.schema != schema) continue;
            entry.schema = 0;
            entry.size = 0;
        }
    }

    fn ensureDeferredRing(self: *PluginRuntime) ![]DeferredEmit {
        if (self.deferred_ring) |ring| return ring;
        const ring = try self.allocator.alloc(DeferredEmit, deferred_capacity);
        self.deferred_ring = ring;
        return ring;
    }

    fn emitCustom(context: ?*anyopaque, schema: u32, payload: ?*const anyopaque, payload_size: usize, flags: u32) callconv(.c) i32 {
        const slot = slotFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const self = slot.runtime;
        if (!self.schemaLive(schema)) {
            @branchHint(.unlikely);
            return abi.result_not_found;
        }
        if (payload_size > abi.custom_payload_max) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        if (payload_size > 0 and payload == null) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const ring = self.ensureDeferredRing() catch {
            @branchHint(.unlikely);
            return abi.result_out_of_memory;
        };
        if (self.deferred_len >= deferred_capacity) {
            @branchHint(.unlikely);
            return abi.result_busy;
        }
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
        const slot = slotFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const self = slot.runtime;
        if (!self.schemaLive(schema)) {
            @branchHint(.unlikely);
            return abi.result_not_found;
        }
        if (payload_size > 0 and payload == null) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        if (self.depth >= max_emit_depth) {
            @branchHint(.unlikely);
            return abi.result_busy;
        }
        self.dispatchCustom(schema, payload, payload_size, @truncate(flags));
        return abi.result_ok;
    }

    fn dispatchCustom(self: *PluginRuntime, schema: u32, payload: ?*const anyopaque, payload_size: usize, flags: u16) void {
        const event_id = schema >> 8;
        if (event_id < abi.event_custom_base) return;
        const custom = event_id - abi.event_custom_base;
        if (custom >= abi.max_custom_events) return;
        const event_index: usize = event_count + custom;
        var result: i32 = @backingInt(abi.EventResult.continue_);
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
        if (self.deferred_len != 0 and self.depth == 0) {
            if (self.deferred_ring) |ring| {
                const pending = self.deferred_len;
                var processed: usize = 0;
                while (processed < pending) : (processed += 1) {
                    var entry = ring[self.deferred_head];
                    self.deferred_head = (self.deferred_head + 1) % deferred_capacity;
                    self.deferred_len -= 1;
                    const payload: ?*const anyopaque = if (entry.size == 0) null else @ptrCast(&entry.payload);
                    if (self.schemaLive(entry.schema)) self.dispatchCustom(entry.schema, payload, entry.size, entry.flags);
                    if (builtin.mode == .debug) @memset(entry.payload[0..entry.size], 0xDD);
                }
            }
        }
        // Deferred callbacks may register commands; flushing here keeps them in
        // the same tick instead of waiting for the next one.
        self.flushCommands();
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

    const OwnedCommandStrings = struct {
        allocator: std.mem.Allocator,
        name: []u8,
        description: []u8,
        permission: []u8,
        aliases: [][]const u8,
        alias_len: usize,

        fn deinit(self: *OwnedCommandStrings) void {
            self.allocator.free(self.name);
            self.allocator.free(self.description);
            self.allocator.free(self.permission);
            for (self.aliases[0..self.alias_len]) |alias| self.allocator.free(alias);
            self.allocator.free(self.aliases);
        }
    };

    fn stringView(value: []const u8) abi.StringView {
        return .{ .data = if (value.len == 0) null else value.ptr, .length = value.len };
    }

    fn validCommandName(name: []const u8) bool {
        if (name.len == 0 or name.len > 31) return false;
        for (name) |c| {
            if (c >= 'A' and c <= 'Z') return false;
            if (c <= 0x20 or c >= 0x7f) return false;
            if (c == '/') return false;
        }
        return true;
    }

    fn commandTrampoline(raw: *anyopaque) void {
        const ctx: *CommandContext = @ptrCast(@alignCast(raw));
        const cmd = ctx.command orelse return;
        const handler: abi.CommandHandlerFn = @ptrCast(cmd.plugin_handler orelse return);
        const self: *PluginRuntime = @ptrCast(@alignCast(cmd.plugin_runtime orelse return));
        var argc: usize = 1;
        var count_tokens = std.mem.tokenizeAny(u8, ctx.args, " \t");
        while (count_tokens.next()) |_| argc += 1;
        const argv = ctx.allocator.alloc(abi.StringView, argc) catch {
            ctx.sendOutput(false, "Command execution failed");
            return;
        };
        defer ctx.allocator.free(argv);
        argv[0] = stringView(cmd.name);
        var index: usize = 1;
        var tokens = std.mem.tokenizeAny(u8, ctx.args, " \t");
        while (tokens.next()) |token| : (index += 1) argv[index] = stringView(token);
        const player_handle = if (ctx.player) |player| self.handles.handleFor(.player, @intFromPtr(player)) orelse 0 else 0;
        const world_handle = if (ctx.player) |player| blk: {
            const dimension = player.entity.dimension orelse break :blk 0;
            break :blk self.handles.handleFor(.world, @intFromPtr(dimension.world)) orelse 0;
        } else 0;
        const call = abi.CommandCall{
            .struct_size = @sizeOf(abi.CommandCall),
            .argc = @intCast(argv.len),
            .argv = argv.ptr,
            .raw_line = stringView(ctx.raw_line),
            .player = player_handle,
            .world = world_handle,
            .userdata = cmd.userdata,
        };
        if (handler(&call) != abi.result_ok) ctx.sendOutput(false, "Command execution failed");
    }

    pub fn commandRegister(context: ?*anyopaque, desc: ?*const abi.CommandDesc, out_command: ?*u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const value = desc orelse return abi.result_invalid_argument;
        const output = out_command orelse return abi.result_invalid_argument;
        if (value.struct_size < @sizeOf(abi.CommandDesc) or value.flags != 0) return abi.result_invalid_argument;
        const handler = value.handler orelse return abi.result_invalid_argument;
        if (!validCommandName(value.name.slice())) return abi.result_invalid_argument;
        if (value.alias_count > 0 and value.aliases == null) return abi.result_invalid_argument;
        const self = slot.runtime;
        const registry = self.command_registry orelse return abi.result_not_found;
        const allocator = self.allocator;
        var owned = OwnedCommandStrings{
            .allocator = allocator,
            .name = allocator.dupe(u8, value.name.slice()) catch return abi.result_out_of_memory,
            .description = undefined,
            .permission = undefined,
            .aliases = undefined,
            .alias_len = 0,
        };
        owned.description = allocator.dupe(u8, value.description.slice()) catch {
            allocator.free(owned.name);
            return abi.result_out_of_memory;
        };
        owned.permission = allocator.dupe(u8, value.permission.slice()) catch {
            allocator.free(owned.name);
            allocator.free(owned.description);
            return abi.result_out_of_memory;
        };
        owned.aliases = allocator.alloc([]const u8, value.alias_count) catch {
            allocator.free(owned.name);
            allocator.free(owned.description);
            allocator.free(owned.permission);
            return abi.result_out_of_memory;
        };
        for (0..value.alias_count) |alias_index| {
            const alias = value.aliases.?[alias_index].slice();
            if (!validCommandName(alias)) {
                owned.deinit();
                return abi.result_invalid_argument;
            }
            const copy = allocator.dupe(u8, alias) catch {
                owned.deinit();
                return abi.result_out_of_memory;
            };
            owned.aliases[alias_index] = copy;
            owned.alias_len = alias_index + 1;
        }
        const cmd = Command.init(allocator, owned.name, owned.description, owned.permission, owned.aliases, commandTrampoline) catch {
            owned.deinit();
            return abi.result_out_of_memory;
        };
        cmd.owned_strings = true;
        cmd.owner_plugin_id = slot.plugin_id;
        cmd.plugin_handler = @ptrCast(handler);
        cmd.plugin_runtime = @ptrCast(self);
        cmd.userdata = value.userdata;
        registry.registerOwnedCommand(cmd) catch |err| {
            cmd.deinit();
            return switch (err) {
                error.Conflict => abi.result_conflict,
                else => abi.result_out_of_memory,
            };
        };
        const handle = self.handles.put(.command, @intFromPtr(cmd), slot.plugin_id, &slot.owns_handles) catch {
            registry.unregisterCommand(cmd);
            return abi.result_out_of_memory;
        };
        slot.commands_owned +%= 1;
        registry.markDirty();
        self.command_dirty = true;
        output.* = handle;
        return abi.result_ok;
    }

    fn commandUnregister(context: ?*anyopaque, command: u64) callconv(.c) i32 {
        const slot = slotFrom(context) orelse return abi.result_invalid_argument;
        const self = slot.runtime;
        const marker = self.handles.get(.command, command) orelse return abi.result_invalid_handle;
        if (self.handles.ownerOf(marker) != slot.plugin_id) return abi.result_invalid_handle;
        const registry = self.command_registry orelse return abi.result_not_found;
        _ = self.handles.remove(.command, command);
        registry.unregisterCommand(@ptrFromInt(marker));
        if (slot.commands_owned > 0) slot.commands_owned -= 1;
        registry.markDirty();
        self.command_dirty = true;
        return abi.result_ok;
    }

    fn commandMarkDirty(context: ?*anyopaque) callconv(.c) void {
        const slot = slotFrom(context) orelse return;
        const registry = slot.runtime.command_registry orelse return;
        registry.markDirty();
        slot.runtime.command_dirty = true;
    }

    pub fn unregisterCommandsFor(self: *PluginRuntime, plugin_id: u32) void {
        const registry = self.command_registry orelse return;
        const removed = registry.removeOwned(plugin_id);
        if (removed == 0) return;
        if (self.slotFor(plugin_id)) |slot| {
            const removed_count: u32 = @intCast(removed);
            if (slot.commands_owned >= removed_count) slot.commands_owned -= removed_count else slot.commands_owned = 0;
        }
        registry.markDirty();
        self.command_dirty = true;
    }

    pub fn flushCommands(self: *PluginRuntime) void {
        if (!self.command_dirty) return;
        self.command_dirty = false;
        if (self.command_registry) |registry| _ = registry.consumeDirty();
        if (self.tecton) |tecton| tecton.broadcastAvailableCommands();
        self.command_broadcasts +%= 1;
    }

    pub fn timerLiveCount(self: *const PluginRuntime) u32 {
        const wheel = self.timer_wheel orelse return 0;
        return wheel.live;
    }

    fn timerCountFor(self: *const PluginRuntime, plugin_id: u32) u32 {
        const wheel = self.timer_wheel orelse return 0;
        var total: u32 = 0;
        for (wheel.slots.items) |timer| {
            if (timer.active and timer.plugin_id == plugin_id) total += 1;
        }
        return total;
    }

    pub fn deferredLen(self: *const PluginRuntime) usize {
        return self.deferred_len;
    }

    fn itemsCount(_: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        count_output.* = ItemType.count();
        return abi.result_ok;
    }

    fn fillItemSnapshot(item: *const ItemType, handle: u64, output: *abi.ItemSnapshot) void {
        output.* = .{
            .header = .{ .struct_size = @sizeOf(abi.ItemSnapshot), .version = 1, .reserved = 0 },
            .handle = handle,
            .network_id = item.network_id,
            .max_stack_size = item.max_stack_size,
            .stackable = if (item.stackable) 1 else 0,
            .reserved = @splat(0),
            .identifier = stringView(item.identifier),
        };
    }

    fn itemsGetSnapshot(context: ?*anyopaque, handle: u64, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.ItemSnapshot)) return abi.result_invalid_argument;
        const pointer = self.handles.get(.item, handle) orelse return abi.result_invalid_handle;
        const item: *ItemType = @ptrFromInt(pointer);
        fillItemSnapshot(item, handle, output);
        return abi.result_ok;
    }

    fn itemsGetByIndex(context: ?*anyopaque, index: usize, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = snapshot orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        if (snapshot_size < @sizeOf(abi.ItemSnapshot)) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const item = ItemType.at(index) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        fillItemSnapshot(item, self.handles.handleFor(.item, @intFromPtr(item)) orelse 0, output);
        return abi.result_ok;
    }

    fn itemsGetByNetworkId(context: ?*anyopaque, network_id: i32, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = snapshot orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        if (snapshot_size < @sizeOf(abi.ItemSnapshot)) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const item = ItemType.getByNetworkId(network_id) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        fillItemSnapshot(item, self.handles.handleFor(.item, @intFromPtr(item)) orelse 0, output);
        return abi.result_ok;
    }

    fn itemsForEach(context: ?*anyopaque, callback: ?abi.ItemCallbackFn, callback_userdata: ?*anyopaque) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const cb = callback orelse return abi.result_invalid_argument;
        for (ItemType.denseItems()) |item| {
            var snapshot: abi.ItemSnapshot = undefined;
            fillItemSnapshot(item, self.handles.handleFor(.item, @intFromPtr(item)) orelse 0, &snapshot);
            cb(callback_userdata, &snapshot);
        }
        return abi.result_ok;
    }

    fn blocksGetSnapshot(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, x: i32, y: i32, z: i32, snapshot: ?*abi.BlockSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.BlockSnapshot)) return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        const permutation = readBlockPermutation(dimension, x, y, z) orelse return abi.result_not_found;
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
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 1, .reserved = @splat(0), .count = value.stack_size, .reserved_count = 0, .network_id = value.item_type.network_id, .metadata = value.metadata, .identifier = .{ .data = value.item_type.identifier.ptr, .length = value.item_type.identifier.len } };
        } else {
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 0, .reserved = @splat(0), .count = 0, .reserved_count = 0, .network_id = 0, .metadata = 0, .identifier = .{} };
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
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const tecton = self.tecton orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        count_output.* = tecton.getPlayerCount();
        return abi.result_ok;
    }

    fn fillPlayerSnapshot(self: *PluginRuntime, player: *Player, handle: u64, output: *abi.PlayerSnapshot) void {
        const dimension = player.entity.dimension;
        output.* = .{
            .header = .{ .struct_size = @sizeOf(abi.PlayerSnapshot), .version = 1, .reserved = 0 },
            .handle = handle,
            .runtime_id = player.entity.runtime_id,
            .name = stringView(player.username),
            .uuid = stringView(player.uuid[0..]),
            .world = if (dimension) |value| self.handles.handleFor(.world, @intFromPtr(value.world)) orelse 0 else 0,
            .dimension = if (dimension) |value| stringView(value.identifier) else .{},
            .x = player.entity.position.x,
            .y = player.entity.position.y,
            .z = player.entity.position.z,
            .yaw = player.entity.rotation.y,
            .pitch = player.entity.rotation.x,
            .gamemode = @intCast(@backingInt(player.gamemode)),
            .spawned = if (player.spawned) 1 else 0,
        };
    }

    fn playersGetSnapshot(context: ?*anyopaque, handle: u64, snapshot: ?*abi.PlayerSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = snapshot orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        if (snapshot_size < @sizeOf(abi.PlayerSnapshot)) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const pointer = self.handles.get(.player, handle) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_handle;
        };
        const player: *Player = @ptrFromInt(pointer);
        self.fillPlayerSnapshot(player, handle, output);
        return abi.result_ok;
    }

    fn playersGetByIndex(context: ?*anyopaque, index: usize, snapshot: ?*abi.PlayerSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = snapshot orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        if (snapshot_size < @sizeOf(abi.PlayerSnapshot)) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const tecton = self.tecton orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const players = tecton.getPlayerSnapshots();
        if (index >= players.len) {
            @branchHint(.unlikely);
            return abi.result_not_found;
        }
        const player = players[index];
        self.fillPlayerSnapshot(player, self.handles.handleFor(.player, @intFromPtr(player)) orelse 0, output);
        return abi.result_ok;
    }

    fn playersGetByRuntime(context: ?*anyopaque, runtime_id: i64, snapshot: ?*abi.PlayerSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.PlayerSnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const player = tecton.findPlayerByRuntimeId(runtime_id) orelse return abi.result_not_found;
        self.fillPlayerSnapshot(player, self.handles.handleFor(.player, @intFromPtr(player)) orelse 0, output);
        return abi.result_ok;
    }

    fn playersForEach(context: ?*anyopaque, callback: ?abi.PlayerCallbackFn, callback_userdata: ?*anyopaque) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const cb = callback orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const tecton = self.tecton orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        for (tecton.getPlayerSnapshots()) |player| {
            var snapshot: abi.PlayerSnapshot = undefined;
            self.fillPlayerSnapshot(player, self.handles.handleFor(.player, @intFromPtr(player)) orelse 0, &snapshot);
            cb(callback_userdata, &snapshot);
        }
        return abi.result_ok;
    }

    fn entitiesCount(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, count_output: *usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        count_output.* = dimension.entities.count();
        return abi.result_ok;
    }

    fn fillEntitySnapshot(self: *PluginRuntime, entity: *Entity, handle: u64, output: *abi.EntitySnapshot) void {
        const dimension = entity.dimension;
        output.* = .{
            .header = .{ .struct_size = @sizeOf(abi.EntitySnapshot), .version = 1, .reserved = 0 },
            .handle = handle,
            .runtime_id = entity.runtime_id,
            .type = stringView(entity.entity_type.identifier),
            .world = if (dimension) |value| self.handles.handleFor(.world, @intFromPtr(value.world)) orelse 0 else 0,
            .dimension = if (dimension) |value| stringView(value.identifier) else .{},
            .x = entity.position.x,
            .y = entity.position.y,
            .z = entity.position.z,
        };
    }

    fn entitiesGetSnapshot(context: ?*anyopaque, handle: u64, snapshot: ?*abi.EntitySnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.EntitySnapshot)) return abi.result_invalid_argument;
        const pointer = self.handles.get(.entity, handle) orelse return abi.result_invalid_handle;
        const entity: *Entity = @ptrFromInt(pointer);
        self.fillEntitySnapshot(entity, handle, output);
        return abi.result_ok;
    }

    fn entityAt(self: *PluginRuntime, dimension: *Dimension, index: usize) ?*Entity {
        if (self.entity_cache_dimension != dimension or self.entity_cache_serial != dimension.entity_serial) {
            self.entity_cache.clearRetainingCapacity();
            var iterator = dimension.entities.valueIterator();
            while (iterator.next()) |entity| self.entity_cache.append(self.allocator, entity.*) catch return null;
            self.entity_cache_dimension = dimension;
            self.entity_cache_serial = dimension.entity_serial;
        }
        if (index >= self.entity_cache.items.len) return null;
        return self.entity_cache.items[index];
    }

    fn entitiesGetByIndex(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, index: usize, snapshot: ?*abi.EntitySnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = snapshot orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        if (snapshot_size < @sizeOf(abi.EntitySnapshot)) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const world = self.worldFromHandle(world_handle) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_handle;
        };
        const dimension = world.getDimension(dimension_name.slice()) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const entity = self.entityAt(dimension, index) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        self.fillEntitySnapshot(entity, self.handles.handleFor(.entity, @intFromPtr(entity)) orelse 0, output);
        return abi.result_ok;
    }

    fn entitiesGetByRuntime(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, runtime_id: i64, snapshot: ?*abi.EntitySnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.EntitySnapshot)) return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        const entity = dimension.getEntity(runtime_id) orelse return abi.result_not_found;
        self.fillEntitySnapshot(entity, self.handles.handleFor(.entity, @intFromPtr(entity)) orelse 0, output);
        return abi.result_ok;
    }

    fn entitiesForEach(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, callback: ?abi.EntityCallbackFn, callback_userdata: ?*anyopaque) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const cb = callback orelse return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        var iterator = dimension.entities.valueIterator();
        while (iterator.next()) |entity| {
            var snapshot: abi.EntitySnapshot = undefined;
            self.fillEntitySnapshot(entity.*, self.handles.handleFor(.entity, @intFromPtr(entity.*)) orelse 0, &snapshot);
            cb(callback_userdata, &snapshot);
        }
        return abi.result_ok;
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
        const permutation = resolveBlockPermutation(self.allocator, block.slice()) orelse return abi.result_not_found;
        const state: u32 = @bitCast(permutation.network_id);
        return self.setBlockState(world, dimension, x, y, z, state, abi.block_flag_apply_traits | abi.block_flag_update_clients);
    }

    fn worldGetBlockState(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, x: i32, y: i32, z: i32, state: ?*u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const output = state orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const world = self.worldFromHandle(world_handle) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_handle;
        };
        const dimension_value = world.getDimension(dimension.slice()) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const permutation = readBlockPermutation(dimension_value, x, y, z) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        output.* = @bitCast(permutation.network_id);
        return abi.result_ok;
    }

    fn setBlockState(self: *PluginRuntime, world: *World, dimension: abi.StringView, x: i32, y: i32, z: i32, state: u32, flags: u32) i32 {
        const known = abi.block_flag_apply_traits | abi.block_flag_update_clients | abi.block_flag_silent;
        if (flags & ~known != 0) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const dimension_value = world.getDimension(dimension.slice()) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const network_id: i32 = @bitCast(state);
        const permutation = BlockPermutation.getByNetworkId(network_id) orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        const position = Protocol.BlockPosition{ .x = x, .y = y, .z = z };
        // Write path: unlike the read lookups, set_block_state is allowed to
        // materialize the target chunk before storing the new permutation on
        // the first write.
        dimension_value.setPermutation(position, permutation, 0) catch {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        if (flags & abi.block_flag_apply_traits != 0) {
            applyTraitsForBlock(self.allocator, dimension_value, position) catch {
                @branchHint(.unlikely);
                return abi.result_not_found;
            };
        }
        if (flags & abi.block_flag_update_clients != 0 and flags & abi.block_flag_silent == 0) {
            var buffer: [64]u8 = undefined;
            var stream = BinaryStream{
                .payload = &buffer,
                .written = 0,
                .offset = 0,
                .allocator = self.allocator,
                .owns_buffer = false,
            };
            defer stream.deinit();
            const serialized = serializeBlockUpdate(position, state, &stream) catch {
                @branchHint(.unlikely);
                return abi.result_out_of_memory;
            };
            // Tests run without a network; production always has a Tecton here.
            if (self.tecton != null) block_broadcast.broadcastBlockUpdateToViewers(dimension_value, position, serialized);
        }
        return abi.result_ok;
    }

    fn worldSetBlockState(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, x: i32, y: i32, z: i32, state: u32, flags: u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const world = self.worldFromHandle(world_handle) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_handle;
        };
        return self.setBlockState(world, dimension, x, y, z, state, flags);
    }

    fn worldForEachInBox(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, box: abi.BlockBox, callback: ?abi.BlockCallbackFn, callback_userdata: ?*anyopaque) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const cb = callback orelse return abi.result_invalid_argument;
        const world = self.worldFromHandle(world_handle) orelse return abi.result_invalid_handle;
        const dimension_value = world.getDimension(dimension.slice()) orelse return abi.result_not_found;
        const min_x = @min(box.min_x, box.max_x);
        const max_x = @max(box.min_x, box.max_x);
        const min_y = @min(box.min_y, box.max_y);
        const max_y = @max(box.min_y, box.max_y);
        const min_z = @min(box.min_z, box.max_z);
        const max_z = @max(box.min_z, box.max_z);
        var y: i64 = min_y;
        while (y <= max_y) : (y += 1) {
            var z: i64 = min_z;
            while (z <= max_z) : (z += 1) {
                var x: i64 = min_x;
                while (x <= max_x) : (x += 1) {
                    const permutation = readBlockPermutation(dimension_value, @intCast(x), @intCast(y), @intCast(z)) orelse continue;
                    cb(callback_userdata, @intCast(x), @intCast(y), @intCast(z), @bitCast(permutation.network_id));
                }
            }
        }
        return abi.result_ok;
    }

    fn blocksResolveName(context: ?*anyopaque, name: abi.StringView, state: ?*u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse return abi.result_invalid_argument;
        const output = state orelse return abi.result_invalid_argument;
        const identifier = name.slice();
        // BlockPermutation.resolve intentionally falls back to air for unknown
        // names. This lookup reports the miss instead of returning a state the
        // caller did not ask for.
        const permutation = resolveBlockPermutation(self.allocator, identifier) orelse return abi.result_not_found;
        output.* = @bitCast(permutation.network_id);
        return abi.result_ok;
    }

    fn networkSend(context: ?*anyopaque, player_handle: u64, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const send_priority = sendPriority(priority) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const payload = bytes.slice();
        if (payload.len == 0 or payload.len > MAX_PLUGIN_PACKET_BYTES) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const tecton = self.tecton orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        if (!isTickThread(tecton)) {
            @branchHint(.unlikely);
            return abi.result_wrong_thread;
        }
        const player = self.playerFromHandle(player_handle) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_handle;
        };
        tecton.network.sendPacketWith(player.connection, payload, send_priority) catch {
            @branchHint(.unlikely);
            return abi.result_out_of_memory;
        };
        return abi.result_ok;
    }

    fn networkBroadcast(context: ?*anyopaque, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self = runtimeFrom(context) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const send_priority = sendPriority(priority) orelse {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        };
        const payload = bytes.slice();
        if (payload.len == 0 or payload.len > MAX_PLUGIN_PACKET_BYTES) {
            @branchHint(.unlikely);
            return abi.result_invalid_argument;
        }
        const tecton = self.tecton orelse {
            @branchHint(.unlikely);
            return abi.result_not_found;
        };
        if (!isTickThread(tecton)) {
            @branchHint(.unlikely);
            return abi.result_wrong_thread;
        }
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

fn readBlockPermutation(dimension: *Dimension, x: i32, y: i32, z: i32) ?*BlockPermutation {
    const chunk = dimension.getChunk(x >> 4, z >> 4) orelse return null;
    return chunk.getPermutationReadOnly(x, y, z, 0) catch null;
}

fn resolveBlockPermutation(allocator: std.mem.Allocator, identifier: []const u8) ?*BlockPermutation {
    if (BlockType.get(identifier) == null) return null;
    return BlockPermutation.resolve(allocator, identifier, null) catch null;
}

fn serializeBlockUpdate(position: Protocol.BlockPosition, state: u32, stream: *BinaryStream) ![]const u8 {
    const update = Protocol.UpdateBlockPacket{ .position = position, .network_block_id = state };
    return update.serialize(stream);
}

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
    pub const private_pluginruntime_dispatch = test_owner.PluginRuntime.dispatch;
    pub const private_pluginruntime_itemHandle = test_owner.PluginRuntime.itemHandle;
    pub const private_pluginruntime_serializeBlockUpdate = test_owner.serializeBlockUpdate;
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

test "all 25 event schemas flags and payload sizes are stable" {
    try @import("runtime_test.zig").Suite(test_scope).case_016();
}

test "all 25 event payloads expose the expected fields" {
    try @import("runtime_test.zig").Suite(test_scope).case_017();
}

test "custom deferred payloads cap at 56 bytes while immediate payloads stay borrowed" {
    try @import("runtime_test.zig").Suite(test_scope).case_018();
}

test "custom schema identity includes the version" {
    try @import("runtime_test.zig").Suite(test_scope).case_019();
}

test "player move does not materialize handles" {
    try @import("runtime_test.zig").Suite(test_scope).case_020();
}

test "hot event payloads do not allocate" {
    try @import("runtime_test.zig").Suite(test_scope).case_021();
}

test "a mutated chat message is copied back to the core" {
    try @import("runtime_test.zig").Suite(test_scope).case_022();
}

test "a mutated move target reaches the core only from pre" {
    try @import("runtime_test.zig").Suite(test_scope).case_023();
}

test "a mutated damage amount reaches the core" {
    try @import("runtime_test.zig").Suite(test_scope).case_024();
}

test "a mutated combust duration reaches the core" {
    try @import("runtime_test.zig").Suite(test_scope).case_025();
}

test "a mutated enchantment level reaches the core" {
    try @import("runtime_test.zig").Suite(test_scope).case_026();
}

test "a mutated entity damage amount reaches the core" {
    try @import("runtime_test.zig").Suite(test_scope).case_027();
}

test "a canceled chat is not forwarded by the text handler" {
    try @import("runtime_test.zig").Suite(test_scope).case_028();
}

test "schema versions reject bits above the low byte" {
    try @import("runtime_test.zig").Suite(test_scope).case_029();
}

test "a shared custom schema survives the unload of its first owner" {
    try @import("runtime_test.zig").Suite(test_scope).case_030();
}

test "item handles stay address-keyed for the runtime lifetime" {
    try @import("runtime_test.zig").Suite(test_scope).case_031();
}

test "deferred custom payloads are eight byte aligned" {
    try @import("runtime_test.zig").Suite(test_scope).case_032();
}

test "unloading the last owner drops deferred emits and subscriptions for its schema" {
    try @import("runtime_test.zig").Suite(test_scope).case_033();
}

test "a freed custom schema stays tombstoned after the name is registered again" {
    try @import("runtime_test.zig").Suite(test_scope).case_034();
}

test "a ninth owner is rejected at the fixed owner capacity" {
    try @import("runtime_test.zig").Suite(test_scope).case_035();
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
    try std.testing.expectEqual(@as(u32, 0), runtime.active[@backingInt(abi.EventId.server_tick)][abi.event_phase_pre]);
    try std.testing.expectEqual(@as(u32, 0), runtime.bridge_total);
}

test "thirty two subscribers on one event never enter dispatch for another" {
    var events = Events.Events.init(std.testing.allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1, .state = .running };
    const Probe = struct {
        calls: u32 = 0,

        fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.calls += 1;
        }
    };
    var probe = Probe{};
    var subscriptions: [32]u64 = undefined;
    for (&subscriptions) |*subscription| {
        try std.testing.expectEqual(
            abi.result_ok,
            PluginRuntime.eventSubscribe(@ptrCast(&slot), @backingInt(abi.EventId.server_start), abi.event_phase_pre, 0, Probe.callback, &probe, subscription),
        );
    }

    var tick = Events.types.ServerTickEvent{ .tick = 1 };
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
    try std.testing.expectEqual(@as(u64, 0), slot.events_dispatched);
    try std.testing.expect(!events.hasListeners(.ServerTick));
    try std.testing.expectEqual(@as(u32, 1), runtime.bridge_total);

    var start = Events.types.ServerStartEvent{};
    _ = events.emit(.ServerStart, &start);
    try std.testing.expectEqual(@as(u32, 32), probe.calls);
    try std.testing.expectEqual(@as(u64, 32), slot.events_dispatched);

    const dispatched = slot.events_dispatched;
    _ = events.emit(.ServerTick, &tick);
    try std.testing.expectEqual(@as(u32, 32), probe.calls);
    try std.testing.expectEqual(dispatched, slot.events_dispatched);
}

test "unsubscribe is owner scoped and compacts the bucket" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    const event_index = @backingInt(abi.EventId.server_tick);
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

    const event_index = @backingInt(abi.EventId.server_tick);
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
        PluginRuntime.eventSubscribe(@ptrCast(&slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );
    probe.sub = sub;
    try std.testing.expect(events.hasListeners(.ServerTick));

    const event_index = @backingInt(abi.EventId.server_tick);
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
        PluginRuntime.eventSubscribe(@ptrCast(slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );

    const event_index = @backingInt(abi.EventId.server_tick);
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
                _ = PluginRuntime.eventSubscribe(@ptrCast(probe.slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 100, second, probe, &probe.sub);
            }
        }

        fn second(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
            const probe: *@This() = @ptrCast(@alignCast(userdata.?));
            probe.push(2);
        }
    };
    var probe = Probe{ .runtime = &runtime, .slot = &slot };

    const event_index = @backingInt(abi.EventId.server_tick);
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
                _ = PluginRuntime.eventSubscribe(@ptrCast(probe.slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 100, second, probe, &second_sub);
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
        PluginRuntime.eventSubscribe(@ptrCast(&slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.first, &probe, &sub),
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
        PluginRuntime.eventSubscribe(@ptrCast(slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.callback, &probe, &sub),
    );

    const event_index = @backingInt(abi.EventId.server_tick);
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
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventSubscribe(@ptrCast(&slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 100, Trace.pluginHigh, &trace, &high));
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.eventSubscribe(@ptrCast(&slot), @backingInt(abi.EventId.server_tick), abi.event_phase_pre, 0, Trace.pluginLow, &trace, &low));

    const event_index = @backingInt(abi.EventId.server_tick);
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

    const first = try allocator.create(Entity);
    first.* = Entity.init(allocator, &entity_type, &dimension);
    try dimension.entities.put(first.runtime_id, first);
    var first_removed = false;
    defer if (!first_removed) {
        _ = dimension.entities.remove(first.runtime_id);
        first.deinit();
        allocator.destroy(first);
    };

    const first_handle = try runtime.handles.put(.entity, @intFromPtr(first), slot.plugin_id, &slot.owns_handles);
    var first_snapshot: abi.EntitySnapshot = undefined;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.entitiesGetSnapshot(@ptrCast(&slot), first_handle, &first_snapshot, @sizeOf(abi.EntitySnapshot)));
    try std.testing.expectEqual(@as(?usize, @intFromPtr(first)), runtime.handles.get(.entity, first_snapshot.handle));

    try entities_mod.removeEntity(&dimension, first);
    first_removed = true;
    try std.testing.expect(runtime.handles.get(.entity, first_snapshot.handle) == null);

    const second = try allocator.create(Entity);
    second.* = Entity.init(allocator, &entity_type, &dimension);
    try dimension.entities.put(second.runtime_id, second);
    const second_handle = try runtime.handles.put(.entity, @intFromPtr(second), slot.plugin_id, &slot.owns_handles);
    var second_snapshot: abi.EntitySnapshot = undefined;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.entitiesGetSnapshot(@ptrCast(&slot), second_handle, &second_snapshot, @sizeOf(abi.EntitySnapshot)));

    dimension.deinit();
    dimension_deinited = true;
    try std.testing.expect(runtime.handles.get(.entity, second_snapshot.handle) == null);
}

test "every served interface advertises exactly its feature bit" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1 };

    var served: u64 = 0;
    var output: ?abi.InterfacePtr = null;
    for (PluginRuntime.interface_specs) |spec| {
        try std.testing.expectEqual(abi.result_ok, PluginRuntime.getInterface(@ptrCast(&slot), spec.id, 1, 0, &output));
        const header = output orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u16, 1), header.major);
        try std.testing.expectEqual(abi.interfaceFeature(spec.id), header.features);
        served |= header.features;

        try std.testing.expectEqual(abi.result_version, PluginRuntime.getInterface(@ptrCast(&slot), spec.id, header.major + 1, 0, &output));
        try std.testing.expectEqual(abi.result_version, PluginRuntime.getInterface(@ptrCast(&slot), spec.id, header.major, header.minor + 1, &output));
    }
    try std.testing.expectEqual(abi.result_unsupported, PluginRuntime.getInterface(@ptrCast(&slot), 0, 1, 0, &output));
    const behaviors = abi.feature_allocator | abi.feature_custom_events | abi.feature_traits | abi.feature_hot_unload;
    try std.testing.expectEqual(abi.host_features, served | behaviors);
}

fn testCommandHandler(_: *const abi.CommandCall) callconv(.c) i32 {
    return abi.result_ok;
}

fn registerTestCommand(runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, name: []const u8, aliases: []const abi.StringView) !u64 {
    const description = abi.StringView{};
    const permission = abi.StringView{};
    var desc = abi.CommandDesc{
        .struct_size = @sizeOf(abi.CommandDesc),
        .flags = 0,
        .name = .{ .data = name.ptr, .length = name.len },
        .description = description,
        .permission = permission,
        .aliases = if (aliases.len == 0) null else aliases.ptr,
        .alias_count = @intCast(aliases.len),
        .reserved = 0,
        .handler = testCommandHandler,
        .userdata = null,
    };
    var handle: u64 = 0;
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.commandRegister(@ptrCast(slot), &desc, &handle));
    _ = runtime;
    return handle;
}

test "fifty command registrations coalesce into one broadcast" {
    const allocator = std.testing.allocator;
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.command_registry = &registry;
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 7, .state = .running };

    for (0..50) |index| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "phase5-{d}", .{index});
        const handle = try registerTestCommand(&runtime, &slot, name, &.{});
        try std.testing.expect(handle != 0);
    }
    try std.testing.expectEqual(@as(usize, 50), registry.commands.count());
    try std.testing.expect(runtime.command_dirty);

    runtime.flushCommands();
    try std.testing.expectEqual(@as(u32, 1), runtime.command_broadcasts);
    try std.testing.expect(!runtime.command_dirty);
    runtime.flushCommands();
    try std.testing.expectEqual(@as(u32, 1), runtime.command_broadcasts);
}

test "command collisions and aliases are owner scoped" {
    const allocator = std.testing.allocator;
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.command_registry = &registry;
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 3, .state = .running };
    var foreign = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 4, .state = .running };

    const handle = try registerTestCommand(&runtime, &slot, "phase5-owner", &.{});
    const alias_view = abi.StringView{ .data = "phase5-alias", .length = 12 };
    _ = try registerTestCommand(&runtime, &slot, "phase5-alias-target", &.{alias_view});
    var conflict_handle: u64 = 0;

    try std.testing.expectEqual(abi.result_conflict, PluginRuntime.commandRegister(@ptrCast(&slot), &abi.CommandDesc{
        .struct_size = @sizeOf(abi.CommandDesc),
        .flags = 0,
        .name = .{ .data = "phase5-owner", .length = 12 },
        .handler = testCommandHandler,
        .description = .{},
        .permission = .{},
        .aliases = null,
        .alias_count = 0,
        .reserved = 0,
        .userdata = null,
    }, &conflict_handle));

    try std.testing.expectEqual(abi.result_invalid_handle, PluginRuntime.commandUnregister(@ptrCast(&foreign), handle));
    try std.testing.expectEqual(abi.result_ok, PluginRuntime.commandUnregister(@ptrCast(&slot), handle));
    try std.testing.expect(registry.findCommand("phase5-owner") == null);
    try std.testing.expect(registry.findCommand("phase5-alias") != null);

    runtime.unregisterCommandsFor(3);
    try std.testing.expect(registry.findCommand("phase5-alias") == null);
    try std.testing.expect(registry.findCommand("phase5-alias-target") == null);
    try std.testing.expect(runtime.command_dirty);
}

test "player entity and item snapshots expose live data" {
    try @import("runtime_test.zig").Suite(test_scope).case_036();
}

test "set block applies traits only when requested" {
    try @import("runtime_test.zig").Suite(test_scope).case_037();
}

test "plugin commands execute with borrowed argv and disappear on owner unload" {
    try @import("runtime_test.zig").Suite(test_scope).case_038();
}

test "host allocator tracks live blocks and survives a mismatched free" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1 };

    const memory = PluginRuntime.allocate(@ptrCast(&slot), 96, 16) orelse return error.OutOfMemory;
    if (comptime allocation_checks) try std.testing.expectEqual(@as(usize, 1), runtime.live_blocks.count());
    PluginRuntime.free(@ptrCast(&slot), memory, 96, 16);
    if (comptime allocation_checks) try std.testing.expectEqual(@as(usize, 0), runtime.live_blocks.count());

    const zeroed = PluginRuntime.allocateZeroed(@ptrCast(&slot), 32, 8) orelse return error.OutOfMemory;
    const grown = PluginRuntime.reallocate(@ptrCast(&slot), zeroed, 32, 64, 8) orelse return error.OutOfMemory;
    PluginRuntime.free(@ptrCast(&slot), grown, 64, 8);
    if (comptime allocation_checks) try std.testing.expectEqual(@as(usize, 0), runtime.live_blocks.count());

    if (comptime allocation_checks) {
        const mismatch = PluginRuntime.allocate(@ptrCast(&slot), 24, 8) orelse return error.OutOfMemory;
        PluginRuntime.free(@ptrCast(&slot), mismatch, 64, 8);
        try std.testing.expectEqual(@as(usize, 0), runtime.live_blocks.count());

        _ = PluginRuntime.allocate(@ptrCast(&slot), 48, 8) orelse return error.OutOfMemory;
        runtime.reclaimBlocks(&slot);
        try std.testing.expectEqual(@as(usize, 0), runtime.live_blocks.count());
    }
}

test "reallocate keeps the original block when tracking fails" {
    if (comptime allocation_checks) {
        var runtime = PluginRuntime.init(std.testing.allocator);
        defer runtime.deinit();
        var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1 };
        const memory = PluginRuntime.allocate(@ptrCast(&slot), 32, 8) orelse return error.OutOfMemory;
        const bytes = @as([*]u8, @ptrCast(memory))[0..32];
        @memset(bytes, 0x5a);

        var filler: usize = 1;
        while (runtime.live_blocks.available > 0) : (filler += 1) {
            try runtime.live_blocks.put(std.testing.allocator, filler, .{ .size = 0, .alignment = 1, .plugin_id = 2 });
        }

        var buffer: [128]u8 align(16) = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
        const probe = fixed.allocator().rawAlloc(96, .fromByteUnits(8), @returnAddress()) orelse return error.OutOfMemory;
        fixed.allocator().rawFree(probe[0..96], .fromByteUnits(8), @returnAddress());
        runtime.allocator = fixed.allocator();
        try std.testing.expect(PluginRuntime.reallocate(@ptrCast(&slot), memory, 32, 96, 8) == null);
        try std.testing.expect(runtime.live_blocks.contains(@intFromPtr(memory)));
        try std.testing.expectEqual(@as(u8, 0x5a), bytes[0]);

        runtime.allocator = std.testing.allocator;
        PluginRuntime.free(@ptrCast(&slot), memory, 32, 8);
        try std.testing.expect(!runtime.live_blocks.contains(@intFromPtr(memory)));
    }
}

test "unknown interface id returns unsupported" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1 };
    var output: ?abi.InterfacePtr = undefined;
    try std.testing.expectEqual(abi.result_unsupported, PluginRuntime.getInterface(@ptrCast(&slot), 0xffff, 1, 0, &output));
    try std.testing.expect(output == null);
}

test "interface version mismatch returns version" {
    var runtime = PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 1 };
    var output: ?abi.InterfacePtr = undefined;
    try std.testing.expectEqual(abi.result_version, PluginRuntime.getInterface(@ptrCast(&slot), abi.interface_core, 2, 0, &output));
    try std.testing.expect(output == null);
    try std.testing.expectEqual(abi.result_version, PluginRuntime.getInterface(@ptrCast(&slot), abi.interface_core, 1, 1, &output));
    try std.testing.expect(output == null);
}
