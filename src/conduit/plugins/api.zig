const std = @import("std");
const Events = @import("../events/root.zig");
const Protocol = @import("protocol");

pub const api_major: u16 = 1;
pub const api_minor: u16 = 0;

pub const ApiVersion = struct {
    major: u16 = api_major,
    minor: u16 = api_minor,
    protocol: u32,
};

pub const Capability = enum {
    read_player,
    message_player,
    teleport,
    world_read,
    world_write,
    inventory_write,
    economy_write,
    register_command,
};

pub const HandleKind = enum(u8) { invalid, player, entity, world, dimension, instance, menu, task };
pub const Handle = packed struct(u64) {
    index: u32,
    generation: u16,
    kind: HandleKind,
    reserved: u8 = 0,
};

pub const PluginId = u32;
pub const TaskHandle = Handle;

pub const PluginState = enum { discovered, validated, initialized, started, stopping, stopped, failed, disabled };
pub const StopReason = enum { shutdown, fault, dependency_failed };

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    api: ApiVersion,
    capabilities: []const Capability = &.{},
    dependencies: []const []const u8 = &.{},
};

pub const ApiError = error{
    InvalidHandle,
    WrongWorld,
    PermissionDenied,
    Busy,
    OutOfMemory,
    Unsupported,
};

pub const PlayerSnapshot = struct {
    handle: Handle,
    runtime_id: i64,
    username: []const u8,
    world: []const u8,
    dimension: []const u8,
};

pub const StringView = struct { ptr: [*]const u8, len: usize };
pub const TextView = StringView;

pub const LogLevel = enum { debug, info, warn, err };

pub const PluginAllocator = struct {
    userdata: *anyopaque,
    allocFn: *const fn (*anyopaque, usize, u8) ?[*]u8,
    freeFn: *const fn (*anyopaque, [*]u8, usize, u8) void,

    pub fn alloc(self: PluginAllocator, len: usize, alignment: u8) ?[*]u8 {
        return self.allocFn(self.userdata, len, alignment);
    }

    pub fn free(self: PluginAllocator, ptr: [*]u8, len: usize, alignment: u8) void {
        self.freeFn(self.userdata, ptr, len, alignment);
    }
};

pub const HostApi = struct {
    api: ApiVersion,
    userdata: *anyopaque,
    allocator: PluginAllocator,
    core_allocator: std.mem.Allocator,
    io: std.Io,
    max_players: usize,
    worldSetBlockFn: *const fn (*anyopaque, StringView, StringView, Protocol.BlockPosition, StringView) ApiError!void,
    events: ?*Events.Events = null,
    logFn: *const fn (*anyopaque, LogLevel, StringView) void,
    playerSnapshotFn: *const fn (*anyopaque, Handle, *PlayerSnapshot) ApiError!void,
    worldFindFn: *const fn (*anyopaque, StringView) ?Handle,
    scheduleFn: *const fn (*anyopaque, u32, Events.Event, *anyopaque) ApiError!TaskHandle,

    pub fn log(self: *const HostApi, level: LogLevel, message: []const u8) void {
        self.logFn(self.userdata, level, .{ .ptr = message.ptr, .len = message.len });
    }
};

pub const PluginContext = struct {
    host: *const HostApi,
    plugin_id: PluginId,
    allocator: PluginAllocator,
};

pub const PluginDescriptor = struct {
    manifest: *const fn () PluginManifest,
    init: *const fn (*PluginContext) anyerror!void,
    start: *const fn () anyerror!void,
    stop: *const fn (StopReason) void,
};
