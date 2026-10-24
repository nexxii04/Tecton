const std = @import("std");
const builtin = @import("builtin");

const Tecton = @import("../tecton.zig").Tecton;
const Raknet = @import("Raknet");
const Events = @import("../events/root.zig");
const World = @import("../world/world.zig").World;
const abi = @import("abi.zig");
const NativePlugin = @import("dynamic_loader.zig").NativePlugin;
const Handles = @import("handles.zig");
const SendPriority = @import("../network/root.zig").SendPriority;
const Player = @import("../player/player.zig").Player;

const MAX_PLUGIN_PACKET_BYTES: usize = 1 << 20;
const event_count = std.meta.fields(Events.Event).len;

pub const PluginRuntime = struct {
    allocator: std.mem.Allocator,
    tecton: ?*Tecton = null,
    events: ?*Events.Events = null,
    host: abi.HostApi,
    handles: Handles.Table,
    plugins: std.ArrayList(NativePlugin),
    plugin_labels: std.ArrayList(PluginLabel),
    subscriptions: std.ArrayList(Subscription),
    bridges: [event_count][3]bool,
    next_id: u32 = 1,
    next_subscription: u64 = 1,
    discovery_error_count: usize = 0,
    dispatching: bool = false,
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

    const PluginLabel = struct {
        id: u32,
        name: []u8,
    };

    const ScheduledTask = struct {
        runtime: *PluginRuntime,
        owner_id: u32,
        handle: u64,
        callback: abi.SchedulerCallbackFn,
        userdata: ?*anyopaque,
        cancelled: bool = false,
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
            .handles = Handles.Table.init(allocator),
            .plugins = .empty,
            .plugin_labels = .empty,
            .subscriptions = .empty,
            .bridges = std.mem.zeroes([event_count][3]bool),
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
        runtime.core_api = .{
            .header = .{ .struct_size = @sizeOf(abi.CoreApi), .major = 1, .minor = 0, .interface_id = abi.interface_core, .features = 0 },
            .get_tick = coreGetTick,
            .get_state = coreGetState,
        };
        runtime.world_api = .{
            .header = .{ .struct_size = @sizeOf(abi.WorldApi), .major = 1, .minor = 0, .interface_id = abi.interface_world, .features = 0 },
            .find = worldFindInterface,
            .get_snapshot = worldGetSnapshot,
        };
        runtime.players_api = .{
            .header = .{ .struct_size = @sizeOf(abi.PlayersApi), .major = 1, .minor = 0, .interface_id = abi.interface_players, .features = 0 },
            .count = playersCount,
            .get_snapshot = playersGetSnapshot,
        };
        runtime.entities_api = .{
            .header = .{ .struct_size = @sizeOf(abi.EntitiesApi), .major = 1, .minor = 0, .interface_id = abi.interface_entities, .features = 0 },
            .count = entitiesCount,
            .get_snapshot = entitiesGetSnapshot,
        };
        runtime.items_api = .{
            .header = .{ .struct_size = @sizeOf(abi.ItemsApi), .major = 1, .minor = 0, .interface_id = abi.interface_items, .features = 0 },
            .count = itemsCount,
            .get_snapshot = itemsGetSnapshot,
        };
        runtime.blocks_api = .{
            .header = .{ .struct_size = @sizeOf(abi.BlocksApi), .major = 1, .minor = 0, .interface_id = abi.interface_blocks, .features = 0 },
            .get_snapshot = blocksGetSnapshot,
        };
        runtime.inventories_api = .{
            .header = .{ .struct_size = @sizeOf(abi.InventoriesApi), .major = 1, .minor = 0, .interface_id = abi.interface_inventories, .features = 0 },
            .get_size = inventoryGetSize,
            .get_item = inventoryGetItem,
        };
        runtime.scheduler_api = .{
            .header = .{ .struct_size = @sizeOf(abi.SchedulerApi), .major = 1, .minor = 0, .interface_id = abi.interface_scheduler, .features = 0 },
            .schedule = schedulerSchedule,
            .cancel = schedulerCancel,
            .cancel_owner = schedulerCancelOwner,
        };
        runtime.network_api = .{
            .header = .{ .struct_size = @sizeOf(abi.NetworkApi), .major = 1, .minor = 0, .interface_id = abi.interface_network, .features = 0 },
            .send = networkSend,
            .broadcast = networkBroadcast,
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
            .features = abi.feature_events | abi.feature_world | abi.feature_logging | abi.feature_allocator | abi.feature_interfaces | abi.feature_core | abi.feature_scheduler | abi.feature_players | abi.feature_entities | abi.feature_items | abi.feature_blocks | abi.feature_inventories | abi.feature_network,
            .log_debug = logDebug,
            .log_info = logInfo,
            .log_warn = logWarn,
            .log_error = logError,
            .get_interface = getInterface,
        };
        return runtime;
    }

    pub fn attach(self: *PluginRuntime, tecton: *Tecton, events: *Events.Events, protocol: u32) void {
        self.tecton = tecton;
        self.events = events;
        self.host.userdata = @ptrCast(self);
        self.host.allocator.userdata = @ptrCast(self);
        self.host.api.protocol = protocol;
        self.host.api.minor = abi.abi_minor;
        self.server_state = 0;
    }

    pub fn discover(self: *PluginRuntime, io: std.Io, protocol: u32, directory_path: []const u8) void {
        const directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
            std.Io.Dir.cwd().createDir(io, directory_path, .default_dir) catch {};
            if (err != error.FileNotFound) Raknet.Logger.WARN("Unable to open plugins directory: {s}", .{@errorName(err)});
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
                Raknet.Logger.ERROR("Unable to allocate plugin name for {s}", .{entry.name});
                continue;
            };
            names.append(self.allocator, name) catch {
                self.allocator.free(name);
                Raknet.Logger.ERROR("Unable to register plugin name for {s}", .{entry.name});
            };
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);

        for (names.items) |name| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory_path, name }) catch {
                Raknet.Logger.ERROR("Unable to allocate plugin path for {s}", .{name});
                continue;
            };
            defer self.allocator.free(path);
            self.load(path, protocol);
        }
    }

    pub fn deinit(self: *PluginRuntime) void {
        self.cancelAllScheduled();
        if (self.events) |events| events.removeOwner(NATIVE_BRIDGE_OWNER_ID);
        var index = self.plugins.items.len;
        while (index > 0) {
            index -= 1;
            self.plugins.items[index].deinit();
        }
        if (self.tecton) |tecton| {
            for (self.plugin_labels.items) |label| {
                tecton.tasks.cancelByOwner("plugin", @intCast(label.id), null);
            }
        }
        self.plugins.deinit(self.allocator);
        self.handles.deinit();
        for (self.plugin_labels.items) |label| self.allocator.free(label.name);
        self.plugin_labels.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
        self.scheduled_tasks.deinit(self.allocator);
        self.events = null;
        self.tecton = null;
    }

    pub fn count(self: *const PluginRuntime) usize {
        return self.plugins.items.len;
    }

    pub fn setServerState(self: *PluginRuntime, state: u32) void {
        self.server_state = state;
    }

    fn load(self: *PluginRuntime, path: []const u8, protocol: u32) void {
        const plugin_id = self.next_id;
        var plugin = NativePlugin.open(self.allocator, path, &self.host, plugin_id, protocol) catch |err| {
            self.discovery_error_count += 1;
            Raknet.Logger.ERROR("Unable to load plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };

        self.next_id += 1;
        const label = self.allocator.dupe(u8, abi.metadataName(plugin.descriptor)) catch {
            self.discovery_error_count += 1;
            plugin.deinit();
            Raknet.Logger.ERROR("Unable to allocate plugin label for {s}", .{path});
            return;
        };

        self.plugin_labels.append(self.allocator, .{ .id = plugin_id, .name = label }) catch {
            self.allocator.free(label);
            self.discovery_error_count += 1;
            plugin.deinit();
            Raknet.Logger.ERROR("Unable to register plugin label for {s}", .{path});
            return;
        };

        Raknet.Logger.INFO("Loading native plugin: {s}", .{path});
        plugin.start() catch |err| {
            plugin.deinit();
            Raknet.Logger.ERROR("Unable to start plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };

        self.plugins.append(self.allocator, plugin) catch |err| {
            plugin.deinit();
            Raknet.Logger.ERROR("Unable to register plugin {s}: {s}", .{ path, @errorName(err) });
            return;
        };
    }

    fn eventSubscribe(context: ?*anyopaque, event_id: u32, phase: u32, priority: i16, callback: ?abi.EventCallbackFn, userdata: ?*anyopaque, subscription: ?*u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return -1));
        if (phase >= 3 or self.dispatching) return -1;
        if (callback == null or subscription == null) return abi.result_invalid_argument;
        const internal_event = internalEvent(event_id) orelse return abi.result_not_found;
        self.ensureBridge(@intFromEnum(internal_event), phase) catch return abi.result_unsupported;

        const id = self.next_subscription;
        self.next_subscription += 1;
        const item = Subscription{
            .id = id,
            .event_id = event_id,
            .phase = phase,
            .priority = priority,
            .callback = callback.?,
            .userdata = userdata,
        };

        var index: usize = 0;
        while (index < self.subscriptions.items.len and self.subscriptions.items[index].priority >= priority) : (index += 1) {}
        self.subscriptions.insert(self.allocator, index, item) catch return abi.result_out_of_memory;
        subscription.?.* = id;
        return 0;
    }

    fn eventUnsubscribe(context: ?*anyopaque, subscription: u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        if (subscription == 0) return abi.result_invalid_argument;
        for (self.subscriptions.items) |*item| {
            if (item.id == subscription and item.active) {
                item.active = false;
                return 0;
            }
        }
        return abi.result_not_found;
    }

    fn ensureBridge(self: *PluginRuntime, event_id: u32, phase: u32) !void {
        if (self.bridges[event_id][phase]) return;
        const events = self.events orelse return error.EventBusUnavailable;
        const event: Events.Event = @enumFromInt(event_id);
        const event_phase: Events.EventPhase = @enumFromInt(phase);
        switch (event) {
            inline else => |tag| {
                switch (event_phase) {
                    .pre => _ = try events.subscribeWithContext(tag, .pre, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag), self),
                    .commit => _ = try events.subscribeWithContext(tag, .commit, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag), self),
                    .post => _ = try events.subscribeWithContext(tag, .post, -32768, NATIVE_BRIDGE_OWNER_ID, bridgeCallback(tag), self),
                }
            },
        }
        self.bridges[event_id][phase] = true;
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
            player_payload.handle = self.handles.put(.player, @intFromPtr(data.player)) catch 0;
            if (player_payload.handle != 0) {
                payload_ptr = @ptrCast(&player_payload);
                payload_size = @sizeOf(abi.PlayerEvent);
            }
        }

        const payload_version: u32 = if (event == .ServerTick or event == .PlayerJoin or event == .PlayerDisconnect) 1 else 0;
        const view = abi.EventView{
            .event_id = external_event_id,
            .phase = phase,
            .data = payload_ptr,
            .data_size = payload_size,
            .result = &result,
            .payload_version = payload_version,
            .struct_size = @sizeOf(abi.EventView),
            .flags = if (event == .ServerTick or event == .PlayerJoin or event == .PlayerDisconnect) abi.event_flag_cancelable | abi.event_flag_callback_only else abi.event_flag_callback_only,
            .payload_schema = if (event == .ServerTick) 0x10001 else if (event == .PlayerJoin or event == .PlayerDisconnect) 0x10002 else 0,
        };
        for (self.subscriptions.items) |subscription| {
            if (!subscription.active or subscription.event_id != external_event_id or subscription.phase != phase) continue;
            subscription.callback(subscription.userdata, &view);
            if (result != @intFromEnum(abi.EventResult.continue_)) {
                if (event == .PlayerDisconnect) _ = self.handles.removePointer(.player, @intFromPtr(data.player));
                return .cancel;
            }
        }
        if (event == .PlayerDisconnect) _ = self.handles.removePointer(.player, @intFromPtr(data.player));
        return .continue_;
    }

    fn getInterface(context: ?*anyopaque, interface_id: u32, major: u16, minor: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = interface orelse return abi.result_invalid_argument;
        output.* = null;
        if (major != 1 or minor > 0) return abi.result_unsupported;
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
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = tick orelse return abi.result_invalid_argument;
        output.* = (self.tecton orelse return abi.result_not_found).tick_count;
        return abi.result_ok;
    }

    fn coreGetState(context: ?*anyopaque, state: ?*u32) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = state orelse return abi.result_invalid_argument;
        output.* = self.server_state;
        return abi.result_ok;
    }

    fn schedulerSchedule(context: ?*anyopaque, owner_id: u32, callback: ?abi.SchedulerCallbackFn, callback_userdata: ?*anyopaque, task: ?*u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const callback_value = callback orelse return abi.result_invalid_argument;
        const output = task orelse return abi.result_invalid_argument;
        if (output.* != 0) return abi.result_invalid_argument;
        if (self.tecton == null) return abi.result_not_found;
        const scheduled = self.allocator.create(ScheduledTask) catch return abi.result_out_of_memory;
        scheduled.* = .{ .runtime = self, .owner_id = owner_id, .handle = self.next_task, .callback = callback_value, .userdata = callback_userdata };
        self.next_task += 1;
        self.scheduled_tasks.append(self.allocator, scheduled) catch {
            self.allocator.destroy(scheduled);
            return abi.result_out_of_memory;
        };
        self.tecton.?.tasks.enqueue(.{ .func = runScheduledTask, .ctx = @ptrCast(scheduled), .name = "plugin", .owner_id = @intCast(owner_id), .cleanup = cleanupScheduledTask }) catch {
            _ = self.scheduled_tasks.pop();
            self.allocator.destroy(scheduled);
            return abi.result_busy;
        };
        output.* = scheduled.handle;
        return abi.result_ok;
    }

    fn schedulerCancel(context: ?*anyopaque, handle: u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        for (self.scheduled_tasks.items) |scheduled| {
            if (scheduled.handle == handle and !scheduled.cancelled) {
                scheduled.cancelled = true;
                return abi.result_ok;
            }
        }
        return abi.result_not_found;
    }

    fn schedulerCancelOwner(context: ?*anyopaque, owner_id: u32) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        var found = false;
        for (self.scheduled_tasks.items) |scheduled| {
            if (scheduled.owner_id == owner_id and !scheduled.cancelled) {
                scheduled.cancelled = true;
                found = true;
            }
        }
        return if (found) abi.result_ok else abi.result_not_found;
    }

    fn runScheduledTask(context: *anyopaque) bool {
        const scheduled: *ScheduledTask = @ptrCast(@alignCast(context));
        if (!scheduled.cancelled) _ = scheduled.callback(scheduled.userdata);
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
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return null));
        if (size == 0) return null;
        return self.allocator.rawAlloc(size, .fromByteUnits(@max(alignment, 1)), @returnAddress());
    }

    fn free(context: ?*anyopaque, memory: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return));
        if (size == 0) return;
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
        const value = text[0..message.length];
        if (std.mem.eql(u8, level, "DEBUG")) {
            Raknet.Logger.DEBUG("[plugin:{s}] {s}", .{ name, value });
        } else if (std.mem.eql(u8, level, "INFO")) {
            Raknet.Logger.INFO("[plugin:{s}] {s}", .{ name, value });
        } else if (std.mem.eql(u8, level, "WARN")) {
            Raknet.Logger.WARN("[plugin:{s}] {s}", .{ name, value });
        } else {
            Raknet.Logger.ERROR("[plugin:{s}] {s}", .{ name, value });
        }
    }

    fn itemsCount(_: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        const ItemType = @import("../items/item_type.zig").ItemType;
        count_output.* = ItemType.getAll().count();
        return abi.result_ok;
    }

    fn itemsGetSnapshot(context: ?*anyopaque, index: usize, snapshot: ?*abi.ItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
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
            const handle = self.handles.put(.item, @intFromPtr(item)) catch return abi.result_out_of_memory;
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.ItemSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .network_id = item.network_id, .max_stack_size = item.max_stack_size, .stackable = if (item.stackable) 1 else 0, .reserved = .{0} ** 5, .identifier = .{ .data = item.identifier.ptr, .length = item.identifier.len } };
            return abi.result_ok;
        }
        return abi.result_not_found;
    }

    fn blocksGetSnapshot(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, x: i32, y: i32, z: i32, snapshot: ?*abi.BlockSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.BlockSnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const world = self.findWorldByHandle(tecton, world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        const permutation = dimension.getPermutation(.{ .x = x, .y = y, .z = z }, 0) catch return abi.result_not_found;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.BlockSnapshot), .version = 1, .reserved = 0 }, .world = world_handle, .dimension = .{ .data = dimension.identifier.ptr, .length = dimension.identifier.len }, .x = x, .y = y, .z = z, .network_id = permutation.network_id, .identifier = .{ .data = permutation.identifier.ptr, .length = permutation.identifier.len } };
        return abi.result_ok;
    }

    fn playerFromHandle(self: *PluginRuntime, handle: u64) ?*@import("../player/player.zig").Player {
        const pointer = self.handles.get(.player, handle) orelse return null;
        return @ptrFromInt(pointer);
    }

    fn inventoryState(self: *PluginRuntime, handle: u64) ?*@import("../entity/traits/inventory.zig").State {
        const player = self.playerFromHandle(handle) orelse return null;
        return player.entity.getTraitState(@import("../entity/traits/inventory.zig").InventoryTrait);
    }

    fn inventoryGetSize(context: ?*anyopaque, player_handle: u64, size_output: *u32) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const state = self.inventoryState(player_handle) orelse return abi.result_invalid_handle;
        size_output.* = state.container.base.getSize();
        return abi.result_ok;
    }

    fn inventoryGetItem(context: ?*anyopaque, player_handle: u64, slot: u32, snapshot: ?*abi.InventoryItemSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.InventoryItemSnapshot)) return abi.result_invalid_argument;
        const state = self.inventoryState(player_handle) orelse return abi.result_invalid_handle;
        if (slot >= state.container.base.getSize()) return abi.result_not_found;
        const item = state.container.base.getItem(slot);
        if (item) |value| {
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 1, .reserved = .{0} ** 3, .count = value.stack_size, .reserved_count = 0, .network_id = value.item_type.network_id, .metadata = value.metadata, .identifier = .{ .data = value.item_type.identifier.ptr, .length = value.item_type.identifier.len } };
        } else {
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.InventoryItemSnapshot), .version = 1, .reserved = 0 }, .present = 0, .reserved = .{0} ** 3, .count = 0, .reserved_count = 0, .network_id = 0, .metadata = 0, .identifier = .{} };
        }
        return abi.result_ok;
    }

    fn worldFindInterface(context: ?*anyopaque, name: abi.StringView, handle: *u64) callconv(.c) i32 {
        return worldFind(context, name, handle);
    }

    fn worldGetSnapshot(context: ?*anyopaque, handle: u64, snapshot: ?*abi.WorldSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.WorldSnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const world = self.findWorldByHandle(tecton, handle) orelse return abi.result_invalid_handle;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.WorldSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .name = .{ .data = world.identifier.ptr, .length = world.identifier.len } };
        return abi.result_ok;
    }

    fn playersCount(context: ?*anyopaque, count_output: *usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = count_output;
        const tecton = self.tecton orelse return abi.result_not_found;
        output.* = tecton.getPlayerCount();
        return abi.result_ok;
    }

    fn playersGetSnapshot(context: ?*anyopaque, index: usize, snapshot: ?*abi.PlayerSnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.PlayerSnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const players = tecton.getPlayerSnapshots();
        if (index >= players.len) return abi.result_not_found;
        const player = players[index];
        const world_handle = if (player.entity.dimension) |dimension| self.handles.put(.world, @intFromPtr(dimension.world)) catch return abi.result_out_of_memory else 0;
        const dimension_name = if (player.entity.dimension) |dimension| dimension.identifier else "";
        const handle = self.handles.put(.player, @intFromPtr(player)) catch return abi.result_out_of_memory;
        output.* = .{ .header = .{ .struct_size = @sizeOf(abi.PlayerSnapshot), .version = 1, .reserved = 0 }, .handle = handle, .runtime_id = player.entity.runtime_id, .name = .{ .data = player.username.ptr, .length = player.username.len }, .uuid = .{ .data = player.uuid.ptr, .length = player.uuid.len }, .world = world_handle, .dimension = .{ .data = dimension_name.ptr, .length = dimension_name.len }, .x = player.entity.position.x, .y = player.entity.position.y, .z = player.entity.position.z };
        return abi.result_ok;
    }

    fn entitiesCount(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, count_output: *usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = count_output;
        const tecton = self.tecton orelse return abi.result_not_found;
        const world = self.findWorldByHandle(tecton, world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        output.* = dimension.entities.count();
        return abi.result_ok;
    }

    fn entitiesGetSnapshot(context: ?*anyopaque, world_handle: u64, dimension_name: abi.StringView, index: usize, snapshot: ?*abi.EntitySnapshot, snapshot_size: usize) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const output = snapshot orelse return abi.result_invalid_argument;
        if (snapshot_size < @sizeOf(abi.EntitySnapshot)) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        const world = self.findWorldByHandle(tecton, world_handle) orelse return abi.result_invalid_handle;
        const dimension = world.getDimension(dimension_name.slice()) orelse return abi.result_not_found;
        var iterator = dimension.entities.valueIterator();
        var current: usize = 0;
        while (iterator.next()) |entity_ptr| {
            if (current != index) {
                current += 1;
                continue;
            }
            const entity = entity_ptr.*;
            const handle = self.handles.put(.entity, @intFromPtr(entity)) catch return abi.result_out_of_memory;
            output.* = .{ .header = .{ .struct_size = @sizeOf(abi.EntitySnapshot), .version = 1, .reserved = 0 }, .handle = handle, .runtime_id = entity.runtime_id, .type = .{ .data = entity.entity_type.identifier.ptr, .length = entity.entity_type.identifier.len }, .world = world_handle, .dimension = .{ .data = dimension.identifier.ptr, .length = dimension.identifier.len }, .x = entity.position.x, .y = entity.position.y, .z = entity.position.z };
            return abi.result_ok;
        }
        return abi.result_not_found;
    }

    fn worldFind(context: ?*anyopaque, name: abi.StringView, handle: *u64) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        const tecton = self.tecton orelse return -1;
        const world = tecton.worlds.get(name.slice()) orelse return -1;
        handle.* = self.handles.put(.world, @intFromPtr(world)) catch return -8;
        return 0;
    }

    fn playerSnapshot(_: ?*anyopaque, _: u64, _: ?*anyopaque, _: usize) callconv(.c) i32 {
        return -3;
    }

    fn worldSetBlock(context: ?*anyopaque, world_handle: u64, dimension: abi.StringView, x: i32, y: i32, z: i32, block: abi.StringView) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context.?));
        const tecton = self.tecton orelse return -1;
        const world = self.findWorldByHandle(tecton, world_handle) orelse return -1;
        const dimension_value = world.getDimension(dimension.slice()) orelse return -2;
        const permutation = @import("../world/block/block_permutation.zig").BlockPermutation.resolve(self.allocator, block.slice(), null) catch return -3;
        dimension_value.setPermutation(.{ .x = x, .y = y, .z = z }, permutation, 0) catch return -3;
        return 0;
    }

    fn networkSend(context: ?*anyopaque, player_handle: u64, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
        const send_priority = sendPriority(priority) orelse return abi.result_invalid_argument;
        const payload = bytes.slice();
        if (payload.len == 0 or payload.len > MAX_PLUGIN_PACKET_BYTES) return abi.result_invalid_argument;
        const tecton = self.tecton orelse return abi.result_not_found;
        if (!isTickThread(tecton)) return abi.result_wrong_thread;
        const player = self.findPlayerByHandle(tecton, player_handle) orelse return abi.result_invalid_handle;
        tecton.network.sendPacketWith(player.connection, payload, send_priority) catch return abi.result_out_of_memory;
        return abi.result_ok;
    }

    fn networkBroadcast(context: ?*anyopaque, bytes: abi.StringView, priority: u32) callconv(.c) i32 {
        const self: *PluginRuntime = @ptrCast(@alignCast(context orelse return abi.result_invalid_argument));
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

    fn findPlayerByHandle(self: *PluginRuntime, tecton: *Tecton, handle: u64) ?*Player {
        const pointer = self.handles.get(.player, handle) orelse return null;
        for (tecton.getPlayerSnapshots()) |player| {
            if (@intFromPtr(player) == pointer) return player;
        }
        return null;
    }

    fn findWorldByHandle(self: *PluginRuntime, tecton: *Tecton, handle: u64) ?*World {
        const pointer = self.handles.get(.world, handle) orelse return null;
        var worlds = tecton.worlds.valueIterator();
        while (worlds.next()) |world| {
            if (@intFromPtr(world.*) == pointer) return world.*;
        }
        return null;
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const abi = test_owner.abi;
    pub const SendPriority = test_owner.SendPriority;
    pub const MAX_PLUGIN_PACKET_BYTES = test_owner.MAX_PLUGIN_PACKET_BYTES;
    pub const PluginRuntime = test_owner.PluginRuntime;
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
