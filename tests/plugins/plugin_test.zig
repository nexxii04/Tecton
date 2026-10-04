const std = @import("std");
const loader = @import("tecton-plugin-loader");
const abi = loader.abi;
const options = @import("plugin-options");

fn allocate(_: ?*anyopaque, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

fn release(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize) callconv(.c) void {}
fn log(_: ?*anyopaque, _: u32, _: abi.StringView) callconv(.c) void {}
fn pluginLog(_: ?*anyopaque, _: u32, _: abi.StringView) callconv(.c) void {}
fn getInterface(_: ?*anyopaque, _: u32, _: u16, _: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
    if (interface) |value| value.* = null;
    return abi.result_unsupported;
}
fn worldFind(_: ?*anyopaque, _: abi.StringView, _: *u64) callconv(.c) i32 {
    return -1;
}
fn playerSnapshot(_: ?*anyopaque, _: u64, _: ?*anyopaque, _: usize) callconv(.c) i32 {
    return -1;
}
fn worldSetBlock(_: ?*anyopaque, _: u64, _: abi.StringView, _: i32, _: i32, _: i32, _: abi.StringView) callconv(.c) i32 {
    return -1;
}
var eventCallback: ?abi.EventCallbackFn = null;
var eventUserdata: ?*anyopaque = null;
var eventSubscription: u64 = 0;

fn eventSubscribe(_: ?*anyopaque, event_id: u32, phase: u32, _: i16, callback: ?abi.EventCallbackFn, userdata: ?*anyopaque, subscription: ?*u64) callconv(.c) i32 {
    if (event_id != @intFromEnum(abi.EventId.server_tick) or phase != @intFromEnum(abi.EventPhase.pre)) return -1;
    eventCallback = callback;
    eventUserdata = userdata;
    eventSubscription = 42;
    subscription.?.* = eventSubscription;
    return 0;
}

fn eventUnsubscribe(_: ?*anyopaque, subscription: u64) callconv(.c) i32 {
    if (subscription != eventSubscription) return -1;
    eventCallback = null;
    eventUserdata = null;
    return 0;
}

test "example native plugin completes lifecycle" {
    const path = options.path;
    var host = abi.HostApi{
        .struct_size = @sizeOf(abi.HostApi),
        .api = .{ .major = abi.abi_major, .minor = 0, .protocol = 2169 },
        .userdata = null,
        .allocator = .{ .userdata = null, .alloc = allocate, .free = release },
        .log = log,
        .world_find = worldFind,
        .player_snapshot = playerSnapshot,
        .world_set_block = worldSetBlock,
        .event_subscribe = eventSubscribe,
        .event_unsubscribe = eventUnsubscribe,
        .features = abi.feature_events | abi.feature_world | abi.feature_logging | abi.feature_allocator,
        .log_debug = pluginLog,
        .log_info = pluginLog,
        .log_warn = pluginLog,
        .log_error = pluginLog,
        .get_interface = getInterface,
    };
    var plugin = try loader.NativePlugin.open(std.testing.allocator, path, &host, 1, 2169);
    defer plugin.deinit();
    try plugin.start();
    try std.testing.expect(eventCallback != null);
    var tick = abi.ServerTickEvent{ .tick = 1 };
    var result: u32 = @intFromEnum(abi.EventResult.continue_);
    const event = abi.EventView{ .event_id = @intFromEnum(abi.EventId.server_tick), .phase = @intFromEnum(abi.EventPhase.pre), .data = @ptrCast(&tick), .data_size = @sizeOf(abi.ServerTickEvent), .result = &result, .payload_version = 1, .struct_size = @sizeOf(abi.EventView), .flags = abi.event_flag_cancelable | abi.event_flag_callback_only, .payload_schema = 0x10001 };
    eventCallback.?(eventUserdata, &event);
    try std.testing.expect(plugin.loaded);
    try std.testing.expect(plugin.started);
    plugin.shutdown(.shutdown);
    try std.testing.expect(!plugin.loaded);
    try std.testing.expect(!plugin.started);
}
