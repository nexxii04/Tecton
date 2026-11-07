const std = @import("std");
const builtin = @import("builtin");
const tecton = @import("tecton");
const NBT = @import("nbt");
const options = @import("bench-options");

const abi = tecton.plugins.abi;
const Events = tecton.events.Events;
const event_types = tecton.events.types;
const PluginRuntime = tecton.plugins.PluginRuntime;

const dispatch_executions = 5;
const dispatch_rounds = 5;
const dispatch_batches = 64;
const dispatch_batch_ops = 4096;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    deny_allocations: bool = false,

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        if (self.deny_allocations) return null;
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        return @ptrCast(memory);
    }

    fn resize(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return false;
    }

    fn remap(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Result = struct {
    median: f64,
    p99: f64,
};

fn printLine(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, format, args);
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

fn sortSamples(samples: []f64) void {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
}

fn median(samples: []f64) f64 {
    sortSamples(samples);
    const middle = samples.len / 2;
    if (samples.len % 2 == 0) return (samples[middle - 1] + samples[middle]) / 2.0;
    return samples[middle];
}

fn p99(samples: []f64) f64 {
    sortSamples(samples);
    const index = (99 * samples.len + 99) / 100 - 1;
    return samples[@min(index, samples.len - 1)];
}

fn maximum(values: []const f64) f64 {
    var result = values[0];
    for (values[1..]) |value| {
        if (value > result) result = value;
    }
    return result;
}

fn elapsedNanos(io: std.Io, start: std.Io.Clock.Timestamp) f64 {
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return @floatFromInt(start.durationTo(end).raw.toNanoseconds());
}

fn expectOk(result: i32) !void {
    if (result != abi.result_ok) return error.BenchmarkFailed;
}

fn setBenchEnvironment(count: usize, phase: u16) !void {
    var count_buffer: [24]u8 = undefined;
    const count_text = try std.fmt.bufPrint(&count_buffer, "{d}", .{count});
    count_buffer[count_text.len] = 0;
    if (setenv("TECTON_BENCH_SUBSCRIBERS", count_buffer[0..count_text.len :0].ptr, 1) != 0) return error.SetEnvironmentFailed;
    const phase_text: [:0]const u8 = switch (phase) {
        abi.event_phase_pre => "pre",
        abi.event_phase_commit => "commit",
        else => "post",
    };
    if (setenv("TECTON_BENCH_PHASE", phase_text.ptr, 1) != 0) return error.SetEnvironmentFailed;
}

fn measureDispatchRun(io: std.Io, allocator: std.mem.Allocator, phase: u16, subscribers: usize) !Result {
    var events = Events.init(allocator);
    defer events.deinit();
    var runtime = PluginRuntime.init(allocator);
    defer runtime.deinit();
    runtime.attachEvents(&events);

    try setBenchEnvironment(subscribers, phase);
    runtime.loadPath(options.plugin_path);
    if (runtime.count() != 1) return error.PluginNotLoaded;
    if (runtime.stateFor(1) != .running) return error.PluginNotRunning;

    var tick = event_types.ServerTickEvent{ .tick = 1 };
    for (0..1024) |_| _ = events.emit(.ServerTick, &tick);

    var batches: [dispatch_batches]f64 = undefined;
    var round_medians: [dispatch_rounds]f64 = undefined;
    var round_tails: [dispatch_rounds]f64 = undefined;
    for (0..dispatch_rounds) |round| {
        for (0..dispatch_batches) |batch| {
            const start = std.Io.Clock.Timestamp.now(io, .awake);
            for (0..dispatch_batch_ops) |_| _ = events.emit(.ServerTick, &tick);
            batches[batch] = elapsedNanos(io, start) / @as(f64, dispatch_batch_ops);
        }
        round_medians[round] = median(&batches);
        round_tails[round] = p99(&batches);
    }

    return .{ .median = median(&round_medians), .p99 = maximum(&round_tails) };
}

fn measureDispatch(io: std.Io, allocator: std.mem.Allocator, phase: u16, subscribers: usize) !Result {
    var medians: [dispatch_executions]f64 = undefined;
    var tails: [dispatch_executions]f64 = undefined;
    for (0..dispatch_executions) |execution| {
        const result = try measureDispatchRun(io, allocator, phase, subscribers);
        medians[execution] = result.median;
        tails[execution] = result.p99;
    }
    return .{ .median = median(&medians), .p99 = median(&tails) };
}

fn benchDispatch(io: std.Io, allocator: std.mem.Allocator) !void {
    const phases = [_]struct { label: []const u8, id: u16 }{
        .{ .label = "pre", .id = abi.event_phase_pre },
        .{ .label = "commit", .id = abi.event_phase_commit },
        .{ .label = "post", .id = abi.event_phase_post },
    };
    const subscribers = [_]usize{ 0, 1, 8, 32, 128 };

    try printLine(io, "\ndispatch ns/op (median, p99); 5 executions x 5 rounds x 64 batches\n", .{});
    try printLine(io, "phase     subs       median          p99\n", .{});
    for (phases) |phase| {
        for (subscribers) |count| {
            const result = try measureDispatch(io, allocator, phase.id, count);
            try printLine(io, "{s:<9} {d:>4} {d:>12.2} {d:>12.2}\n", .{ phase.label, count, result.median, result.p99 });
        }
    }
}

fn benchHandles(io: std.Io, runtime: *PluginRuntime, counted: *CountingAllocator) !void {
    var handle = try runtime.handles.put(.world, 0x1000, 0, &runtime.handles.runtime_head);
    const handle_cell: *volatile u64 = &handle;
    var checksum: usize = 0;

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..10_000_000) |_| {
        checksum +%= runtime.handles.get(.world, handle_cell.*) orelse 0;
    }
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    if (checksum == 0) return error.BenchmarkFailed;
    try printLine(io, "handles.get             {d:>10.2} ns/op   allocations 0\n", .{total / 10_000_000.0});
}

fn benchPlayers(io: std.Io, allocator: std.mem.Allocator, runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, counted: *CountingAllocator) !void {
    const Player = tecton.player.Player;
    const Connection = tecton.transport.Connection;
    const Protocol = tecton.protocol;

    const fake = try allocator.create(tecton.Server);
    fake.* = undefined;
    fake.players = @TypeOf(fake.players).init(io, allocator);
    runtime.tecton = fake;

    const connection = try allocator.create(Connection);
    connection.* = .{
        .id = 1,
        .backend = undefined,
        .allocator = allocator,
        .refs = .init(1),
        .state = .init(.open),
    };

    var storage: [100]Player = undefined;
    for (&storage, 0..) |*player, index| {
        player.* = undefined;
        player.entity.dimension = null;
        player.entity.runtime_id = @intCast(index + 1);
        player.entity.position = Protocol.Vector3f.init(@floatFromInt(index), 64, 0);
        player.entity.rotation = Protocol.Vector2f.init(0, 0);
        player.username = "bench";
        player.uuid = "00000000-0000-0000-0000-000000000000";
        player.gamemode = .Creative;
        player.spawned = true;
        player.connection = connection;
        player.pending_removal = .init(false);
        try fake.players.insert(player);
        _ = try runtime.handles.put(.player, @intFromPtr(player), 0, &runtime.handles.runtime_head);
    }

    var snapshot: abi.PlayerSnapshot = undefined;
    const snapshot_size = @sizeOf(abi.PlayerSnapshot);
    var checksum: usize = 0;

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..1000) |_| {
        for (0..100) |index| {
            try expectOk(runtime.players_api.get_by_index(@ptrCast(slot), index, &snapshot, snapshot_size));
            checksum +%= @intCast(snapshot.runtime_id);
        }
    }
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    if (checksum == 0) return error.BenchmarkFailed;
    try printLine(io, "players.get_by_index+snapshot {d:>9.2} ns/player allocations 0\n", .{total / 100_000.0});

    runtime.tecton = null;
    fake.players.deinit();
    allocator.destroy(fake);
    connection.release();
}

fn benchItems(io: std.Io, allocator: std.mem.Allocator, runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, counted: *CountingAllocator) !void {
    const ItemType = tecton.items.ItemType;
    try ItemType.initRegistry(allocator);
    defer ItemType.deinitRegistry();

    for (0..2000) |index| {
        const name = try allocator.print("bench:item{d}", .{index});
        const item = try ItemType.init(allocator, name, @intCast(10_000 + index), 64, true, &.{}, false, 0, .{ .Compound = NBT.CompoundTag.init(allocator, null) });
        try item.register();
    }

    var snapshot: abi.ItemSnapshot = undefined;
    const snapshot_size = @sizeOf(abi.ItemSnapshot);
    var checksum: usize = 0;

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..1000) |_| {
        for (0..2000) |index| {
            try expectOk(runtime.items_api.get_by_index(@ptrCast(slot), index, &snapshot, snapshot_size));
            checksum +%= @intCast(snapshot.network_id);
        }
    }
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    if (checksum == 0) return error.BenchmarkFailed;
    try printLine(io, "items.get_by_index      {d:>10.2} ns/item  allocations 0\n", .{total / 2_000_000.0});
}

const StubProvider = struct {
    fn readChunk(_: *anyopaque, _: i32, _: i32, _: *tecton.world.Dimension) anyerror!*tecton.world.Chunk {
        return error.NotSupported;
    }

    fn writeChunk(_: *anyopaque, _: *tecton.world.Chunk, _: *tecton.world.Dimension) anyerror!void {}

    fn readBuffer(_: *anyopaque, _: []const u8) anyerror!?[]const u8 {
        return null;
    }

    fn writeBuffer(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}

    fn deinit(_: *anyopaque) void {}

    const vtable = tecton.world.provider.WorldProvider.VTable{
        .read_chunk = readChunk,
        .read_chunk_direct = null,
        .read_chunk_column = null,
        .read_chunk_block_entity_data = null,
        .write_chunk = writeChunk,
        .uncache_chunk = null,
        .read_buffer = readBuffer,
        .write_buffer = writeBuffer,
        .write_player = null,
        .read_player = null,
        .write_chunk_entities = null,
        .read_chunk_entities = null,
        .write_block_entities = null,
        .read_block_entities = null,
        .deinit_fn = deinit,
    };
};

fn benchWorld(io: std.Io, allocator: std.mem.Allocator, runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, counted: *CountingAllocator) !void {
    const BlockPermutation = tecton.block.BlockPermutation;
    const BlockType = tecton.block.BlockType;
    const BlockState = tecton.block.BlockState;
    const World = tecton.world.World;

    try BlockPermutation.initRegistry(allocator);
    defer BlockPermutation.deinitRegistry();
    try BlockType.initRegistry(allocator);
    defer BlockType.deinitRegistry();

    const air_type = try BlockType.init(allocator, "minecraft:air");
    try air_type.register();
    const air_permutation = try BlockPermutation.init(allocator, 0, "minecraft:air", BlockState.init(allocator));
    try air_permutation.register();
    try air_type.addPermutation(air_permutation);

    var world: World = .{
        .tecton = undefined,
        .allocator = allocator,
        .identifier = "bench-world",
        .dimensions = std.StringHashMap(*tecton.world.Dimension).init(allocator),
        .provider = .{ .ptr = undefined, .vtable = &StubProvider.vtable },
    };
    defer world.dimensions.deinit();
    var dimension = tecton.world.Dimension.init(&world, allocator, "overworld", .Overworld, null);
    defer dimension.deinit();
    try world.dimensions.put("overworld", &dimension);

    const world_handle = try runtime.handles.put(.world, @intFromPtr(&world), 0, &runtime.handles.runtime_head);
    const name = abi.StringView{ .data = "overworld", .length = 9 };
    const network_id = @as(u32, @bitCast(air_permutation.network_id));
    try expectOk(runtime.world_api.set_block_state(@ptrCast(slot), world_handle, name, 4, 64, 4, network_id, 0));

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..1_000_000) |_| {
        try expectOk(runtime.world_api.set_block_state(@ptrCast(slot), world_handle, name, 4, 64, 4, network_id, 0));
    }
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    try printLine(io, "world.set_block_state   {d:>10.2} ns/write allocations 0\n", .{total / 1_000_000.0});
}

fn benchScheduler(io: std.Io, runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, counted: *CountingAllocator) !void {
    const callback = struct {
        fn call(_: ?*anyopaque, _: u64) callconv(.c) void {}
    }.call;

    var warmup: u64 = 0;
    try expectOk(runtime.scheduler_api.every(@ptrCast(slot), 1, callback, null, &warmup));
    try expectOk(runtime.scheduler_api.cancel(@ptrCast(slot), warmup));

    var timers: [64]u64 = undefined;
    for (&timers) |*timer| {
        try expectOk(runtime.scheduler_api.every(@ptrCast(slot), 10, callback, null, timer));
    }

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var tick: u64 = 1;
    while (tick <= 20_000) : (tick += 1) runtime.runTimers(tick);
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    if (runtime.timerLiveCount() != 64) return error.BenchmarkFailed;
    for (timers) |timer| try expectOk(runtime.scheduler_api.cancel(@ptrCast(slot), timer));
    try printLine(io, "scheduler.every x64     {d:>10.2} ns/tick  allocations 0\n", .{total / 20_000.0});
}

fn benchCustomEvents(io: std.Io, runtime: *PluginRuntime, slot: *PluginRuntime.HostSlot, counted: *CountingAllocator) !void {
    const schema_name = "bench.custom";
    var schema: u32 = 0;
    try expectOk(runtime.events_api.schema_of(@ptrCast(slot), .{ .data = schema_name.ptr, .length = schema_name.len }, 1, &schema));
    _ = runtime.events_api.emit(@ptrCast(slot), schema, null, 0, 0);
    runtime.endTick();

    var payload: [8]u8 = @splat(0);
    var accepted: usize = 0;
    var busy: usize = 0;

    counted.allocations = 0;
    counted.deny_allocations = true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..4096) |_| {
        const result = runtime.events_api.emit(@ptrCast(slot), schema, &payload, payload.len, 0);
        switch (result) {
            abi.result_ok => accepted += 1,
            abi.result_busy => busy += 1,
            else => return error.BenchmarkFailed,
        }
    }
    const total = elapsedNanos(io, start);
    counted.deny_allocations = false;

    if (counted.allocations != 0) return error.AllocationInHotPath;
    if (accepted != 1024 or busy != 3072) return error.BenchmarkFailed;
    runtime.endTick();
    try printLine(io, "emit_custom full ring   {d:>10.2} ns/emit  allocations 0   accepted 1024 busy 3072\n", .{total / 4096.0});
}

fn benchHotPaths(io: std.Io, allocator: std.mem.Allocator) !void {
    var counted = CountingAllocator.init(allocator);
    var runtime = PluginRuntime.init(counted.allocator());
    defer {
        counted.deny_allocations = false;
        runtime.deinit();
    }
    var slot = PluginRuntime.HostSlot{ .runtime = &runtime, .plugin_id = 0, .name = "bench", .host = undefined, .state = .running };

    try printLine(io, "\nhot path ns/op; every window denies allocations\n", .{});
    try benchHandles(io, &runtime, &counted);
    try benchPlayers(io, allocator, &runtime, &slot, &counted);
    try benchItems(io, allocator, &runtime, &slot, &counted);
    try benchWorld(io, allocator, &runtime, &slot, &counted);
    try benchScheduler(io, &runtime, &slot, &counted);
    try benchCustomEvents(io, &runtime, &slot, &counted);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    try printLine(io, "tecton plugins benchmark | zig {} | {s}\n", .{ builtin.zig_version, @tagName(builtin.os.tag) });
    try printLine(io, "HostApi {} B | HostSlot {} B | EventView {} B | plugin {s}\n", .{ @sizeOf(abi.HostApi), @sizeOf(PluginRuntime.HostSlot), @sizeOf(abi.EventView), options.plugin_path });

    try benchDispatch(io, allocator);
    try benchHotPaths(io, allocator);
}
