const std = @import("std");
const loader = @import("tecton-plugin-loader");
const abi = loader.abi;
const options = @import("plugin-options");

fn allocate(_: ?*anyopaque, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

fn release(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize) callconv(.c) void {}
fn log(_: ?*anyopaque, _: u32, _: abi.StringView) callconv(.c) void {}
fn emitCustom(_: ?*anyopaque, _: u32, _: ?*const anyopaque, _: usize, _: u32) callconv(.c) i32 {
    return abi.result_unsupported;
}
fn every(_: ?*anyopaque, _: u32, _: ?abi.TimerCallbackFn, _: ?*anyopaque, _: ?*u64) callconv(.c) i32 {
    return abi.result_unsupported;
}
fn getInterface(_: ?*anyopaque, _: u32, _: u16, _: u16, interface: ?*?abi.InterfacePtr) callconv(.c) i32 {
    if (interface) |value| value.* = null;
    return abi.result_unsupported;
}

var eventCallback: ?abi.EventCallbackFn = null;
var eventUserdata: ?*anyopaque = null;
var eventSubscription: u64 = 0;

fn eventSubscribe(_: ?*anyopaque, event_id: u32, phase: u16, _: i16, callback: ?abi.EventCallbackFn, userdata: ?*anyopaque, subscription: ?*u64) callconv(.c) i32 {
    if (event_id != @intFromEnum(abi.EventId.server_tick) or phase != abi.event_phase_pre) return abi.result_invalid_argument;
    eventCallback = callback;
    eventUserdata = userdata;
    eventSubscription = 42;
    subscription.?.* = eventSubscription;
    return abi.result_ok;
}

fn eventUnsubscribe(_: ?*anyopaque, subscription: u64) callconv(.c) i32 {
    if (subscription != eventSubscription) return abi.result_not_found;
    eventCallback = null;
    eventUserdata = null;
    return abi.result_ok;
}

fn hostApi() abi.HostApi {
    return .{
        .struct_size = @sizeOf(abi.HostApi),
        .abi_major = abi.abi_major,
        .abi_minor = abi.abi_minor,
        .plugin_id = 1,
        .userdata = null,
        .allocator = .{ .userdata = null, .alloc = allocate, .free = release, .realloc = reallocate, .alloc_zeroed = allocate },
        .log = log,
        .event_subscribe = eventSubscribe,
        .event_unsubscribe = eventUnsubscribe,
        .emit_custom = emitCustom,
        .get_interface = getInterface,
        .every = every,
        .features = abi.host_features,
    };
}

fn reallocate(_: ?*anyopaque, _: ?*anyopaque, _: usize, _: usize, _: usize) callconv(.c) ?*anyopaque {
    return null;
}

fn lifecycleMask(plugin: *loader.NativePlugin) u32 {
    const symbol = plugin.library.rawSymbol("tecton_minimal_lifecycle_mask") orelse return 0;
    const read: *const fn () callconv(.c) u32 = @ptrCast(symbol);
    return read();
}

fn failureMask(plugin: *loader.NativePlugin) u32 {
    const symbol = plugin.library.rawSymbol("tecton_failure_mask") orelse return 0;
    const read: *const fn () callconv(.c) u32 = @ptrCast(symbol);
    return read();
}

fn failureShutdownReason(plugin: *loader.NativePlugin) u32 {
    const symbol = plugin.library.rawSymbol("tecton_failure_shutdown_reason") orelse return 0;
    const read: *const fn () callconv(.c) u32 = @ptrCast(symbol);
    return read();
}

test "example native plugin completes lifecycle" {
    const path = options.path;
    var host = hostApi();
    var plugin = try loader.NativePlugin.open(std.testing.allocator, path, &host, 1);
    defer plugin.deinit();
    try plugin.load();
    try std.testing.expectEqual(@as(u32, 1), lifecycleMask(&plugin));
    try plugin.start();
    try std.testing.expectEqual(@as(u32, 3), lifecycleMask(&plugin));
    try std.testing.expect(eventCallback != null);
    plugin.ready();
    try std.testing.expectEqual(@as(u32, 7), lifecycleMask(&plugin));
    var tick = abi.ServerTickEvent{ .tick = 1 };
    var result: i32 = @intFromEnum(abi.EventResult.continue_);
    const event = abi.EventView{
        .data = @ptrCast(&tick),
        .data_size = @sizeOf(abi.ServerTickEvent),
        .result = &result,
        .schema = abi.schema_server_tick,
        .event_id = @intFromEnum(abi.EventId.server_tick),
        .phase = abi.event_phase_pre,
        .flags = abi.event_flag_callback_only | abi.event_flag_borrowed,
    };
    eventCallback.?(eventUserdata, &event);
    try std.testing.expect(plugin.loaded);
    try std.testing.expect(plugin.started);
    plugin.shutdown(.normal);
    try std.testing.expect(!plugin.started);
    try std.testing.expectEqual(@as(u32, 15), lifecycleMask(&plugin));
    plugin.unload();
    try std.testing.expect(!plugin.loaded);
    try std.testing.expectEqual(@as(u32, 31), lifecycleMask(&plugin));
}

test "failed start invokes fault shutdown and unload" {
    var host = hostApi();
    var plugin = try loader.NativePlugin.open(std.testing.allocator, options.failure_path, &host, 1);
    defer plugin.deinit();
    try plugin.load();
    try std.testing.expectEqual(@as(u32, 1), failureMask(&plugin));
    try std.testing.expectError(error.CallbackFailed, plugin.start());
    try std.testing.expect(!plugin.started);
    plugin.shutdown(.fault);
    try std.testing.expectEqual(@as(u32, 11), failureMask(&plugin));
    try std.testing.expectEqual(abi.shutdown_fault, failureShutdownReason(&plugin));
    plugin.unload();
    try std.testing.expectEqual(@as(u32, 27), failureMask(&plugin));
}

test "descriptor with a foreign fingerprint is rejected without dereferencing it" {
    var host = hostApi();
    try std.testing.expectError(error.FingerprintMismatch, loader.NativePlugin.open(std.testing.allocator, options.mismatch_path, &host, 1));
    try std.testing.expectEqual(abi.load_fingerprint, loader.reasonCode(error.FingerprintMismatch));
}

test "legacy descriptor symbol is reported as legacy ABI" {
    var host = hostApi();
    try std.testing.expectError(error.LegacyAbi, loader.NativePlugin.open(std.testing.allocator, options.legacy_path, &host, 1));
    try std.testing.expectEqual(abi.load_legacy_abi, loader.reasonCode(error.LegacyAbi));
}
