const std = @import("std");

comptime {
    if (@sizeOf(usize) != 8) @compileError("Tecton plugin ABI requires LP64");
}

pub const abi_major: u32 = 2;
pub const abi_minor: u32 = 0;
pub const descriptor_version: u32 = 2;

pub const plugin_status_ok: u32 = 0;
pub const plugin_status_abi_major: u32 = 1;
pub const plugin_status_abi_minor: u32 = 2;
pub const plugin_status_host_too_old: u32 = 3;
pub const plugin_status_build_target: u32 = 4;

pub const log_trace: u32 = 0;
pub const log_debug: u32 = 1;
pub const log_info: u32 = 2;
pub const log_warn: u32 = 3;
pub const log_error: u32 = 4;

pub const shutdown_normal: u32 = 0;
pub const shutdown_fault: u32 = 1;
pub const shutdown_reload: u32 = 2;
pub const shutdown_server_exit: u32 = 3;

pub const event_phase_pre: u16 = 0;
pub const event_phase_commit: u16 = 1;
pub const event_phase_post: u16 = 2;

pub const feature_events: u64 = 1 << 0;
pub const feature_logging: u64 = 1 << 1;
pub const feature_allocator: u64 = 1 << 2;
pub const feature_scheduler: u64 = 1 << 3;
pub const feature_world: u64 = 1 << 4;
pub const feature_players: u64 = 1 << 5;
pub const feature_entities: u64 = 1 << 6;
pub const feature_items: u64 = 1 << 7;
pub const feature_blocks: u64 = 1 << 8;
pub const feature_inventories: u64 = 1 << 9;
pub const feature_registries: u64 = 1 << 10;
pub const feature_network: u64 = 1 << 11;
pub const feature_commands: u64 = 1 << 12;
pub const feature_custom_events: u64 = 1 << 13;
pub const feature_traits: u64 = 1 << 14;
pub const feature_hot_unload: u64 = 1 << 15;
pub const host_features: u64 = feature_events | feature_logging | feature_allocator | feature_scheduler | feature_world | feature_players | feature_entities | feature_items | feature_blocks | feature_inventories | feature_registries | feature_network | feature_commands | feature_custom_events | feature_traits | feature_hot_unload;

pub const block_flag_apply_traits: u32 = 1 << 0;
pub const block_flag_update_clients: u32 = 1 << 1;
pub const block_flag_silent: u32 = 1 << 2;

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
pub const interface_network: u32 = 12;
pub const interface_commands: u32 = 13;

pub fn interfaceFeature(interface_id: u32) u64 {
    return switch (interface_id) {
        interface_logging => feature_logging,
        interface_events => feature_events,
        interface_scheduler => feature_scheduler,
        interface_world => feature_world,
        interface_players => feature_players,
        interface_entities => feature_entities,
        interface_items => feature_items,
        interface_blocks => feature_blocks,
        interface_inventories => feature_inventories,
        interface_registries => feature_registries,
        interface_network => feature_network,
        interface_commands => feature_commands,
        else => 0,
    };
}

pub const max_custom_events: u32 = 128;
pub const custom_payload_max: usize = 56;

pub const event_flag_cancelable: u16 = 1 << 0;
pub const event_flag_mutable: u16 = 1 << 1;
pub const event_flag_callback_only: u16 = 1 << 2;
pub const event_flag_borrowed: u16 = 1 << 3;

pub const result_ok: i32 = 0;
pub const result_invalid_argument: i32 = -1;
pub const result_unsupported: i32 = -2;
pub const result_not_found: i32 = -3;
pub const result_wrong_thread: i32 = -4;
pub const result_invalid_handle: i32 = -5;
pub const result_busy: i32 = -6;
pub const result_conflict: i32 = -7;
pub const result_out_of_memory: i32 = -8;
pub const result_version: i32 = -9;
pub const result_unloaded: i32 = -10;
pub const result_denied: i32 = -11;
pub const result_limit: i32 = -12;

pub const load_ok: u32 = 0;
pub const load_dlopen: u32 = 1;
pub const load_symbol_missing: u32 = 2;
pub const load_legacy_abi: u32 = 3;
pub const load_abi_major: u32 = 4;
pub const load_abi_minor: u32 = 5;
pub const load_fingerprint: u32 = 6;
pub const load_descriptor: u32 = 7;
pub const load_metadata: u32 = 8;
pub const load_duplicate_name: u32 = 9;
pub const load_required_feature: u32 = 10;
pub const load_missing_callback: u32 = 11;
pub const load_callback_failed: u32 = 12;
pub const load_out_of_memory: u32 = 13;
pub const load_reason_count: usize = load_out_of_memory + 1;

pub const LoadReason = enum(u32) {
    ok = load_ok,
    dlopen = load_dlopen,
    symbol_missing = load_symbol_missing,
    legacy_abi = load_legacy_abi,
    abi_major = load_abi_major,
    abi_minor = load_abi_minor,
    fingerprint = load_fingerprint,
    descriptor = load_descriptor,
    metadata = load_metadata,
    duplicate_name = load_duplicate_name,
    required_feature = load_required_feature,
    missing_callback = load_missing_callback,
    callback_failed = load_callback_failed,
    out_of_memory = load_out_of_memory,
};

pub fn loadReasonName(reason: u32) []const u8 {
    return switch (reason) {
        load_ok => "ok",
        load_dlopen => "dlopen",
        load_symbol_missing => "symbol_missing",
        load_legacy_abi => "legacy_abi",
        load_abi_major => "abi_major",
        load_abi_minor => "abi_minor",
        load_fingerprint => "fingerprint",
        load_descriptor => "descriptor",
        load_metadata => "metadata",
        load_duplicate_name => "duplicate_name",
        load_required_feature => "required_feature",
        load_missing_callback => "missing_callback",
        load_callback_failed => "callback_failed",
        load_out_of_memory => "out_of_memory",
        else => "unknown",
    };
}

pub fn shutdownReasonName(reason: u32) []const u8 {
    return switch (reason) {
        shutdown_normal => "normal",
        shutdown_fault => "fault",
        shutdown_reload => "reload",
        shutdown_server_exit => "server_exit",
        else => "unknown",
    };
}

pub const packet_priority_normal: u32 = 0;
pub const packet_priority_immediate: u32 = 1;
pub const event_custom_base: u32 = 0x1000;

pub const schema_server_tick: u32 = (@backingInt(EventId.server_tick) << 8) | 1;
pub const schema_player: u32 = (@backingInt(EventId.player_join) << 8) | 1;

pub const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,

    pub fn slice(self: StringView) []const u8 {
        const ptr = self.data orelse return "";
        return ptr[0..self.length];
    }
};

pub const ApiVersion = extern struct { major: u16, minor: u16, patch: u16, reserved: u16 };

pub const HostQuery = extern struct {
    struct_size: u32,
    abi_major: u32,
    abi_minor: u32,
    reserved: u32,
    abi_fingerprint: u64,
    host_features: u64,
    tick_rate: u32,
    reserved2: u32,
};

pub const PluginInfo = extern struct {
    struct_size: u32,
    status: u32,
    abi_major: u32,
    abi_minor: u32,
    abi_fingerprint: u64,
    descriptor: ?*const Descriptor,
    diagnostic: StringView,
    reserved: u64,
};

pub const Metadata = extern struct {
    struct_size: u32,
    plugin_flags: u32,
    name: StringView,
    version: StringView,
    description: StringView,
    api: ApiVersion,
    required_features: u64,
    optional_features: u64,
};

pub const Descriptor = extern struct {
    struct_size: u32,
    descriptor_version: u32,
    abi_fingerprint: u64,
    metadata: Metadata,
    on_load: ?OnLoadFn,
    on_start: ?OnStartFn,
    on_shutdown: ?OnShutdownFn,
    on_unload: ?OnUnloadFn,
    on_ready: ?OnReadyFn,
};

pub const Context = extern struct {
    struct_size: u32,
    plugin_id: u32,
    host: *const HostApi,
    engine: ?*anyopaque,
    reserved: u64,
};

pub const Allocator = extern struct {
    userdata: ?*anyopaque,
    alloc: AllocFn,
    free: FreeFn,
    realloc: ReallocFn,
    alloc_zeroed: AllocFn,
};

pub const InterfaceHeader = extern struct {
    struct_size: u32,
    major: u16,
    minor: u16,
    interface_id: u32,
    reserved: u32,
    features: u64,
};
pub const InterfacePtr = *const InterfaceHeader;

pub const EventId = enum(u32) {
    server_start = 0,
    server_shutdown = 1,
    server_tick = 2,
    player_join = 3,
    player_disconnect = 4,
    player_chat = 5,
    item_use = 6,
    player_move = 7,
    damage = 8,
    block_place = 9,
    block_break = 10,
    inventory_open = 11,
    inventory_click = 12,
    inventory_close = 13,
    transaction_prepare = 14,
    transaction_commit = 15,
    transaction_abort = 16,
    entity_combust = 17,
    enchantment_apply = 18,
    enchantment_remove = 19,
    entity_spawn = 20,
    entity_despawn = 21,
    entity_damage = 22,
    entity_death = 23,
    entity_interact = 24,
};

pub const EventResult = enum(i32) { continue_ = 0, cancel = 1 };

pub const PayloadKind = enum {
    none,
    server_tick,
    player_join,
    player_ref,
    player_chat,
    item_use,
    player_move,
    damage,
    block_place,
    block_break,
    inventory,
    inventory_click,
    transaction,
    entity_combust,
    enchant,
    entity_spawn,
    entity_despawn,
    entity_damage,
    entity_death,
    entity_interact,
};

pub const EventMeta = struct {
    external_id: u32,
    schema: u32,
    flags: u16,
    payload: PayloadKind,
    payload_size: usize,
};

fn payloadSize(payload: PayloadKind) usize {
    return switch (payload) {
        .none => 0,
        .server_tick => @sizeOf(ServerTickEvent),
        .player_join => @sizeOf(PlayerJoinEvent),
        .player_ref => @sizeOf(PlayerRefEvent),
        .player_chat => @sizeOf(PlayerChatEvent),
        .item_use => @sizeOf(ItemUseEvent),
        .player_move => @sizeOf(PlayerMoveEvent),
        .damage => @sizeOf(DamageEvent),
        .block_place => @sizeOf(BlockPlaceEvent),
        .block_break => @sizeOf(BlockBreakEvent),
        .inventory => @sizeOf(InventoryEvent),
        .inventory_click => @sizeOf(InventoryClickEvent),
        .transaction => @sizeOf(TransactionEvent),
        .entity_combust => @sizeOf(EntityCombustEvent),
        .enchant => @sizeOf(EnchantEvent),
        .entity_spawn => @sizeOf(EntitySpawnEvent),
        .entity_despawn => @sizeOf(EntityDespawnEvent),
        .entity_damage => @sizeOf(EntityDamageEvent),
        .entity_death => @sizeOf(EntityDeathEvent),
        .entity_interact => @sizeOf(EntityInteractEvent),
    };
}

pub fn eventMeta(event: EventId) EventMeta {
    const payload: PayloadKind = switch (event) {
        .server_start, .server_shutdown => .none,
        .server_tick => .server_tick,
        .player_join => .player_join,
        .player_disconnect => .player_ref,
        .player_chat => .player_chat,
        .item_use => .item_use,
        .player_move => .player_move,
        .damage => .damage,
        .block_place => .block_place,
        .block_break => .block_break,
        .inventory_open, .inventory_close => .inventory,
        .inventory_click => .inventory_click,
        .transaction_prepare, .transaction_commit, .transaction_abort => .transaction,
        .entity_combust => .entity_combust,
        .enchantment_apply, .enchantment_remove => .enchant,
        .entity_spawn => .entity_spawn,
        .entity_despawn => .entity_despawn,
        .entity_damage => .entity_damage,
        .entity_death => .entity_death,
        .entity_interact => .entity_interact,
    };
    // InventoryOpen/Click/Close, TransactionPrepare and EntityInteract stay ABI-only until a core
    // emitter honors their result; a cancelable flag without a route would be a false promise.
    const cancelable = switch (event) {
        .player_join,
        .player_chat,
        .item_use,
        .player_move,
        .damage,
        .block_place,
        .block_break,
        .entity_combust,
        .enchantment_apply,
        .enchantment_remove,
        .entity_damage,
        => true,
        else => false,
    };
    const mutable = switch (event) {
        .player_chat, .player_move, .damage, .entity_combust, .enchantment_apply, .entity_damage => true,
        else => false,
    };
    const id = @backingInt(event);
    const version: u32 = if (payload == .none) 0 else 1;
    return .{
        .external_id = id,
        .schema = (id << 8) | version,
        .flags = event_flag_callback_only | event_flag_borrowed | (if (cancelable) event_flag_cancelable else 0) | (if (mutable) event_flag_mutable else 0),
        .payload = payload,
        .payload_size = payloadSize(payload),
    };
}

pub const EventView = extern struct {
    data: ?*const anyopaque,
    data_size: usize,
    result: *i32,
    schema: u32,
    event_id: u32,
    phase: u16,
    flags: u16,
};

pub const ServerTickEvent = extern struct { tick: u64 };
pub const PlayerEvent = extern struct { handle: u64 };
pub const PlayerJoinEvent = extern struct { handle: u64, runtime_id: i64 };
pub const PlayerRefEvent = extern struct { handle: u64, runtime_id: i64 };
pub const PlayerChatEvent = extern struct { runtime_id: i64, message: StringView, flags: u32, reserved: u32 };
pub const ItemUseEvent = extern struct { runtime_id: i64, identifier: StringView, flags: u32, reserved: u32 };
pub const PlayerMoveEvent = extern struct { runtime_id: i64, from_x: f32, from_y: f32, from_z: f32, to_x: f32, to_y: f32, to_z: f32, on_ground: u32, reserved: u32 };
pub const DamageEvent = extern struct { victim_runtime: i64, attacker_runtime: i64, amount: f32, cause: u32, reserved: u32 };
pub const BlockPlaceEvent = extern struct { runtime_id: i64, x: i32, y: i32, z: i32, network_id: i32, reserved: u32 };
pub const BlockBreakEvent = extern struct { runtime_id: i64, x: i32, y: i32, z: i32, network_id: i32, reserved: u32 };
pub const InventoryEvent = extern struct { handle: u64, container_id: u32, reserved: u32 };
pub const InventoryClickEvent = extern struct { handle: u64, slot: u16, button: u8, reserved: u8, reserved2: u32 };
pub const TransactionEvent = extern struct { handle: u64, transaction_id: [16]u8, committed: u32, reserved: u32 };
pub const EntityCombustEvent = extern struct { runtime_id: i64, instigator_runtime: i64, duration: i32, source: u32 };
pub const EnchantEvent = extern struct { item_handle: u64, actor_runtime: i64, enchantment_id: u32, previous_level: u8, level: u8, source: u8, reserved: u8 };
pub const EntitySpawnEvent = extern struct { runtime_id: i64, reserved: u64 };
pub const EntityDespawnEvent = extern struct { runtime_id: i64, cause: u32, reserved: u32 };
pub const EntityDamageEvent = extern struct { target_runtime: i64, source_runtime: i64, amount: f32, cause: u32, reserved: u32 };
pub const EntityDeathEvent = extern struct { runtime_id: i64, killer_runtime: i64, x: f32, y: f32, z: f32, reserved: u32 };
pub const EntityInteractEvent = extern struct { target_runtime: i64, player_runtime: i64, action: u32, reserved: u32 };

pub const EventPayload = union {
    server_tick: ServerTickEvent,
    player_join: PlayerJoinEvent,
    player_ref: PlayerRefEvent,
    player_chat: PlayerChatEvent,
    item_use: ItemUseEvent,
    player_move: PlayerMoveEvent,
    damage: DamageEvent,
    block_place: BlockPlaceEvent,
    block_break: BlockBreakEvent,
    inventory: InventoryEvent,
    inventory_click: InventoryClickEvent,
    transaction: TransactionEvent,
    entity_combust: EntityCombustEvent,
    enchant: EnchantEvent,
    entity_spawn: EntitySpawnEvent,
    entity_despawn: EntityDespawnEvent,
    entity_damage: EntityDamageEvent,
    entity_death: EntityDeathEvent,
    entity_interact: EntityInteractEvent,
};

pub const SnapshotHeader = extern struct { struct_size: u32, version: u16, reserved: u16 };
pub const WorldSnapshot = extern struct { header: SnapshotHeader, handle: u64, name: StringView };
pub const PlayerSnapshot = extern struct { header: SnapshotHeader, handle: u64, runtime_id: i64, name: StringView, uuid: StringView, world: u64, dimension: StringView, x: f32, y: f32, z: f32, yaw: f32, pitch: f32, gamemode: u32, spawned: u32 };
pub const EntitySnapshot = extern struct { header: SnapshotHeader, handle: u64, runtime_id: i64, type: StringView, world: u64, dimension: StringView, x: f32, y: f32, z: f32 };
pub const ItemSnapshot = extern struct { header: SnapshotHeader, handle: u64, network_id: i32, max_stack_size: u16, stackable: u8, reserved: [5]u8, identifier: StringView };
pub const BlockSnapshot = extern struct { header: SnapshotHeader, world: u64, dimension: StringView, x: i32, y: i32, z: i32, network_id: i32, identifier: StringView };
pub const InventoryItemSnapshot = extern struct { header: SnapshotHeader, present: u8, reserved: [3]u8, count: u16, reserved_count: u16, network_id: i32, metadata: u32, identifier: StringView };

pub const EventCallbackFn = *const fn (?*anyopaque, *const EventView) callconv(.c) void;
pub const EventSubscribeFn = *const fn (?*anyopaque, u32, u16, i16, ?EventCallbackFn, ?*anyopaque, ?*u64) callconv(.c) i32;
pub const EventUnsubscribeFn = *const fn (?*anyopaque, u64) callconv(.c) i32;
pub const EmitCustomFn = *const fn (?*anyopaque, u32, ?*const anyopaque, usize, u32) callconv(.c) i32;
pub const AllocFn = *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) void;
pub const ReallocFn = *const fn (?*anyopaque, ?*anyopaque, usize, usize, usize) callconv(.c) ?*anyopaque;
pub const LogFn = *const fn (?*anyopaque, u32, StringView) callconv(.c) void;
pub const GetInterfaceFn = *const fn (?*anyopaque, u32, u16, u16, ?*?InterfacePtr) callconv(.c) i32;
pub const TimerCallbackFn = *const fn (?*anyopaque, u64) callconv(.c) void;
pub const SchedulerAfterFn = *const fn (?*anyopaque, u32, ?TimerCallbackFn, ?*anyopaque, ?*u64) callconv(.c) i32;
pub const SchedulerEveryFn = SchedulerAfterFn;
pub const LogIsEnabledFn = *const fn (?*anyopaque, u32) callconv(.c) i32;
pub const LogSetLevelFn = *const fn (?*anyopaque, u32) callconv(.c) void;
pub const LogSetScopeFn = *const fn (?*anyopaque, StringView) callconv(.c) void;
pub const SchemaOfFn = *const fn (?*anyopaque, StringView, u32, ?*u32) callconv(.c) i32;
pub const RegistryFn = *const fn (?*anyopaque, ?*RegistryView) callconv(.c) i32;
pub const BlockBox = extern struct { min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32 };
pub const CommandHandlerFn = *const fn (*const CommandCall) callconv(.c) i32;
pub const CommandRegisterFn = *const fn (?*anyopaque, ?*const CommandDesc, ?*u64) callconv(.c) i32;
pub const CommandUnregisterFn = *const fn (?*anyopaque, u64) callconv(.c) i32;
pub const CommandMarkDirtyFn = *const fn (?*anyopaque) callconv(.c) void;
pub const WorldFindFn = *const fn (?*anyopaque, StringView, *u64) callconv(.c) i32;
pub const WorldGetSnapshotFn = *const fn (?*anyopaque, u64, ?*WorldSnapshot, usize) callconv(.c) i32;
pub const WorldSetBlockFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, StringView) callconv(.c) i32;
pub const WorldGetBlockStateFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, ?*u32) callconv(.c) i32;
pub const WorldSetBlockStateFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, u32, u32) callconv(.c) i32;
pub const BlockCallbackFn = *const fn (?*anyopaque, i32, i32, i32, u32) callconv(.c) void;
pub const WorldForEachInBoxFn = *const fn (?*anyopaque, u64, StringView, BlockBox, ?BlockCallbackFn, ?*anyopaque) callconv(.c) i32;
pub const PlayersCountFn = *const fn (?*anyopaque, *usize) callconv(.c) i32;
pub const PlayersGetSnapshotFn = *const fn (?*anyopaque, u64, ?*PlayerSnapshot, usize) callconv(.c) i32;
pub const PlayersGetByIndexFn = *const fn (?*anyopaque, usize, ?*PlayerSnapshot, usize) callconv(.c) i32;
pub const PlayersGetByRuntimeFn = *const fn (?*anyopaque, i64, ?*PlayerSnapshot, usize) callconv(.c) i32;
pub const PlayerCallbackFn = *const fn (?*anyopaque, *const PlayerSnapshot) callconv(.c) void;
pub const PlayersForEachFn = *const fn (?*anyopaque, ?PlayerCallbackFn, ?*anyopaque) callconv(.c) i32;
pub const EntitiesCountFn = *const fn (?*anyopaque, u64, StringView, *usize) callconv(.c) i32;
pub const EntitiesGetSnapshotFn = *const fn (?*anyopaque, u64, ?*EntitySnapshot, usize) callconv(.c) i32;
pub const EntitiesGetByIndexFn = *const fn (?*anyopaque, u64, StringView, usize, ?*EntitySnapshot, usize) callconv(.c) i32;
pub const EntitiesGetByRuntimeFn = *const fn (?*anyopaque, u64, StringView, i64, ?*EntitySnapshot, usize) callconv(.c) i32;
pub const EntityCallbackFn = *const fn (?*anyopaque, *const EntitySnapshot) callconv(.c) void;
pub const EntitiesForEachFn = *const fn (?*anyopaque, u64, StringView, ?EntityCallbackFn, ?*anyopaque) callconv(.c) i32;
pub const ItemsCountFn = *const fn (?*anyopaque, *usize) callconv(.c) i32;
pub const ItemsGetSnapshotFn = *const fn (?*anyopaque, u64, ?*ItemSnapshot, usize) callconv(.c) i32;
pub const ItemsGetByIndexFn = *const fn (?*anyopaque, usize, ?*ItemSnapshot, usize) callconv(.c) i32;
pub const ItemsGetByNetworkIdFn = *const fn (?*anyopaque, i32, ?*ItemSnapshot, usize) callconv(.c) i32;
pub const ItemCallbackFn = *const fn (?*anyopaque, *const ItemSnapshot) callconv(.c) void;
pub const ItemsForEachFn = *const fn (?*anyopaque, ?ItemCallbackFn, ?*anyopaque) callconv(.c) i32;
pub const BlocksGetSnapshotFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, ?*BlockSnapshot, usize) callconv(.c) i32;
pub const BlocksResolveNameFn = *const fn (?*anyopaque, StringView, ?*u32) callconv(.c) i32;
pub const InventoryGetSizeFn = *const fn (?*anyopaque, u64, *u32) callconv(.c) i32;
pub const InventoryGetItemFn = *const fn (?*anyopaque, u64, u32, ?*InventoryItemSnapshot, usize) callconv(.c) i32;
pub const CoreGetTickFn = *const fn (?*anyopaque, ?*u64) callconv(.c) i32;
pub const CoreGetStateFn = *const fn (?*anyopaque, ?*u32) callconv(.c) i32;
pub const SchedulerCancelFn = *const fn (?*anyopaque, u64) callconv(.c) i32;
pub const SchedulerCancelOwnerFn = *const fn (?*anyopaque) callconv(.c) i32;
pub const NetworkSendFn = *const fn (?*anyopaque, u64, StringView, u32) callconv(.c) i32;
pub const NetworkBroadcastFn = *const fn (?*anyopaque, StringView, u32) callconv(.c) i32;

pub const WorldApi = extern struct { header: InterfaceHeader, find: WorldFindFn, get_snapshot: WorldGetSnapshotFn, set_block: WorldSetBlockFn, get_block_state: WorldGetBlockStateFn, set_block_state: WorldSetBlockStateFn, for_each_in_box: WorldForEachInBoxFn };
pub const PlayersApi = extern struct { header: InterfaceHeader, count: PlayersCountFn, get_snapshot: PlayersGetSnapshotFn, get_by_index: PlayersGetByIndexFn, get_by_runtime: PlayersGetByRuntimeFn, for_each: PlayersForEachFn };
pub const EntitiesApi = extern struct { header: InterfaceHeader, count: EntitiesCountFn, get_snapshot: EntitiesGetSnapshotFn, get_by_index: EntitiesGetByIndexFn, get_by_runtime: EntitiesGetByRuntimeFn, for_each: EntitiesForEachFn };
pub const ItemsApi = extern struct { header: InterfaceHeader, count: ItemsCountFn, get_snapshot: ItemsGetSnapshotFn, get_by_index: ItemsGetByIndexFn, get_by_network_id: ItemsGetByNetworkIdFn, for_each: ItemsForEachFn };
pub const BlocksApi = extern struct { header: InterfaceHeader, get_snapshot: BlocksGetSnapshotFn, resolve_name: BlocksResolveNameFn };
pub const InventoriesApi = extern struct { header: InterfaceHeader, get_size: InventoryGetSizeFn, get_item: InventoryGetItemFn };
pub const CoreApi = extern struct { header: InterfaceHeader, get_tick: CoreGetTickFn, get_state: CoreGetStateFn };
pub const SchedulerApi = extern struct { header: InterfaceHeader, after: SchedulerAfterFn, every: SchedulerEveryFn, cancel: SchedulerCancelFn, cancel_owner: SchedulerCancelOwnerFn };
pub const LoggingApi = extern struct { header: InterfaceHeader, log: LogFn, is_enabled: LogIsEnabledFn, set_level: LogSetLevelFn, set_scope: LogSetScopeFn };
pub const EventsApi = extern struct { header: InterfaceHeader, subscribe: EventSubscribeFn, unsubscribe: EventUnsubscribeFn, emit: EmitCustomFn, emit_immediate: EmitCustomFn, schema_of: SchemaOfFn };

pub const RegistryView = extern struct {
    data: ?*const anyopaque,
    count: usize,
    stride: usize,
    element_version: u32,
    reserved: u32,
};

pub const BlockStateEntry = extern struct { network_id: i32, reserved: u32, identifier: StringView };
pub const ItemEntry = extern struct { network_id: i32, max_stack_size: u16, stackable: u8, reserved: u8, identifier: StringView };
pub const EntityTypeEntry = extern struct { network_id: i32, reserved: u32, identifier: StringView };
pub const RegistriesApi = extern struct { header: InterfaceHeader, block_states: RegistryFn, items: RegistryFn, entity_types: RegistryFn };

pub const CommandDesc = extern struct {
    struct_size: u32,
    flags: u32,
    name: StringView,
    description: StringView,
    permission: StringView,
    aliases: ?[*]const StringView,
    alias_count: u32,
    reserved: u32,
    handler: ?CommandHandlerFn,
    userdata: ?*anyopaque,
};

pub const CommandCall = extern struct {
    struct_size: u32,
    argc: u32,
    argv: ?[*]const StringView,
    raw_line: StringView,
    player: u64,
    world: u64,
    userdata: ?*anyopaque,
};

pub const CommandsApi = extern struct { header: InterfaceHeader, register_command: CommandRegisterFn, unregister: CommandUnregisterFn, mark_dirty: CommandMarkDirtyFn };
pub const NetworkApi = extern struct { header: InterfaceHeader, send: NetworkSendFn, broadcast: NetworkBroadcastFn };

pub const HostApi = extern struct {
    struct_size: u32,
    abi_major: u16,
    abi_minor: u16,
    plugin_id: u32,
    userdata: ?*anyopaque,
    allocator: Allocator,
    log: LogFn,
    event_subscribe: EventSubscribeFn,
    event_unsubscribe: EventUnsubscribeFn,
    emit_custom: EmitCustomFn,
    get_interface: GetInterfaceFn,
    every: SchedulerEveryFn,
    features: u64,
};

pub const OnLoadFn = *const fn (*Context) callconv(.c) i32;
pub const OnStartFn = *const fn (*Context) callconv(.c) i32;
pub const OnShutdownFn = *const fn (*Context, u32) callconv(.c) void;
pub const OnUnloadFn = *const fn (*Context) callconv(.c) void;
pub const OnReadyFn = *const fn (*Context) callconv(.c) void;
pub const QueryFn = *const fn (*const HostQuery, *PluginInfo) callconv(.c) i32;

pub const ShutdownReason = enum(u32) { normal = shutdown_normal, fault = shutdown_fault, reload = shutdown_reload, server_exit = shutdown_server_exit };

pub const Error = error{
    InvalidArgument,
    AbiMajor,
    AbiMinor,
    HostTooOld,
    BuildTarget,
    Fingerprint,
    Descriptor,
    Metadata,
    RequiredFeature,
    MissingCallback,
    CallbackFailed,
};

pub const abi_fp_seed: u64 = 0xcbf29ce484222325;
pub const abi_fp_prime: u64 = 0x100000001b3;

fn mix(hash: u64, value: u64) u64 {
    var accumulator = hash;
    inline for (0..8) |index| {
        const octet = (value >> @intCast(index * 8)) & 0xff;
        accumulator = (accumulator ^ octet) *% abi_fp_prime;
    }
    return accumulator;
}

fn mixSigned(hash: u64, value: i32) u64 {
    return mix(hash, @bitCast(@as(i64, value)));
}

fn fpStringView(hash: u64) u64 {
    return mix(mix(mix(hash, @sizeOf(StringView)), @offsetOf(StringView, "data")), @offsetOf(StringView, "length"));
}

fn fpApiVersion(hash: u64) u64 {
    return mix(mix(mix(mix(mix(hash, @sizeOf(ApiVersion)), @offsetOf(ApiVersion, "major")), @offsetOf(ApiVersion, "minor")), @offsetOf(ApiVersion, "patch")), @offsetOf(ApiVersion, "reserved"));
}

fn fpHostQuery(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(HostQuery));
    h = mix(h, @offsetOf(HostQuery, "struct_size"));
    h = mix(h, @offsetOf(HostQuery, "abi_major"));
    h = mix(h, @offsetOf(HostQuery, "abi_minor"));
    h = mix(h, @offsetOf(HostQuery, "reserved"));
    h = mix(h, @offsetOf(HostQuery, "abi_fingerprint"));
    h = mix(h, @offsetOf(HostQuery, "host_features"));
    h = mix(h, @offsetOf(HostQuery, "tick_rate"));
    return mix(h, @offsetOf(HostQuery, "reserved2"));
}

fn fpPluginInfo(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PluginInfo));
    h = mix(h, @offsetOf(PluginInfo, "struct_size"));
    h = mix(h, @offsetOf(PluginInfo, "status"));
    h = mix(h, @offsetOf(PluginInfo, "abi_major"));
    h = mix(h, @offsetOf(PluginInfo, "abi_minor"));
    h = mix(h, @offsetOf(PluginInfo, "abi_fingerprint"));
    h = mix(h, @offsetOf(PluginInfo, "descriptor"));
    h = mix(h, @offsetOf(PluginInfo, "diagnostic"));
    return mix(h, @offsetOf(PluginInfo, "reserved"));
}

fn fpMetadata(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(Metadata));
    h = mix(h, @offsetOf(Metadata, "struct_size"));
    h = mix(h, @offsetOf(Metadata, "plugin_flags"));
    h = mix(h, @offsetOf(Metadata, "name"));
    h = mix(h, @offsetOf(Metadata, "version"));
    h = mix(h, @offsetOf(Metadata, "description"));
    h = mix(h, @offsetOf(Metadata, "api"));
    h = mix(h, @offsetOf(Metadata, "required_features"));
    return mix(h, @offsetOf(Metadata, "optional_features"));
}

fn fpDescriptor(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(Descriptor));
    h = mix(h, @offsetOf(Descriptor, "struct_size"));
    h = mix(h, @offsetOf(Descriptor, "descriptor_version"));
    h = mix(h, @offsetOf(Descriptor, "abi_fingerprint"));
    h = mix(h, @offsetOf(Descriptor, "metadata"));
    h = mix(h, @offsetOf(Descriptor, "on_load"));
    h = mix(h, @offsetOf(Descriptor, "on_start"));
    h = mix(h, @offsetOf(Descriptor, "on_shutdown"));
    h = mix(h, @offsetOf(Descriptor, "on_unload"));
    return mix(h, @offsetOf(Descriptor, "on_ready"));
}

fn fpContext(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(Context));
    h = mix(h, @offsetOf(Context, "struct_size"));
    h = mix(h, @offsetOf(Context, "plugin_id"));
    h = mix(h, @offsetOf(Context, "host"));
    h = mix(h, @offsetOf(Context, "engine"));
    return mix(h, @offsetOf(Context, "reserved"));
}

fn fpAllocator(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(Allocator));
    h = mix(h, @offsetOf(Allocator, "userdata"));
    h = mix(h, @offsetOf(Allocator, "alloc"));
    h = mix(h, @offsetOf(Allocator, "free"));
    h = mix(h, @offsetOf(Allocator, "realloc"));
    return mix(h, @offsetOf(Allocator, "alloc_zeroed"));
}

fn fpInterfaceHeader(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(InterfaceHeader));
    h = mix(h, @offsetOf(InterfaceHeader, "struct_size"));
    h = mix(h, @offsetOf(InterfaceHeader, "major"));
    h = mix(h, @offsetOf(InterfaceHeader, "minor"));
    h = mix(h, @offsetOf(InterfaceHeader, "interface_id"));
    h = mix(h, @offsetOf(InterfaceHeader, "reserved"));
    return mix(h, @offsetOf(InterfaceHeader, "features"));
}

fn fpEventView(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EventView));
    h = mix(h, @offsetOf(EventView, "data"));
    h = mix(h, @offsetOf(EventView, "data_size"));
    h = mix(h, @offsetOf(EventView, "result"));
    h = mix(h, @offsetOf(EventView, "schema"));
    h = mix(h, @offsetOf(EventView, "event_id"));
    h = mix(h, @offsetOf(EventView, "phase"));
    return mix(h, @offsetOf(EventView, "flags"));
}

fn fpServerTickEvent(hash: u64) u64 {
    return mix(mix(hash, @sizeOf(ServerTickEvent)), @offsetOf(ServerTickEvent, "tick"));
}

fn fpPlayerEvent(hash: u64) u64 {
    return mix(mix(hash, @sizeOf(PlayerEvent)), @offsetOf(PlayerEvent, "handle"));
}

fn fpPlayerJoinEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayerJoinEvent));
    h = mix(h, @offsetOf(PlayerJoinEvent, "handle"));
    return mix(h, @offsetOf(PlayerJoinEvent, "runtime_id"));
}

fn fpPlayerRefEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayerRefEvent));
    h = mix(h, @offsetOf(PlayerRefEvent, "handle"));
    return mix(h, @offsetOf(PlayerRefEvent, "runtime_id"));
}

fn fpPlayerChatEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayerChatEvent));
    h = mix(h, @offsetOf(PlayerChatEvent, "runtime_id"));
    h = mix(h, @offsetOf(PlayerChatEvent, "message"));
    h = mix(h, @offsetOf(PlayerChatEvent, "flags"));
    return mix(h, @offsetOf(PlayerChatEvent, "reserved"));
}

fn fpItemUseEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(ItemUseEvent));
    h = mix(h, @offsetOf(ItemUseEvent, "runtime_id"));
    h = mix(h, @offsetOf(ItemUseEvent, "identifier"));
    h = mix(h, @offsetOf(ItemUseEvent, "flags"));
    return mix(h, @offsetOf(ItemUseEvent, "reserved"));
}

fn fpPlayerMoveEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayerMoveEvent));
    h = mix(h, @offsetOf(PlayerMoveEvent, "runtime_id"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "from_x"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "from_y"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "from_z"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "to_x"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "to_y"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "to_z"));
    h = mix(h, @offsetOf(PlayerMoveEvent, "on_ground"));
    return mix(h, @offsetOf(PlayerMoveEvent, "reserved"));
}

fn fpDamageEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(DamageEvent));
    h = mix(h, @offsetOf(DamageEvent, "victim_runtime"));
    h = mix(h, @offsetOf(DamageEvent, "attacker_runtime"));
    h = mix(h, @offsetOf(DamageEvent, "amount"));
    h = mix(h, @offsetOf(DamageEvent, "cause"));
    return mix(h, @offsetOf(DamageEvent, "reserved"));
}

fn fpBlockPlaceEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlockPlaceEvent));
    h = mix(h, @offsetOf(BlockPlaceEvent, "runtime_id"));
    h = mix(h, @offsetOf(BlockPlaceEvent, "x"));
    h = mix(h, @offsetOf(BlockPlaceEvent, "y"));
    h = mix(h, @offsetOf(BlockPlaceEvent, "z"));
    h = mix(h, @offsetOf(BlockPlaceEvent, "network_id"));
    return mix(h, @offsetOf(BlockPlaceEvent, "reserved"));
}

fn fpBlockBreakEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlockBreakEvent));
    h = mix(h, @offsetOf(BlockBreakEvent, "runtime_id"));
    h = mix(h, @offsetOf(BlockBreakEvent, "x"));
    h = mix(h, @offsetOf(BlockBreakEvent, "y"));
    h = mix(h, @offsetOf(BlockBreakEvent, "z"));
    h = mix(h, @offsetOf(BlockBreakEvent, "network_id"));
    return mix(h, @offsetOf(BlockBreakEvent, "reserved"));
}

fn fpInventoryEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(InventoryEvent));
    h = mix(h, @offsetOf(InventoryEvent, "handle"));
    h = mix(h, @offsetOf(InventoryEvent, "container_id"));
    return mix(h, @offsetOf(InventoryEvent, "reserved"));
}

fn fpInventoryClickEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(InventoryClickEvent));
    h = mix(h, @offsetOf(InventoryClickEvent, "handle"));
    h = mix(h, @offsetOf(InventoryClickEvent, "slot"));
    h = mix(h, @offsetOf(InventoryClickEvent, "button"));
    h = mix(h, @offsetOf(InventoryClickEvent, "reserved"));
    return mix(h, @offsetOf(InventoryClickEvent, "reserved2"));
}

fn fpTransactionEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(TransactionEvent));
    h = mix(h, @offsetOf(TransactionEvent, "handle"));
    h = mix(h, @offsetOf(TransactionEvent, "transaction_id"));
    h = mix(h, @offsetOf(TransactionEvent, "committed"));
    return mix(h, @offsetOf(TransactionEvent, "reserved"));
}

fn fpEntityCombustEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityCombustEvent));
    h = mix(h, @offsetOf(EntityCombustEvent, "runtime_id"));
    h = mix(h, @offsetOf(EntityCombustEvent, "instigator_runtime"));
    h = mix(h, @offsetOf(EntityCombustEvent, "duration"));
    return mix(h, @offsetOf(EntityCombustEvent, "source"));
}

fn fpEnchantEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EnchantEvent));
    h = mix(h, @offsetOf(EnchantEvent, "item_handle"));
    h = mix(h, @offsetOf(EnchantEvent, "actor_runtime"));
    h = mix(h, @offsetOf(EnchantEvent, "enchantment_id"));
    h = mix(h, @offsetOf(EnchantEvent, "previous_level"));
    h = mix(h, @offsetOf(EnchantEvent, "level"));
    h = mix(h, @offsetOf(EnchantEvent, "source"));
    return mix(h, @offsetOf(EnchantEvent, "reserved"));
}

fn fpEntitySpawnEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntitySpawnEvent));
    h = mix(h, @offsetOf(EntitySpawnEvent, "runtime_id"));
    return mix(h, @offsetOf(EntitySpawnEvent, "reserved"));
}

fn fpEntityDespawnEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityDespawnEvent));
    h = mix(h, @offsetOf(EntityDespawnEvent, "runtime_id"));
    h = mix(h, @offsetOf(EntityDespawnEvent, "cause"));
    return mix(h, @offsetOf(EntityDespawnEvent, "reserved"));
}

fn fpEntityDamageEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityDamageEvent));
    h = mix(h, @offsetOf(EntityDamageEvent, "target_runtime"));
    h = mix(h, @offsetOf(EntityDamageEvent, "source_runtime"));
    h = mix(h, @offsetOf(EntityDamageEvent, "amount"));
    h = mix(h, @offsetOf(EntityDamageEvent, "cause"));
    return mix(h, @offsetOf(EntityDamageEvent, "reserved"));
}

fn fpEntityDeathEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityDeathEvent));
    h = mix(h, @offsetOf(EntityDeathEvent, "runtime_id"));
    h = mix(h, @offsetOf(EntityDeathEvent, "killer_runtime"));
    h = mix(h, @offsetOf(EntityDeathEvent, "x"));
    h = mix(h, @offsetOf(EntityDeathEvent, "y"));
    h = mix(h, @offsetOf(EntityDeathEvent, "z"));
    return mix(h, @offsetOf(EntityDeathEvent, "reserved"));
}

fn fpEntityInteractEvent(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityInteractEvent));
    h = mix(h, @offsetOf(EntityInteractEvent, "target_runtime"));
    h = mix(h, @offsetOf(EntityInteractEvent, "player_runtime"));
    h = mix(h, @offsetOf(EntityInteractEvent, "action"));
    return mix(h, @offsetOf(EntityInteractEvent, "reserved"));
}

fn fpSnapshotHeader(hash: u64) u64 {
    return mix(mix(mix(mix(hash, @sizeOf(SnapshotHeader)), @offsetOf(SnapshotHeader, "struct_size")), @offsetOf(SnapshotHeader, "version")), @offsetOf(SnapshotHeader, "reserved"));
}

fn fpWorldSnapshot(hash: u64) u64 {
    return mix(mix(mix(mix(hash, @sizeOf(WorldSnapshot)), @offsetOf(WorldSnapshot, "header")), @offsetOf(WorldSnapshot, "handle")), @offsetOf(WorldSnapshot, "name"));
}

fn fpPlayerSnapshot(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayerSnapshot));
    h = mix(h, @offsetOf(PlayerSnapshot, "header"));
    h = mix(h, @offsetOf(PlayerSnapshot, "handle"));
    h = mix(h, @offsetOf(PlayerSnapshot, "runtime_id"));
    h = mix(h, @offsetOf(PlayerSnapshot, "name"));
    h = mix(h, @offsetOf(PlayerSnapshot, "uuid"));
    h = mix(h, @offsetOf(PlayerSnapshot, "world"));
    h = mix(h, @offsetOf(PlayerSnapshot, "dimension"));
    h = mix(h, @offsetOf(PlayerSnapshot, "x"));
    h = mix(h, @offsetOf(PlayerSnapshot, "y"));
    h = mix(h, @offsetOf(PlayerSnapshot, "z"));
    h = mix(h, @offsetOf(PlayerSnapshot, "yaw"));
    h = mix(h, @offsetOf(PlayerSnapshot, "pitch"));
    h = mix(h, @offsetOf(PlayerSnapshot, "gamemode"));
    return mix(h, @offsetOf(PlayerSnapshot, "spawned"));
}

fn fpEntitySnapshot(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntitySnapshot));
    h = mix(h, @offsetOf(EntitySnapshot, "header"));
    h = mix(h, @offsetOf(EntitySnapshot, "handle"));
    h = mix(h, @offsetOf(EntitySnapshot, "runtime_id"));
    h = mix(h, @offsetOf(EntitySnapshot, "type"));
    h = mix(h, @offsetOf(EntitySnapshot, "world"));
    h = mix(h, @offsetOf(EntitySnapshot, "dimension"));
    h = mix(h, @offsetOf(EntitySnapshot, "x"));
    h = mix(h, @offsetOf(EntitySnapshot, "y"));
    return mix(h, @offsetOf(EntitySnapshot, "z"));
}

fn fpItemSnapshot(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(ItemSnapshot));
    h = mix(h, @offsetOf(ItemSnapshot, "header"));
    h = mix(h, @offsetOf(ItemSnapshot, "handle"));
    h = mix(h, @offsetOf(ItemSnapshot, "network_id"));
    h = mix(h, @offsetOf(ItemSnapshot, "max_stack_size"));
    h = mix(h, @offsetOf(ItemSnapshot, "stackable"));
    h = mix(h, @offsetOf(ItemSnapshot, "reserved"));
    return mix(h, @offsetOf(ItemSnapshot, "identifier"));
}

fn fpBlockSnapshot(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlockSnapshot));
    h = mix(h, @offsetOf(BlockSnapshot, "header"));
    h = mix(h, @offsetOf(BlockSnapshot, "world"));
    h = mix(h, @offsetOf(BlockSnapshot, "dimension"));
    h = mix(h, @offsetOf(BlockSnapshot, "x"));
    h = mix(h, @offsetOf(BlockSnapshot, "y"));
    h = mix(h, @offsetOf(BlockSnapshot, "z"));
    h = mix(h, @offsetOf(BlockSnapshot, "network_id"));
    return mix(h, @offsetOf(BlockSnapshot, "identifier"));
}

fn fpInventoryItemSnapshot(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(InventoryItemSnapshot));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "header"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "present"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "reserved"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "count"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "reserved_count"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "network_id"));
    h = mix(h, @offsetOf(InventoryItemSnapshot, "metadata"));
    return mix(h, @offsetOf(InventoryItemSnapshot, "identifier"));
}

fn fpWorldApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(WorldApi));
    h = mix(h, @offsetOf(WorldApi, "header"));
    h = mix(h, @offsetOf(WorldApi, "find"));
    h = mix(h, @offsetOf(WorldApi, "get_snapshot"));
    h = mix(h, @offsetOf(WorldApi, "set_block"));
    h = mix(h, @offsetOf(WorldApi, "get_block_state"));
    h = mix(h, @offsetOf(WorldApi, "set_block_state"));
    return mix(h, @offsetOf(WorldApi, "for_each_in_box"));
}

fn fpPlayersApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(PlayersApi));
    h = mix(h, @offsetOf(PlayersApi, "header"));
    h = mix(h, @offsetOf(PlayersApi, "count"));
    h = mix(h, @offsetOf(PlayersApi, "get_snapshot"));
    h = mix(h, @offsetOf(PlayersApi, "get_by_index"));
    h = mix(h, @offsetOf(PlayersApi, "get_by_runtime"));
    return mix(h, @offsetOf(PlayersApi, "for_each"));
}

fn fpEntitiesApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntitiesApi));
    h = mix(h, @offsetOf(EntitiesApi, "header"));
    h = mix(h, @offsetOf(EntitiesApi, "count"));
    h = mix(h, @offsetOf(EntitiesApi, "get_snapshot"));
    h = mix(h, @offsetOf(EntitiesApi, "get_by_index"));
    h = mix(h, @offsetOf(EntitiesApi, "get_by_runtime"));
    return mix(h, @offsetOf(EntitiesApi, "for_each"));
}

fn fpItemsApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(ItemsApi));
    h = mix(h, @offsetOf(ItemsApi, "header"));
    h = mix(h, @offsetOf(ItemsApi, "count"));
    h = mix(h, @offsetOf(ItemsApi, "get_snapshot"));
    h = mix(h, @offsetOf(ItemsApi, "get_by_index"));
    h = mix(h, @offsetOf(ItemsApi, "get_by_network_id"));
    return mix(h, @offsetOf(ItemsApi, "for_each"));
}

fn fpBlocksApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlocksApi));
    h = mix(h, @offsetOf(BlocksApi, "header"));
    h = mix(h, @offsetOf(BlocksApi, "get_snapshot"));
    return mix(h, @offsetOf(BlocksApi, "resolve_name"));
}

fn fpInventoriesApi(hash: u64) u64 {
    return mix(mix(mix(mix(hash, @sizeOf(InventoriesApi)), @offsetOf(InventoriesApi, "header")), @offsetOf(InventoriesApi, "get_size")), @offsetOf(InventoriesApi, "get_item"));
}

fn fpCoreApi(hash: u64) u64 {
    return mix(mix(mix(mix(hash, @sizeOf(CoreApi)), @offsetOf(CoreApi, "header")), @offsetOf(CoreApi, "get_tick")), @offsetOf(CoreApi, "get_state"));
}

fn fpSchedulerApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(SchedulerApi));
    h = mix(h, @offsetOf(SchedulerApi, "header"));
    h = mix(h, @offsetOf(SchedulerApi, "after"));
    h = mix(h, @offsetOf(SchedulerApi, "every"));
    h = mix(h, @offsetOf(SchedulerApi, "cancel"));
    return mix(h, @offsetOf(SchedulerApi, "cancel_owner"));
}

fn fpLoggingApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(LoggingApi));
    h = mix(h, @offsetOf(LoggingApi, "header"));
    h = mix(h, @offsetOf(LoggingApi, "log"));
    h = mix(h, @offsetOf(LoggingApi, "is_enabled"));
    h = mix(h, @offsetOf(LoggingApi, "set_level"));
    return mix(h, @offsetOf(LoggingApi, "set_scope"));
}

fn fpEventsApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EventsApi));
    h = mix(h, @offsetOf(EventsApi, "header"));
    h = mix(h, @offsetOf(EventsApi, "subscribe"));
    h = mix(h, @offsetOf(EventsApi, "unsubscribe"));
    h = mix(h, @offsetOf(EventsApi, "emit"));
    h = mix(h, @offsetOf(EventsApi, "emit_immediate"));
    return mix(h, @offsetOf(EventsApi, "schema_of"));
}

fn fpRegistryView(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(RegistryView));
    h = mix(h, @offsetOf(RegistryView, "data"));
    h = mix(h, @offsetOf(RegistryView, "count"));
    h = mix(h, @offsetOf(RegistryView, "stride"));
    h = mix(h, @offsetOf(RegistryView, "element_version"));
    return mix(h, @offsetOf(RegistryView, "reserved"));
}

fn fpBlockStateEntry(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlockStateEntry));
    h = mix(h, @offsetOf(BlockStateEntry, "network_id"));
    h = mix(h, @offsetOf(BlockStateEntry, "reserved"));
    return mix(h, @offsetOf(BlockStateEntry, "identifier"));
}

fn fpItemEntry(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(ItemEntry));
    h = mix(h, @offsetOf(ItemEntry, "network_id"));
    h = mix(h, @offsetOf(ItemEntry, "max_stack_size"));
    h = mix(h, @offsetOf(ItemEntry, "stackable"));
    h = mix(h, @offsetOf(ItemEntry, "reserved"));
    return mix(h, @offsetOf(ItemEntry, "identifier"));
}

fn fpEntityTypeEntry(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(EntityTypeEntry));
    h = mix(h, @offsetOf(EntityTypeEntry, "network_id"));
    h = mix(h, @offsetOf(EntityTypeEntry, "reserved"));
    return mix(h, @offsetOf(EntityTypeEntry, "identifier"));
}

fn fpRegistriesApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(RegistriesApi));
    h = mix(h, @offsetOf(RegistriesApi, "header"));
    h = mix(h, @offsetOf(RegistriesApi, "block_states"));
    h = mix(h, @offsetOf(RegistriesApi, "items"));
    return mix(h, @offsetOf(RegistriesApi, "entity_types"));
}

fn fpCommandDesc(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(CommandDesc));
    h = mix(h, @offsetOf(CommandDesc, "struct_size"));
    h = mix(h, @offsetOf(CommandDesc, "flags"));
    h = mix(h, @offsetOf(CommandDesc, "name"));
    h = mix(h, @offsetOf(CommandDesc, "description"));
    h = mix(h, @offsetOf(CommandDesc, "permission"));
    h = mix(h, @offsetOf(CommandDesc, "aliases"));
    h = mix(h, @offsetOf(CommandDesc, "alias_count"));
    h = mix(h, @offsetOf(CommandDesc, "reserved"));
    h = mix(h, @offsetOf(CommandDesc, "handler"));
    return mix(h, @offsetOf(CommandDesc, "userdata"));
}

fn fpCommandCall(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(CommandCall));
    h = mix(h, @offsetOf(CommandCall, "struct_size"));
    h = mix(h, @offsetOf(CommandCall, "argc"));
    h = mix(h, @offsetOf(CommandCall, "argv"));
    h = mix(h, @offsetOf(CommandCall, "raw_line"));
    h = mix(h, @offsetOf(CommandCall, "player"));
    h = mix(h, @offsetOf(CommandCall, "world"));
    return mix(h, @offsetOf(CommandCall, "userdata"));
}

fn fpBlockBox(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(BlockBox));
    h = mix(h, @offsetOf(BlockBox, "min_x"));
    h = mix(h, @offsetOf(BlockBox, "min_y"));
    h = mix(h, @offsetOf(BlockBox, "min_z"));
    h = mix(h, @offsetOf(BlockBox, "max_x"));
    h = mix(h, @offsetOf(BlockBox, "max_y"));
    return mix(h, @offsetOf(BlockBox, "max_z"));
}

fn fpCommandsApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(CommandsApi));
    h = mix(h, @offsetOf(CommandsApi, "header"));
    h = mix(h, @offsetOf(CommandsApi, "register_command"));
    h = mix(h, @offsetOf(CommandsApi, "unregister"));
    return mix(h, @offsetOf(CommandsApi, "mark_dirty"));
}

fn fpNetworkApi(hash: u64) u64 {
    return mix(mix(mix(mix(hash, @sizeOf(NetworkApi)), @offsetOf(NetworkApi, "header")), @offsetOf(NetworkApi, "send")), @offsetOf(NetworkApi, "broadcast"));
}

fn fpHostApi(hash: u64) u64 {
    var h = hash;
    h = mix(h, @sizeOf(HostApi));
    h = mix(h, @offsetOf(HostApi, "struct_size"));
    h = mix(h, @offsetOf(HostApi, "abi_major"));
    h = mix(h, @offsetOf(HostApi, "abi_minor"));
    h = mix(h, @offsetOf(HostApi, "plugin_id"));
    h = mix(h, @offsetOf(HostApi, "userdata"));
    h = mix(h, @offsetOf(HostApi, "allocator"));
    h = mix(h, @offsetOf(HostApi, "log"));
    h = mix(h, @offsetOf(HostApi, "event_subscribe"));
    h = mix(h, @offsetOf(HostApi, "event_unsubscribe"));
    h = mix(h, @offsetOf(HostApi, "emit_custom"));
    h = mix(h, @offsetOf(HostApi, "get_interface"));
    h = mix(h, @offsetOf(HostApi, "every"));
    return mix(h, @offsetOf(HostApi, "features"));
}

fn fpConstants() u64 {
    var h: u64 = 0;
    h ^= mix(abi_fp_seed ^ 1001, abi_major);
    h ^= mix(abi_fp_seed ^ 1002, abi_minor);
    h ^= mix(abi_fp_seed ^ 1003, descriptor_version);
    h ^= mix(abi_fp_seed ^ 1004, plugin_status_ok);
    h ^= mix(abi_fp_seed ^ 1005, plugin_status_abi_major);
    h ^= mix(abi_fp_seed ^ 1006, plugin_status_abi_minor);
    h ^= mix(abi_fp_seed ^ 1007, plugin_status_host_too_old);
    h ^= mix(abi_fp_seed ^ 1008, plugin_status_build_target);
    h ^= mix(abi_fp_seed ^ 1009, log_trace);
    h ^= mix(abi_fp_seed ^ 1010, log_debug);
    h ^= mix(abi_fp_seed ^ 1011, log_info);
    h ^= mix(abi_fp_seed ^ 1012, log_warn);
    h ^= mix(abi_fp_seed ^ 1013, log_error);
    h ^= mix(abi_fp_seed ^ 1014, shutdown_normal);
    h ^= mix(abi_fp_seed ^ 1015, shutdown_fault);
    h ^= mix(abi_fp_seed ^ 1016, shutdown_reload);
    h ^= mix(abi_fp_seed ^ 1017, shutdown_server_exit);
    h ^= mix(abi_fp_seed ^ 1018, event_phase_pre);
    h ^= mix(abi_fp_seed ^ 1019, event_phase_commit);
    h ^= mix(abi_fp_seed ^ 1020, event_phase_post);
    h ^= mix(abi_fp_seed ^ 1021, feature_events);
    h ^= mix(abi_fp_seed ^ 1022, feature_logging);
    h ^= mix(abi_fp_seed ^ 1023, feature_allocator);
    h ^= mix(abi_fp_seed ^ 1024, feature_scheduler);
    h ^= mix(abi_fp_seed ^ 1025, feature_world);
    h ^= mix(abi_fp_seed ^ 1026, feature_players);
    h ^= mix(abi_fp_seed ^ 1027, feature_entities);
    h ^= mix(abi_fp_seed ^ 1028, feature_items);
    h ^= mix(abi_fp_seed ^ 1029, feature_blocks);
    h ^= mix(abi_fp_seed ^ 1030, feature_inventories);
    h ^= mix(abi_fp_seed ^ 1031, feature_registries);
    h ^= mix(abi_fp_seed ^ 1032, feature_network);
    h ^= mix(abi_fp_seed ^ 1033, feature_commands);
    h ^= mix(abi_fp_seed ^ 1096, feature_custom_events);
    h ^= mix(abi_fp_seed ^ 1097, feature_traits);
    h ^= mix(abi_fp_seed ^ 1098, feature_hot_unload);
    h ^= mix(abi_fp_seed ^ 1099, block_flag_apply_traits);
    h ^= mix(abi_fp_seed ^ 1100, block_flag_update_clients);
    h ^= mix(abi_fp_seed ^ 1101, block_flag_silent);
    h ^= mix(abi_fp_seed ^ 1034, @backingInt(EventId.server_start));
    h ^= mix(abi_fp_seed ^ 1035, @backingInt(EventId.server_shutdown));
    h ^= mix(abi_fp_seed ^ 1036, @backingInt(EventId.server_tick));
    h ^= mix(abi_fp_seed ^ 1037, @backingInt(EventId.player_join));
    h ^= mix(abi_fp_seed ^ 1038, @backingInt(EventId.player_disconnect));
    h ^= mix(abi_fp_seed ^ 1039, @backingInt(EventId.player_chat));
    h ^= mix(abi_fp_seed ^ 1040, @backingInt(EventId.item_use));
    h ^= mix(abi_fp_seed ^ 1041, @backingInt(EventId.player_move));
    h ^= mix(abi_fp_seed ^ 1042, @backingInt(EventId.damage));
    h ^= mix(abi_fp_seed ^ 1043, @backingInt(EventId.block_place));
    h ^= mix(abi_fp_seed ^ 1044, @backingInt(EventId.block_break));
    h ^= mix(abi_fp_seed ^ 1045, @backingInt(EventId.inventory_open));
    h ^= mix(abi_fp_seed ^ 1046, @backingInt(EventId.inventory_click));
    h ^= mix(abi_fp_seed ^ 1047, @backingInt(EventId.inventory_close));
    h ^= mix(abi_fp_seed ^ 1048, @backingInt(EventId.transaction_prepare));
    h ^= mix(abi_fp_seed ^ 1049, @backingInt(EventId.transaction_commit));
    h ^= mix(abi_fp_seed ^ 1050, @backingInt(EventId.transaction_abort));
    h ^= mix(abi_fp_seed ^ 1051, event_flag_cancelable);
    h ^= mix(abi_fp_seed ^ 1052, event_flag_mutable);
    h ^= mix(abi_fp_seed ^ 1053, event_flag_callback_only);
    h ^= mix(abi_fp_seed ^ 1054, event_flag_borrowed);
    h ^= mixSigned(abi_fp_seed ^ 1055, result_ok);
    h ^= mixSigned(abi_fp_seed ^ 1056, result_invalid_argument);
    h ^= mixSigned(abi_fp_seed ^ 1057, result_unsupported);
    h ^= mixSigned(abi_fp_seed ^ 1058, result_not_found);
    h ^= mixSigned(abi_fp_seed ^ 1059, result_wrong_thread);
    h ^= mixSigned(abi_fp_seed ^ 1060, result_invalid_handle);
    h ^= mixSigned(abi_fp_seed ^ 1061, result_busy);
    h ^= mixSigned(abi_fp_seed ^ 1062, result_conflict);
    h ^= mixSigned(abi_fp_seed ^ 1063, result_out_of_memory);
    h ^= mixSigned(abi_fp_seed ^ 1064, result_version);
    h ^= mixSigned(abi_fp_seed ^ 1065, result_unloaded);
    h ^= mixSigned(abi_fp_seed ^ 1066, result_denied);
    h ^= mixSigned(abi_fp_seed ^ 1067, result_limit);
    h ^= mix(abi_fp_seed ^ 1102, load_ok);
    h ^= mix(abi_fp_seed ^ 1103, load_dlopen);
    h ^= mix(abi_fp_seed ^ 1104, load_symbol_missing);
    h ^= mix(abi_fp_seed ^ 1105, load_legacy_abi);
    h ^= mix(abi_fp_seed ^ 1106, load_abi_major);
    h ^= mix(abi_fp_seed ^ 1107, load_abi_minor);
    h ^= mix(abi_fp_seed ^ 1108, load_fingerprint);
    h ^= mix(abi_fp_seed ^ 1109, load_descriptor);
    h ^= mix(abi_fp_seed ^ 1110, load_metadata);
    h ^= mix(abi_fp_seed ^ 1111, load_duplicate_name);
    h ^= mix(abi_fp_seed ^ 1112, load_required_feature);
    h ^= mix(abi_fp_seed ^ 1113, load_missing_callback);
    h ^= mix(abi_fp_seed ^ 1114, load_callback_failed);
    h ^= mix(abi_fp_seed ^ 1115, load_out_of_memory);
    h ^= mix(abi_fp_seed ^ 1068, packet_priority_normal);
    h ^= mix(abi_fp_seed ^ 1069, packet_priority_immediate);
    h ^= mix(abi_fp_seed ^ 1070, event_custom_base);
    h ^= mix(abi_fp_seed ^ 1071, interface_core);
    h ^= mix(abi_fp_seed ^ 1072, interface_logging);
    h ^= mix(abi_fp_seed ^ 1073, interface_events);
    h ^= mix(abi_fp_seed ^ 1074, interface_scheduler);
    h ^= mix(abi_fp_seed ^ 1075, interface_world);
    h ^= mix(abi_fp_seed ^ 1076, interface_players);
    h ^= mix(abi_fp_seed ^ 1077, interface_entities);
    h ^= mix(abi_fp_seed ^ 1078, interface_items);
    h ^= mix(abi_fp_seed ^ 1079, interface_blocks);
    h ^= mix(abi_fp_seed ^ 1080, interface_inventories);
    h ^= mix(abi_fp_seed ^ 1081, interface_registries);
    h ^= mix(abi_fp_seed ^ 1082, interface_network);
    h ^= mix(abi_fp_seed ^ 1083, interface_commands);
    h ^= mix(abi_fp_seed ^ 1086, custom_payload_max);
    h ^= mix(abi_fp_seed ^ 1087, max_custom_events);
    h ^= mix(abi_fp_seed ^ 1088, @backingInt(EventId.entity_combust));
    h ^= mix(abi_fp_seed ^ 1089, @backingInt(EventId.enchantment_apply));
    h ^= mix(abi_fp_seed ^ 1090, @backingInt(EventId.enchantment_remove));
    h ^= mix(abi_fp_seed ^ 1091, @backingInt(EventId.entity_spawn));
    h ^= mix(abi_fp_seed ^ 1092, @backingInt(EventId.entity_despawn));
    h ^= mix(abi_fp_seed ^ 1093, @backingInt(EventId.entity_damage));
    h ^= mix(abi_fp_seed ^ 1094, @backingInt(EventId.entity_death));
    h ^= mix(abi_fp_seed ^ 1095, @backingInt(EventId.entity_interact));
    return h;
}

pub const abi_fingerprint: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var h: u64 = 0;
    h ^= fpStringView(abi_fp_seed ^ 1);
    h ^= fpApiVersion(abi_fp_seed ^ 2);
    h ^= fpHostQuery(abi_fp_seed ^ 3);
    h ^= fpPluginInfo(abi_fp_seed ^ 4);
    h ^= fpMetadata(abi_fp_seed ^ 5);
    h ^= fpDescriptor(abi_fp_seed ^ 6);
    h ^= fpContext(abi_fp_seed ^ 7);
    h ^= fpAllocator(abi_fp_seed ^ 8);
    h ^= fpInterfaceHeader(abi_fp_seed ^ 9);
    h ^= fpEventView(abi_fp_seed ^ 10);
    h ^= fpServerTickEvent(abi_fp_seed ^ 28);
    h ^= fpPlayerEvent(abi_fp_seed ^ 29);
    h ^= fpPlayerJoinEvent(abi_fp_seed ^ 39);
    h ^= fpPlayerRefEvent(abi_fp_seed ^ 40);
    h ^= fpPlayerChatEvent(abi_fp_seed ^ 41);
    h ^= fpItemUseEvent(abi_fp_seed ^ 42);
    h ^= fpPlayerMoveEvent(abi_fp_seed ^ 43);
    h ^= fpDamageEvent(abi_fp_seed ^ 44);
    h ^= fpBlockPlaceEvent(abi_fp_seed ^ 45);
    h ^= fpBlockBreakEvent(abi_fp_seed ^ 46);
    h ^= fpInventoryEvent(abi_fp_seed ^ 47);
    h ^= fpInventoryClickEvent(abi_fp_seed ^ 48);
    h ^= fpTransactionEvent(abi_fp_seed ^ 49);
    h ^= fpEntityCombustEvent(abi_fp_seed ^ 50);
    h ^= fpEnchantEvent(abi_fp_seed ^ 51);
    h ^= fpEntitySpawnEvent(abi_fp_seed ^ 52);
    h ^= fpEntityDespawnEvent(abi_fp_seed ^ 53);
    h ^= fpEntityDamageEvent(abi_fp_seed ^ 54);
    h ^= fpEntityDeathEvent(abi_fp_seed ^ 55);
    h ^= fpEntityInteractEvent(abi_fp_seed ^ 56);
    h ^= fpSnapshotHeader(abi_fp_seed ^ 11);
    h ^= fpWorldSnapshot(abi_fp_seed ^ 12);
    h ^= fpPlayerSnapshot(abi_fp_seed ^ 13);
    h ^= fpEntitySnapshot(abi_fp_seed ^ 14);
    h ^= fpItemSnapshot(abi_fp_seed ^ 15);
    h ^= fpBlockSnapshot(abi_fp_seed ^ 16);
    h ^= fpInventoryItemSnapshot(abi_fp_seed ^ 17);
    h ^= fpWorldApi(abi_fp_seed ^ 18);
    h ^= fpPlayersApi(abi_fp_seed ^ 19);
    h ^= fpEntitiesApi(abi_fp_seed ^ 20);
    h ^= fpItemsApi(abi_fp_seed ^ 21);
    h ^= fpBlocksApi(abi_fp_seed ^ 22);
    h ^= fpInventoriesApi(abi_fp_seed ^ 23);
    h ^= fpCoreApi(abi_fp_seed ^ 24);
    h ^= fpSchedulerApi(abi_fp_seed ^ 25);
    h ^= fpNetworkApi(abi_fp_seed ^ 26);
    h ^= fpHostApi(abi_fp_seed ^ 27);
    h ^= fpLoggingApi(abi_fp_seed ^ 30);
    h ^= fpEventsApi(abi_fp_seed ^ 31);
    h ^= fpRegistryView(abi_fp_seed ^ 32);
    h ^= fpBlockStateEntry(abi_fp_seed ^ 33);
    h ^= fpItemEntry(abi_fp_seed ^ 34);
    h ^= fpEntityTypeEntry(abi_fp_seed ^ 35);
    h ^= fpRegistriesApi(abi_fp_seed ^ 36);
    h ^= fpCommandDesc(abi_fp_seed ^ 37);
    h ^= fpCommandsApi(abi_fp_seed ^ 38);
    h ^= fpCommandCall(abi_fp_seed ^ 57);
    h ^= fpBlockBox(abi_fp_seed ^ 58);
    h ^= fpConstants();
    break :blk h;
};

pub fn hostQuery(features: u64) HostQuery {
    return .{
        .struct_size = @sizeOf(HostQuery),
        .abi_major = abi_major,
        .abi_minor = abi_minor,
        .reserved = 0,
        .abi_fingerprint = abi_fingerprint,
        .host_features = features,
        .tick_rate = 20,
        .reserved2 = 0,
    };
}

pub fn validateQuery(query: *const HostQuery, info: *PluginInfo) Error!void {
    if (query.struct_size < @sizeOf(HostQuery)) return error.InvalidArgument;
    if (info.struct_size < @sizeOf(PluginInfo)) return error.InvalidArgument;
    if (query.abi_major != abi_major) return error.AbiMajor;
    if (info.status != plugin_status_ok) return switch (info.status) {
        plugin_status_abi_major => error.AbiMajor,
        plugin_status_abi_minor => error.AbiMinor,
        plugin_status_host_too_old => error.HostTooOld,
        plugin_status_build_target => error.BuildTarget,
        else => error.InvalidArgument,
    };
    if (info.abi_major != abi_major) return error.AbiMajor;
    if (info.abi_minor > abi_minor) return error.AbiMinor;
    if (info.abi_fingerprint != abi_fingerprint) return error.Fingerprint;
    if (info.descriptor == null) return error.Descriptor;
}

pub fn validateDescriptor(descriptor: *const Descriptor, features: u64) Error!void {
    if (descriptor.struct_size < @offsetOf(Descriptor, "on_ready") + @sizeOf(OnReadyFn)) return error.Descriptor;
    if (descriptor.descriptor_version != descriptor_version) return error.Descriptor;
    if (descriptor.abi_fingerprint != abi_fingerprint) return error.Fingerprint;
    if (descriptor.metadata.struct_size < @offsetOf(Metadata, "optional_features") + @sizeOf(u64)) return error.Metadata;
    if (descriptor.metadata.plugin_flags != 0) return error.Metadata;
    const name = descriptor.metadata.name;
    if (name.length == 0 or name.data == null or name.length > 63) return error.Metadata;
    const version = descriptor.metadata.version;
    if (version.length == 0 or version.data == null) return error.Metadata;
    if (descriptor.metadata.required_features & ~features != 0) return error.RequiredFeature;
    if (descriptor.on_load == null or descriptor.on_start == null or descriptor.on_shutdown == null or descriptor.on_unload == null) return error.MissingCallback;
}

pub fn metadataName(descriptor: *const Descriptor) []const u8 {
    return descriptor.metadata.name.slice();
}

test "host api fits the cache budget" {
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(HostApi));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Allocator));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(HostQuery));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(PluginInfo));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(LoggingApi));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(EventsApi));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(SchedulerApi));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RegistryView));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(RegistriesApi));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(PlayerSnapshot));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(WorldApi));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(PlayersApi));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(EntitiesApi));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ItemsApi));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BlocksApi));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(CommandDesc));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(CommandCall));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BlockBox));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(CommandsApi));
}

test "query and descriptor validation enforce fingerprint and callbacks" {
    const name = "test";
    const version = "2.0.0";
    var descriptor = Descriptor{
        .struct_size = @sizeOf(Descriptor),
        .descriptor_version = descriptor_version,
        .abi_fingerprint = abi_fingerprint,
        .metadata = .{
            .struct_size = @sizeOf(Metadata),
            .plugin_flags = 0,
            .name = .{ .data = name.ptr, .length = name.len },
            .version = .{ .data = version.ptr, .length = version.len },
            .description = .{},
            .api = .{ .major = abi_major, .minor = abi_minor, .patch = 0, .reserved = 0 },
            .required_features = feature_events,
            .optional_features = 0,
        },
        .on_load = struct {
            fn f(_: *Context) callconv(.c) i32 {
                return 0;
            }
        }.f,
        .on_start = struct {
            fn f(_: *Context) callconv(.c) i32 {
                return 0;
            }
        }.f,
        .on_shutdown = struct {
            fn f(_: *Context, _: u32) callconv(.c) void {}
        }.f,
        .on_unload = struct {
            fn f(_: *Context) callconv(.c) void {}
        }.f,
        .on_ready = null,
    };
    try validateDescriptor(&descriptor, host_features);

    var info = PluginInfo{
        .struct_size = @sizeOf(PluginInfo),
        .status = plugin_status_ok,
        .abi_major = abi_major,
        .abi_minor = abi_minor,
        .abi_fingerprint = abi_fingerprint,
        .descriptor = &descriptor,
        .diagnostic = .{},
        .reserved = 0,
    };
    const query = hostQuery(host_features);
    try validateQuery(&query, &info);

    info.abi_major = abi_major + 1;
    try std.testing.expectError(error.AbiMajor, validateQuery(&query, &info));
    info.abi_major = abi_major;

    info.abi_minor = abi_minor + 1;
    try std.testing.expectError(error.AbiMinor, validateQuery(&query, &info));
    info.abi_minor = abi_minor;

    info.status = plugin_status_abi_minor;
    info.abi_major = 0;
    try std.testing.expectError(error.AbiMinor, validateQuery(&query, &info));
    info.status = plugin_status_ok;
    info.abi_major = abi_major;

    info.abi_fingerprint ^= 1;
    try std.testing.expectError(error.Fingerprint, validateQuery(&query, &info));
    info.abi_fingerprint = abi_fingerprint;

    descriptor.metadata.required_features = 1 << 63;
    try std.testing.expectError(error.RequiredFeature, validateDescriptor(&descriptor, host_features));
    descriptor.metadata.required_features = 0;
    descriptor.metadata.optional_features = 1 << 63;
    try validateDescriptor(&descriptor, host_features);
    descriptor.metadata.optional_features = 0;

    descriptor.on_start = null;
    try std.testing.expectError(error.MissingCallback, validateDescriptor(&descriptor, host_features));
}
