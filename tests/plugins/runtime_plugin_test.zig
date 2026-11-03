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
    try std.testing.expectEqual(tecton.plugins.PluginState.failed, runtime.stateFor(2).?);
    try std.testing.expectEqual(abi.load_duplicate_name, runtime.loadReasonFor(2).?);
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
