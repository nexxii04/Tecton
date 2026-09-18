const std = @import("std");

pub const abi_major: u32 = 1;
pub const abi_minor: u32 = 0;
pub const descriptor_version: u32 = 1;
pub const feature_events: u64 = 1 << 0;
pub const feature_world: u64 = 1 << 1;
pub const feature_logging: u64 = 1 << 2;
pub const feature_allocator: u64 = 1 << 3;

pub const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,

    pub fn slice(self: StringView) []const u8 {
        const ptr = self.data orelse return "";
        return ptr[0..self.length];
    }
};

pub const ApiVersion = extern struct {
    major: u16,
    minor: u16,
    protocol: u32,
};

pub const Metadata = extern struct {
    struct_size: u32,
    name: StringView,
    version: StringView,
    description: StringView,
    api: ApiVersion,
    capabilities: u64,
};

pub const EventId = enum(u32) {
    server_start,
    server_shutdown,
    server_tick,
    player_join,
    player_disconnect,
    player_chat,
    item_use,
    player_move,
    damage,
    block_place,
    block_break,
    inventory_open,
    inventory_click,
    inventory_close,
    transaction_prepare,
    transaction_commit,
    transaction_abort,
};

pub const EventPhase = enum(u32) { pre, commit, post };
pub const EventResult = enum(u32) { continue_, cancel };

pub const EventView = extern struct {
    event_id: u32,
    phase: u32,
    data: ?*const anyopaque,
    data_size: usize,
    result: *u32,
    payload_version: u32,
};

pub const ServerTickEvent = extern struct { tick: u64 };
pub const PlayerEvent = extern struct { handle: u64 };
pub const EventCallbackFn = *const fn (?*anyopaque, *const EventView) callconv(.c) void;
pub const EventSubscribeFn = *const fn (?*anyopaque, u32, u32, i16, EventCallbackFn, ?*anyopaque, *u64) callconv(.c) i32;
pub const EventUnsubscribeFn = *const fn (?*anyopaque, u64) callconv(.c) i32;

pub const AllocFn = *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const FreeFn = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) void;
pub const LogFn = *const fn (?*anyopaque, u32, StringView) callconv(.c) void;
pub const PluginLogFn = *const fn (?*anyopaque, u32, StringView) callconv(.c) void;
pub const WorldFindFn = *const fn (?*anyopaque, StringView, *u64) callconv(.c) i32;
pub const PlayerSnapshotFn = *const fn (?*anyopaque, u64, ?*anyopaque, usize) callconv(.c) i32;
pub const WorldSetBlockFn = *const fn (?*anyopaque, u64, StringView, i32, i32, i32, StringView) callconv(.c) i32;

pub const Allocator = extern struct {
    userdata: ?*anyopaque,
    alloc: AllocFn,
    free: FreeFn,
};

pub const HostApi = extern struct {
    struct_size: u32,
    api: ApiVersion,
    userdata: ?*anyopaque,
    allocator: Allocator,
    log: LogFn,
    world_find: WorldFindFn,
    player_snapshot: PlayerSnapshotFn,
    world_set_block: WorldSetBlockFn,
    event_subscribe: EventSubscribeFn,
    event_unsubscribe: EventUnsubscribeFn,
    features: u64,
    log_debug: PluginLogFn,
    log_info: PluginLogFn,
    log_warn: PluginLogFn,
    log_error: PluginLogFn,
};

pub const Context = extern struct {
    struct_size: u32,
    plugin_id: u32,
    host: *const HostApi,
};

pub const OnLoadFn = *const fn (*Context) callconv(.c) i32;
pub const OnStartFn = *const fn (*Context) callconv(.c) i32;
pub const OnShutdownFn = *const fn (*Context, u32) callconv(.c) void;
pub const OnUnloadFn = *const fn (*Context) callconv(.c) void;

pub const Descriptor = extern struct {
    struct_size: u32,
    descriptor_version: u32,
    metadata: Metadata,
    on_load: ?OnLoadFn,
    on_start: ?OnStartFn,
    on_shutdown: ?OnShutdownFn,
    on_unload: ?OnUnloadFn,
};

pub const GetDescriptorFn = *const fn (u32, u32) callconv(.c) ?*const Descriptor;

pub const ShutdownReason = enum(u32) {
    shutdown = 0,
    fault = 1,
    dependency_failed = 2,
};

pub const Error = error{
    InvalidDescriptor,
    InvalidMetadata,
    IncompatibleAbi,
    IncompatibleApi,
    MissingCallback,
    CallbackFailed,
};

pub fn validateDescriptor(descriptor: *const Descriptor, protocol: u32) Error!void {
    if (descriptor.struct_size < @sizeOf(Descriptor)) return error.InvalidDescriptor;
    if (descriptor.descriptor_version != descriptor_version) return error.InvalidDescriptor;
    if (descriptor.metadata.struct_size < @sizeOf(Metadata)) return error.InvalidMetadata;
    if (descriptor.metadata.name.length == 0 or descriptor.metadata.name.data == null) return error.InvalidMetadata;
    if (descriptor.metadata.version.length == 0 or descriptor.metadata.version.data == null) return error.InvalidMetadata;
    if (descriptor.metadata.api.major != abi_major or descriptor.metadata.api.minor > abi_minor) return error.IncompatibleApi;
    if (descriptor.metadata.api.protocol != protocol) return error.IncompatibleApi;
    if (descriptor.on_load == null or descriptor.on_start == null or descriptor.on_shutdown == null or descriptor.on_unload == null) return error.MissingCallback;
}

pub fn metadataName(descriptor: *const Descriptor) []const u8 {
    return descriptor.metadata.name.slice();
}

test "native descriptor validation accepts the current ABI" {
    const name = "test";
    const version = "1.0.0";
    const descriptor = Descriptor{
        .struct_size = @sizeOf(Descriptor),
        .descriptor_version = descriptor_version,
        .metadata = .{
            .struct_size = @sizeOf(Metadata),
            .name = .{ .data = name.ptr, .length = name.len },
            .version = .{ .data = version.ptr, .length = version.len },
            .description = .{},
            .api = .{ .major = abi_major, .minor = abi_minor, .protocol = 0 },
            .capabilities = 0,
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
    };
    try validateDescriptor(&descriptor, 0);
}
