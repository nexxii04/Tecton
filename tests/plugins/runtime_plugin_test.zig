const std = @import("std");
const tecton = @import("tecton");
const NBT = @import("nbt");
const options = @import("plugin-options");

const abi = tecton.plugins.abi;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setTracePath(path: [:0]const u8) !void {
    try std.testing.expectEqual(@as(c_int, 0), setenv("TECTON_PLUGIN_TRACE", path.ptr, 1));
}

fn readTrace(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

test "failed plugin start leaves no resources alive" {
    const allocator = std.testing.allocator;
    try tecton.items.ItemType.initRegistry(allocator);
    defer tecton.items.ItemType.deinitRegistry();
    const item = try tecton.items.ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:test_failure"),
        999,
        64,
        true,
        &.{},
        false,
        0,
        .{ .Compound = NBT.CompoundTag.init(allocator, null) },
    );
    try item.register();

    var events = tecton.events.Events.init(allocator);
    defer events.deinit();
    var tasks = tecton.tasks.TaskQueue.init(allocator);
    defer tasks.deinit();
    var runtime = tecton.plugins.PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);
    runtime.tasks = &tasks;

    runtime.loadPath(options.failure_path);

    try std.testing.expectEqual(@as(usize, 0), runtime.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.failedCount());
    try std.testing.expectEqual(tecton.plugins.PluginState.failed, runtime.stateFor(1).?);
    try std.testing.expectEqual(abi.load_callback_failed, runtime.loadReasonFor(1).?);
    try std.testing.expect(!events.hasListeners(.ServerTick));
    try std.testing.expectEqual(@as(usize, 0), tasks.pending());
    try std.testing.expectEqual(@as(usize, 0), runtime.handles.activeCount());
    try std.testing.expectEqual(tecton.plugins.Handles.none, runtime.slots.items[0].?.owns_handles);

    const event_index = @intFromEnum(abi.EventId.server_tick);
    try std.testing.expectEqual(@as(u32, 0), runtime.active[event_index][0]);
    try std.testing.expectEqual(@as(usize, 0), runtime.buckets[event_index][0].items.len);
}

test "duplicate metadata name is rejected and the first plugin stays running" {
    var runtime = tecton.plugins.PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    runtime.loadPath(options.trace_a_path);
    runtime.loadPath(options.trace_duplicate_path);

    try std.testing.expectEqual(@as(usize, 1), runtime.count());
    try std.testing.expectEqual(@as(usize, 1), runtime.failedCount());
    try std.testing.expectEqual(tecton.plugins.PluginState.running, runtime.stateFor(1).?);
    try std.testing.expectEqual(abi.load_ok, runtime.loadReasonFor(1).?);
    try std.testing.expectEqual(tecton.plugins.PluginState.failed, runtime.stateFor(2).?);
    try std.testing.expectEqual(abi.load_duplicate_name, runtime.loadReasonFor(2).?);
    try std.testing.expectEqual(@as(u32, 1), runtime.counters.loaded);
    try std.testing.expectEqual(@as(u32, 1), runtime.counters.failed);
    try std.testing.expectEqual(@as(u32, 1), runtime.counters.by_reason[abi.load_duplicate_name]);
}

test "each load reason is reported in the slot, detail and aggregate counter" {
    const allocator = std.testing.allocator;
    var runtime = tecton.plugins.PluginRuntime.init(allocator);
    defer runtime.deinit();

    const cases = [_]struct { path: []const u8, reason: u32 }{
        .{ .path = "missing-phase6-plugin.so", .reason = abi.load_dlopen },
        .{ .path = options.no_query_path, .reason = abi.load_symbol_missing },
        .{ .path = options.legacy_path, .reason = abi.load_legacy_abi },
        .{ .path = options.reason_abi_major_path, .reason = abi.load_abi_major },
        .{ .path = options.reason_abi_minor_path, .reason = abi.load_abi_minor },
        .{ .path = options.mismatch_path, .reason = abi.load_fingerprint },
        .{ .path = options.reason_descriptor_path, .reason = abi.load_descriptor },
        .{ .path = options.reason_metadata_path, .reason = abi.load_metadata },
        .{ .path = options.reason_required_feature_path, .reason = abi.load_required_feature },
        .{ .path = options.reason_missing_callback_path, .reason = abi.load_missing_callback },
        .{ .path = options.failure_path, .reason = abi.load_callback_failed },
    };

    for (cases, 0..) |case, index| {
        runtime.loadPath(case.path);
        const plugin_id: u32 = @intCast(index + 1);
        try std.testing.expectEqual(tecton.plugins.PluginState.failed, runtime.stateFor(plugin_id).?);
        try std.testing.expectEqual(case.reason, runtime.loadReasonFor(plugin_id).?);
        try std.testing.expect(runtime.loadDetailFor(plugin_id).?.len > 0);
        try std.testing.expectEqual(@as(u32, 1), runtime.counters.by_reason[case.reason]);
    }

    try std.testing.expectEqual(@as(u32, cases.len), runtime.counters.failed);
    try std.testing.expectEqual(@as(u32, 0), runtime.counters.loaded);
    try std.testing.expectEqual(@as(u32, 0), runtime.counters.unloaded);

    const snapshots = try runtime.snapshotPlugins(allocator);
    defer allocator.free(snapshots);
    try std.testing.expectEqual(cases.len, snapshots.len);
    for (snapshots, 0..) |snapshot, snapshot_index| {
        const expected_previous: tecton.plugins.PluginState = if (cases[snapshot_index].reason == abi.load_callback_failed) .starting else .loading;
        try std.testing.expectEqual(tecton.plugins.PluginState.failed, snapshot.state);
        try std.testing.expectEqual(expected_previous, snapshot.previous_state);
        try std.testing.expect(snapshot.load_detail.len > 0);
        switch (cases[snapshot_index].reason) {
            abi.load_abi_major, abi.load_abi_minor => {
                try std.testing.expectEqual(@as(u16, 2), snapshot.abi_major);
                try std.testing.expectEqual(@as(u16, 0), snapshot.abi_minor);
            },
            abi.load_dlopen, abi.load_symbol_missing, abi.load_legacy_abi => {
                try std.testing.expectEqual(@as(u16, 0), snapshot.abi_major);
                try std.testing.expectEqual(@as(u16, 0), snapshot.abi_minor);
            },
            else => {},
        }
    }
}

test "out of memory during load is reported as a failed slot" {
    const allocator = std.testing.allocator;
    var index: usize = 1;
    var found = false;
    while (index < 24 and !found) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = index });
        var runtime = tecton.plugins.PluginRuntime.init(failing.allocator());
        runtime.loadPath(options.trace_a_path);
        const snapshots = runtime.snapshotPlugins(allocator) catch &.{};
        if (snapshots.len > 0) {
            if (snapshots[0].state == .failed and snapshots[0].load_reason == abi.load_out_of_memory) found = true;
            allocator.free(snapshots);
        }
        runtime.deinit();
    }
    try std.testing.expect(found);
}

test "unload reports counters and removes the running slot" {
    var runtime = tecton.plugins.PluginRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    runtime.loadPath(options.trace_a_path);
    try std.testing.expectEqual(tecton.plugins.PluginState.running, runtime.stateFor(1).?);
    try std.testing.expectEqual(@as(u32, 1), runtime.counters.loaded);

    runtime.unloadPlugin(1);
    try std.testing.expect(runtime.stateFor(1) == null);
    try std.testing.expectEqual(@as(u32, 1), runtime.counters.unloaded);
}

test "on_ready runs after every on_start in load order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var trace_buf: [512]u8 = undefined;
    const trace_path = try std.fmt.bufPrintZ(&trace_buf, ".zig-cache/tmp/{s}/trace.log", .{tmp.sub_path});
    try setTracePath(trace_path);

    try tmp.dir.createDir(io, "plugins", .default_dir);
    const sources = [_][]const u8{ options.trace_a_path, options.trace_b_path };
    const names = [_][]const u8{ "plugins/a.so", "plugins/b.so" };
    for (sources, names) |source, name| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(1 << 24));
        defer allocator.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    }

    var dir_buf: [512]u8 = undefined;
    const plugins_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/plugins", .{tmp.sub_path});
    var runtime = tecton.plugins.PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.discover(io, plugins_dir);

    try std.testing.expectEqual(@as(usize, 2), runtime.count());
    const trace = try readTrace(allocator, trace_path);
    defer allocator.free(trace);
    try std.testing.expectEqualStrings("a:load\na:start\nb:load\nb:start\na:ready\nb:ready\n", trace);
}

test "deinit unloads plugins while players are still registered" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var trace_buf: [512]u8 = undefined;
    const trace_path = try std.fmt.bufPrintZ(&trace_buf, ".zig-cache/tmp/{s}/trace.log", .{tmp.sub_path});
    try setTracePath(trace_path);

    var worlds_buf: [512]u8 = undefined;
    const worlds_path = try std.fmt.bufPrint(&worlds_buf, ".zig-cache/tmp/{s}/worlds", .{tmp.sub_path});

    var server = try tecton.Server.init(.{
        .io = std.testing.io,
        .allocator = allocator,
        .composition = tecton.composition,
        .properties = tecton.ServerProperties{ .allocator = allocator, .address = "127.0.0.1", .port = 0 },
        .paths = .{ .worlds = worlds_path, .plugins = "test-plugins" },
        .enable_console = false,
        .discover_native_plugins = false,
        .auto_load_worlds = false,
        .create_default_world = false,
    });
    var deinited = false;
    defer if (!deinited) server.deinit();

    var network: tecton.network.NetworkHandler = undefined;
    network.allocator = allocator;
    network.send_buffers = .empty;
    network.port = null;
    network.options = .{ .compression_method = .NotPresent, .compression_threshold = 255 };
    server.network = &network;
    server.network_initialized = true;
    server.fixAddress();
    try server.prepare();
    server.network_initialized = false;

    server.plugin_runtime.loadPath(options.trace_a_path);
    try std.testing.expectEqual(@as(usize, 1), server.plugin_runtime.count());
    server.players.online_count.store(1, .release);

    server.deinit();
    deinited = true;

    const trace = try readTrace(allocator, trace_path);
    defer allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "a:shutdown:1") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "a:shutdown:"));
}
