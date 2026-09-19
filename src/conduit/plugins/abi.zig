const std = @import("std");

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 3;
pub const descriptor_query_minor: u32 = 0;
pub const descriptor_version: u32 = 1;
pub const feature_events: u64 = 1 << 0;
pub const feature_world: u64 = 1 << 1;
pub const feature_logging: u64 = 1 << 2;
pub const feature_allocator: u64 = 1 << 3;
pub const feature_interfaces: u64 = 1 << 4;
pub const feature_core: u64 = 1 << 5;
pub const feature_scheduler: u64 = 1 << 6;
pub const feature_players: u64 = 1 << 7;
pub const feature_entities: u64 = 1 << 8;
pub const feature_items: u64 = 1 << 9;
pub const feature_blocks: u64 = 1 << 10;
pub const feature_inventories: u64 = 1 << 11;
pub const interface_core: u32 = 1;
pub const interface_logging: u32 = 2;
pub const interface_events: u32 = 3;
pub const interface_scheduler: u32 = 4;
pub const interface_world: u32 = 5;
pub const interface_players: u32 = 6;
pub const interface_entities: u32 = 7;
pub const interface_items: u32 = 8;
pub const interface_blocks: u32 = 9;
pub const interface_inventories: u32 = 10;
pub const interface_registries: u32 = 11;
pub const event_flag_cancelable: u32 = 1 << 0;
pub const event_flag_mutable: u32 = 1 << 1;
pub const event_flag_callback_only: u32 = 1 << 2;
pub const result_ok: i32 = 0;
pub const result_invalid_argument: i32 = -1;
pub const result_unsupported: i32 = -2;
pub const result_not_found: i32 = -3;
pub const result_wrong_thread: i32 = -4;
pub const result_invalid_handle: i32 = -5;
pub const result_busy: i32 = -6;
pub const result_conflict: i32 = -7;
pub const result_out_of_memory: i32 = -8;

pub const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,

    pub fn slice(self: StringView) []const u8 {
        const ptr = self.data orelse return "";
        return ptr[0..self.length];
    }
};

pub const ApiVersion = extern struct { major: u16, minor: u16, protocol: u32 };
pub const Metadata = extern struct { struct_size: u32, name: StringView, version: StringView, description: StringView, api: ApiVersion, capabilities: u64 };

pub const EventId = enum(u32) {
    server_start = 0, server_shutdown = 1, server_tick = 2, player_join = 3, player_disconnect = 4, player_chat = 5, item_use = 6, player_move = 7, damage = 8, block_place = 9, block_break = 10, inventory_open = 11, inventory_click = 12, inventory_close = 13, transaction_prepare = 14, transaction_commit = 15, transaction_abort = 16,
};
pub const EventPhase = enum(u32) { pre, commit, post };
pub const EventResult = enum(u32) { continue_, cancel };
pub const EventView = extern struct { event_id: u32, phase: u32, data: ?*const anyopaque, data_size: usize, result: *u32, payload_version: u32, struct_size: u32, flags: u32, payload_schema: u32 };
pub const ServerTickEvent = extern struct { tick: u64 };
pub const PlayerEvent = extern struct { handle: u64 };
pub const EventCallbackFn = *const fn (?*anyopaque, *const EventView) callconv(.c) void;
pub const EventSubscribeFn = *const fn (?*anyopaque, u32, u32, i16, ?EventCallbackFn, ?*anyopaque, ?*u64) callconv(.c) i32;
pub const EventUnsubscribeFn = *const fn (?*anyopaque, u64) callconv(.c) i32;
pub const AllocFn = *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) void;
pub const LogFn = *const fn (?*anyopaque, u32, StringView) callconv(.c) void;
pub const PluginLogFn = *const fn (?*anyopaque, u32, StringView) callconv(.c) void;
pub const InterfaceHeader = extern struct { struct_size: u32, major: u16, minor: u16, interface_id: u32, features: u64 };
pub const InterfacePtr = *const InterfaceHeader;
pub const GetInterfaceFn = *const fn (?*anyopaque, u32, u16, u16, ?*?InterfacePtr) callconv(.c) i32;
pub const WorldFindFn = *const fn (?*anyopaque, StringView, *u64) callconv(.c) i32;
pub const PlayerSnapshotFn = *const fn (?*anyopaque, u64, ?*anyopaque, usize) callconv(.c) i32;
pub const WorldSetBlockFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, StringView) callconv(.c) i32;
pub const CoreGetTickFn = *const fn (?*anyopaque, ?*u64) callconv(.c) i32;
pub const CoreGetStateFn = *const fn (?*anyopaque, ?*u32) callconv(.c) i32;
pub const SchedulerCallbackFn = *const fn (?*anyopaque) callconv(.c) i32;
pub const SchedulerScheduleFn = *const fn (?*anyopaque, u32, SchedulerCallbackFn, ?*anyopaque, ?*u64) callconv(.c) i32;
pub const SchedulerCancelFn = *const fn (?*anyopaque, u64) callconv(.c) i32;
pub const SchedulerCancelOwnerFn = *const fn (?*anyopaque, u32) callconv(.c) i32;

pub const SnapshotHeader = extern struct { struct_size: u32, version: u16, reserved: u16 };
pub const WorldSnapshot = extern struct { header: SnapshotHeader, handle: u64, name: StringView };
pub const PlayerSnapshot = extern struct { header: SnapshotHeader, handle: u64, runtime_id: i64, name: StringView, uuid: StringView, world: u64, dimension: StringView, x: f32, y: f32, z: f32 };
pub const EntitySnapshot = extern struct { header: SnapshotHeader, handle: u64, runtime_id: i64, type: StringView, world: u64, dimension: StringView, x: f32, y: f32, z: f32 };
pub const WorldFindInterfaceFn = *const fn (?*anyopaque, StringView, *u64) callconv(.c) i32;
pub const WorldGetSnapshotFn = *const fn (?*anyopaque, u64, ?*WorldSnapshot, usize) callconv(.c) i32;
pub const PlayersCountFn = *const fn (?*anyopaque, *usize) callconv(.c) i32;
pub const PlayersGetSnapshotFn = *const fn (?*anyopaque, usize, ?*PlayerSnapshot, usize) callconv(.c) i32;
pub const EntitiesCountFn = *const fn (?*anyopaque, u64, StringView, *usize) callconv(.c) i32;
pub const EntitiesGetSnapshotFn = *const fn (?*anyopaque, u64, StringView, usize, ?*EntitySnapshot, usize) callconv(.c) i32;
pub const WorldApi = extern struct { header: InterfaceHeader, find: WorldFindInterfaceFn, get_snapshot: WorldGetSnapshotFn };
pub const PlayersApi = extern struct { header: InterfaceHeader, count: PlayersCountFn, get_snapshot: PlayersGetSnapshotFn };
pub const EntitiesApi = extern struct { header: InterfaceHeader, count: EntitiesCountFn, get_snapshot: EntitiesGetSnapshotFn };
pub const ItemSnapshot = extern struct { header: SnapshotHeader, handle: u64, network_id: i32, max_stack_size: u16, stackable: u8, reserved: [5]u8, identifier: StringView };
pub const BlockSnapshot = extern struct { header: SnapshotHeader, world: u64, dimension: StringView, x: i32, y: i32, z: i32, network_id: i32, identifier: StringView };
pub const InventoryItemSnapshot = extern struct { header: SnapshotHeader, present: u8, reserved: [3]u8, count: u16, reserved_count: u16, network_id: i32, metadata: u32, identifier: StringView };
pub const ItemsCountFn = *const fn (?*anyopaque, *usize) callconv(.c) i32;
pub const ItemsGetSnapshotFn = *const fn (?*anyopaque, usize, ?*ItemSnapshot, usize) callconv(.c) i32;
pub const BlocksGetSnapshotFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, ?*BlockSnapshot, usize) callconv(.c) i32;
pub const InventoryGetSizeFn = *const fn (?*anyopaque, u64, *u32) callconv(.c) i32;
pub const InventoryGetItemFn = *const fn (?*anyopaque, u64, u32, ?*InventoryItemSnapshot, usize) callconv(.c) i32;
pub const ItemsApi = extern struct { header: InterfaceHeader, count: ItemsCountFn, get_snapshot: ItemsGetSnapshotFn };
pub const BlocksApi = extern struct { header: InterfaceHeader, get_snapshot: BlocksGetSnapshotFn };
pub const InventoriesApi = extern struct { header: InterfaceHeader, get_size: InventoryGetSizeFn, get_item: InventoryGetItemFn };
pub const CoreApi = extern struct { header: InterfaceHeader, get_tick: CoreGetTickFn, get_state: CoreGetStateFn };
pub const SchedulerApi = extern struct { header: InterfaceHeader, schedule: SchedulerScheduleFn, cancel: SchedulerCancelFn, cancel_owner: SchedulerCancelOwnerFn };
pub const Allocator = extern struct { userdata: ?*anyopaque, alloc: AllocFn, free: FreeFn };

pub const HostApi = extern struct {
    struct_size: u32, api: ApiVersion, userdata: ?*anyopaque, allocator: Allocator, log: LogFn, world_find: WorldFindFn, player_snapshot: PlayerSnapshotFn, world_set_block: WorldSetBlockFn, event_subscribe: EventSubscribeFn, event_unsubscribe: EventUnsubscribeFn, features: u64, log_debug: PluginLogFn, log_info: PluginLogFn, log_warn: PluginLogFn, log_error: PluginLogFn, get_interface: GetInterfaceFn,
};
pub const Context = extern struct { struct_size: u32, plugin_id: u32, host: *const HostApi };
pub const OnLoadFn = *const fn (*Context) callconv(.c) i32;
pub const OnStartFn = *const fn (*Context) callconv(.c) i32;
pub const OnShutdownFn = *const fn (*Context, u32) callconv(.c) void;
pub const OnUnloadFn = *const fn (*Context) callconv(.c) void;
pub const Descriptor = extern struct { struct_size: u32, descriptor_version: u32, metadata: Metadata, on_load: ?OnLoadFn, on_start: ?OnStartFn, on_shutdown: ?OnShutdownFn, on_unload: ?OnUnloadFn };
pub const GetDescriptorFn = *const fn (u32, u32) callconv(.c) ?*const Descriptor;
pub const ShutdownReason = enum(u32) { shutdown = 0, fault = 1, dependency_failed = 2 };
pub const Error = error{ InvalidDescriptor, InvalidMetadata, IncompatibleAbi, IncompatibleApi, MissingCallback, CallbackFailed };

pub fn hasField(struct_size: u32, offset: usize, field_size: usize) bool { return @as(usize, struct_size) >= offset + field_size; }

pub fn validateDescriptor(descriptor: *const Descriptor, protocol: u32) Error!void {
    const descriptor_required = @offsetOf(Descriptor, "on_unload") + @sizeOf(OnUnloadFn);
    const metadata_required = @offsetOf(Metadata, "capabilities") + @sizeOf(u64);
    if (descriptor.struct_size < descriptor_required) return error.InvalidDescriptor;
    if (descriptor.descriptor_version != descriptor_version) return error.InvalidDescriptor;
    if (descriptor.metadata.struct_size < metadata_required) return error.InvalidMetadata;
    if (descriptor.metadata.name.length == 0 or descriptor.metadata.name.data == null) return error.InvalidMetadata;
    if (descriptor.metadata.version.length == 0 or descriptor.metadata.version.data == null) return error.InvalidMetadata;
    if (descriptor.metadata.api.major != abi_major or descriptor.metadata.api.minor > abi_minor) return error.IncompatibleApi;
    if (descriptor.metadata.api.protocol != protocol) return error.IncompatibleApi;
    if (descriptor.on_load == null or descriptor.on_start == null or descriptor.on_shutdown == null or descriptor.on_unload == null) return error.MissingCallback;
}

pub fn metadataName(descriptor: *const Descriptor) []const u8 { return descriptor.metadata.name.slice(); }

test "native descriptor validation accepts the current ABI" {
    const name = "test";
    const version = "1.0.0";
    const descriptor = Descriptor{ .struct_size = @sizeOf(Descriptor), .descriptor_version = descriptor_version, .metadata = .{ .struct_size = @sizeOf(Metadata), .name = .{ .data = name.ptr, .length = name.len }, .version = .{ .data = version.ptr, .length = version.len }, .description = .{}, .api = .{ .major = abi_major, .minor = abi_minor, .protocol = 0 }, .capabilities = 0 }, .on_load = struct { fn f(_: *Context) callconv(.c) i32 { return 0; } }.f, .on_start = struct { fn f(_: *Context) callconv(.c) i32 { return 0; } }.f, .on_shutdown = struct { fn f(_: *Context, _: u32) callconv(.c) void {} }.f, .on_unload = struct { fn f(_: *Context) callconv(.c) void {} }.f };
    try validateDescriptor(&descriptor, 0);
}
