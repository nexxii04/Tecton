const std = @import("std");
const testing = std.testing;

const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const bot_mod = @import("bot.zig");
const Bot = bot_mod.Bot;
const Counters = bot_mod.Counters;
const Layout = bot_mod.Layout;

const usage =
    \\Usage: tecton-loadbot [options]
    \\
    \\Drives fake Bedrock clients against a running server so the player ceiling
    \\can be measured without real clients. Reports the traffic it generates; the
    \\server's own tick profile is the other half of the picture.
    \\
    \\  --host <addr>         server address (default 127.0.0.1)
    \\  --port <port>         server port (default 19132)
    \\  --bots <n>            how many bots to run (default 10)
    \\  --ramp <n>            bots started per second (default 20, 0 = no ramp)
    \\  --hold <seconds>      keep the bots connected this long (default 60)
    \\  --name-prefix <text>  display name prefix (default LoadBot)
    \\  --chunk-radius <n>    view distance each bot requests (default 8)
    \\  --walk                make every bot walk instead of standing still
    \\  --speed <blocks/s>    walking speed (default 4.3)
    \\  --layout <cluster|grid>
    \\                        grid: one bot per spacing (default); cluster:
    \\                        everyone in one chunk, worst-case movement fan-out
    \\  --spacing <blocks>    grid spacing and walking patrol length (default 16)
    \\  --spawn-y <blocks>    height the bots report (default 100; they never
    \\                        fall, so a ground-level visual check sets it)
    \\  --inventory           after spawning, drag a stack between two hotbar
    \\                        slots with real ItemStackRequest packets
    \\  --inventory-hz <n>    drags per bot per second (default 10, max 20)
    \\  --give-items          fill the hotbar through /give before the hold
    \\  --enchant-items       also /enchant every hotbar slot (implies
    \\                        --give-items); the inventories persist on disk,
    \\                        so a later run with the same names starts seeded
    \\  --curse-binding       run the armor scenario instead (implies
    \\                        --give-items): give boots, curse them, equip them
    \\                        through an ItemStackRequest, take an empty armor
    \\                        slot off as a control and then try to take the
    \\                        cursed piece off, which the server must refuse
    \\  --duel                run the two-bot protection/thorns scenario
    \\                        (requires --bots 2): bot 0 swings, bot 1 wears
    \\                        the armor and reports its own health. Flags:
    \\    --duel-pieces <0-4>   armor pieces the victim wears (default 4)
    \\    --duel-enchant <name> enchantment on them; "none" skips it and measures
    \\                          bare diamond (default protection)
    \\    --duel-level <n>      level for that enchantment (default 4)
    \\    --duel-thorns <0-4>   pieces that also carry Thorns III (default 0)
    \\    --duel-swings <n>     hits the attacker throws (default 20)
    \\    --duel-weapon <none|item>
    \\                          item in the attacker's hand; "none" swings the
    \\                          fist (1 damage), which stretches a Thorns sample
    \\                          (default diamond_sword)
    \\  --no-compress         send uncompressed datagrams (less bot CPU)
    \\  --report <seconds>    interval between progress lines (default 5)
    \\  --mtu <bytes>         RakNet MTU to offer (default 1492)
    \\  --verbose             log every bot event
    \\  --help                show this message
    \\
;

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 19132,
    bots: usize = 10,
    ramp_per_second: usize = 20,
    hold_seconds: u64 = 60,
    name_prefix: []const u8 = "LoadBot",
    chunk_radius: i32 = 8,
    walk: bool = false,
    speed: f32 = 4.3,
    layout: Layout = .grid,
    spacing: f32 = 16.0,
    spawn_y: f32 = 100.0,
    inventory: bool = false,
    inventory_hz: u32 = 10,
    give_items: bool = false,
    enchant_items: bool = false,
    curse_binding: bool = false,
    duel: bool = false,
    duel_pieces: u8 = 4,
    duel_enchant: []const u8 = "protection",
    duel_level: u8 = 4,
    duel_thorns: u8 = 0,
    duel_swings: u32 = 20,
    duel_weapon: []const u8 = "diamond_sword",
    compress: bool = true,
    report_seconds: u64 = 5,
    mtu_size: u16 = 1492,
    verbose: bool = false,
};

const Snapshot = struct {
    packets_sent: u64,
    bytes_sent: u64,
    packets_received: u64,
    bytes_received: u64,
    move_packets: u64,
    chunk_packets: u64,
    inv_requests: u64,
    inv_responses: u64,
    inv_errors: u64,
    inv_content_packets: u64,
    inv_content_bytes: u64,
    inv_slot_packets: u64,
    inv_slot_bytes: u64,
    commands_sent: u64,
    command_outputs: u64,
    command_failures: u64,
    curse_held: u64,
    curse_leaks: u64,
    curse_control: u64,
    duel_ready: u64,
    duel_swings: u64,

    fn take(counters: *const Counters) Snapshot {
        return .{
            .packets_sent = counters.packets_sent.load(.monotonic),
            .bytes_sent = counters.bytes_sent.load(.monotonic),
            .packets_received = counters.packets_received.load(.monotonic),
            .bytes_received = counters.bytes_received.load(.monotonic),
            .move_packets = counters.move_packets.load(.monotonic),
            .chunk_packets = counters.chunk_packets.load(.monotonic),
            .inv_requests = counters.inv_requests.load(.monotonic),
            .inv_responses = counters.inv_responses.load(.monotonic),
            .inv_errors = counters.inv_errors.load(.monotonic),
            .inv_content_packets = counters.inv_content_packets.load(.monotonic),
            .inv_content_bytes = counters.inv_content_bytes.load(.monotonic),
            .inv_slot_packets = counters.inv_slot_packets.load(.monotonic),
            .inv_slot_bytes = counters.inv_slot_bytes.load(.monotonic),
            .commands_sent = counters.commands_sent.load(.monotonic),
            .command_outputs = counters.command_outputs.load(.monotonic),
            .command_failures = counters.command_failures.load(.monotonic),
            .curse_held = counters.curse_held.load(.monotonic),
            .curse_leaks = counters.curse_leaks.load(.monotonic),
            .curse_control = counters.curse_control.load(.monotonic),
            .duel_ready = counters.duel_ready.load(.monotonic),
            .duel_swings = counters.duel_swings.load(.monotonic),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const allocator = init.gpa;

    const args = std.process.Args.toSlice(init.minimal.args, arena) catch {
        std.process.exit(2);
    };

    const options = parseArgs(args) orelse {
        print(io, "{s}", .{usage});
        std.process.exit(2);
    };

    if (options.bots == 0) {
        print(io, "refusing to run with zero bots\n", .{});
        std.process.exit(2);
    }

    if (options.duel and options.bots != 2) {
        print(io, "the duel scenario is two bots: bot 0 swings, bot 1 wears (--bots 2)\n", .{});
        std.process.exit(2);
    }

    // ZigNet panics if its logger was never initialised.
    Raknet.Logger.init(allocator);

    const server_address = try std.fmt.allocPrint(arena, "{s}:{d}", .{ options.host, options.port });

    var counters = Counters{};
    var stop = std.atomic.Value(bool).init(false);

    const config = bot_mod.Config{
        .io = io,
        .host = options.host,
        .port = options.port,
        .mtu_size = options.mtu_size,
        .chunk_radius = options.chunk_radius,
        .walk = options.walk,
        .speed = options.speed,
        .layout = options.layout,
        .spacing = options.spacing,
        .spawn_y = options.spawn_y,
        .inventory = options.inventory,
        .inventory_hz = options.inventory_hz,
        .give_items = options.give_items,
        .enchant_items = options.enchant_items,
        .curse_binding = options.curse_binding,
        .duel = options.duel,
        .duel_pieces = options.duel_pieces,
        .duel_enchant = options.duel_enchant,
        .duel_level = options.duel_level,
        .duel_thorns = options.duel_thorns,
        .duel_swings = options.duel_swings,
        .duel_weapon = options.duel_weapon,
        .frame_options = .{ .compress = options.compress },
        .server_address = server_address,
        .game_version = Protocol.MINECRAFT_VERSION,
        .verbose = options.verbose,
        .stop = &stop,
    };

    print(
        io,
        "tecton-loadbot -> {s}  bots={d} ramp={d}/s hold={d}s layout={s} walk={} compress={} inventory={} give={} enchant={} curse={} duel={}\n",
        .{
            server_address,
            options.bots,
            options.ramp_per_second,
            options.hold_seconds,
            @tagName(options.layout),
            options.walk,
            options.compress,
            options.inventory,
            options.give_items,
            options.enchant_items,
            options.curse_binding,
            options.duel,
        },
    );

    const bots = try allocator.alloc(*Bot, options.bots);
    defer allocator.free(bots);
    const threads = try allocator.alloc(std.Thread, options.bots);
    defer allocator.free(threads);

    const ramp_interval_ns: i96 = if (options.ramp_per_second == 0)
        0
    else
        @divTrunc(@as(i96, std.time.ns_per_s), @as(i96, @intCast(options.ramp_per_second)));

    var running: usize = 0;
    for (0..options.bots) |index| {
        const name = try std.fmt.allocPrint(arena, "{s}{d:0>4}", .{ options.name_prefix, index });
        const bot = Bot.init(allocator, &config, &counters, index, name) catch {
            _ = counters.failed.fetchAdd(1, .monotonic);
            continue;
        };

        threads[running] = std.Thread.spawn(.{}, Bot.run, .{bot}) catch {
            bot.deinit();
            _ = counters.failed.fetchAdd(1, .monotonic);
            continue;
        };
        bots[running] = bot;
        running += 1;

        if (ramp_interval_ns > 0 and running < options.bots) {
            io.sleep(std.Io.Duration.fromNanoseconds(ramp_interval_ns), .awake) catch {};
        }
    }

    print(io, "ramp finished: {d}/{d} bots started\n", .{ running, options.bots });

    var previous = Snapshot.take(&counters);
    var elapsed_seconds: u64 = 0;
    while (elapsed_seconds < options.hold_seconds) {
        io.sleep(std.Io.Duration.fromSeconds(@intCast(options.report_seconds)), .awake) catch break;
        elapsed_seconds += options.report_seconds;

        const current = Snapshot.take(&counters);
        const seconds: f64 = @floatFromInt(options.report_seconds);
        const spawned = counters.spawned.load(.monotonic);

        var bytes_out: [32]u8 = undefined;
        var bytes_in: [32]u8 = undefined;
        var proxy: [32]u8 = undefined;

        print(
            io,
            "t={d:>4}s conn={d} spawn={d} fail={d} dead={d} | out {d:>7.0}/s {s:>8}/s | in {d:>8.0}/s {s:>9}/s | move {d:>8.0}/s{s} chunk {d:>7.0}/s\n",
            .{
                elapsed_seconds,
                counters.connected.load(.monotonic),
                spawned,
                counters.failed.load(.monotonic),
                counters.dead.load(.monotonic),
                rate(current.packets_sent - previous.packets_sent, seconds),
                formatBytes(&bytes_out, current.bytes_sent - previous.bytes_sent, seconds),
                rate(current.packets_received - previous.packets_received, seconds),
                formatBytes(&bytes_in, current.bytes_received - previous.bytes_received, seconds),
                rate(current.move_packets - previous.move_packets, seconds),
                movementPerBot(&proxy, spawned, current.move_packets - previous.move_packets, seconds),
                rate(current.chunk_packets - previous.chunk_packets, seconds),
            },
        );

        if (options.inventory) {
            print(
                io,
                "           inventory: drag {d:>7.0}/s resp {d:>7.0}/s err {d:>7.0}/s content {d:>6.0}/s slot {d:>6.0}/s\n",
                .{
                    rate(current.inv_requests - previous.inv_requests, seconds),
                    rate(current.inv_responses - previous.inv_responses, seconds),
                    rate(current.inv_errors - previous.inv_errors, seconds),
                    rate(current.inv_content_packets - previous.inv_content_packets, seconds),
                    rate(current.inv_slot_packets - previous.inv_slot_packets, seconds),
                },
            );
            print(
                io,
                "           container bytes: content {d:.1} B/packet, slot {d:.1} B/packet\n",
                .{
                    perPacket(current.inv_content_bytes, current.inv_content_packets),
                    perPacket(current.inv_slot_bytes, current.inv_slot_packets),
                },
            );
        }

        if (options.give_items) {
            print(
                io,
                "           setup: {d} commands sent, {d} answered, {d} refused\n",
                .{
                    current.commands_sent,
                    current.command_outputs,
                    current.command_failures,
                },
            );
        }

        if (options.curse_binding) {
            print(
                io,
                "           curse of binding: {d} refusals, {d} leaks, {d} refused controls\n",
                .{ current.curse_held, current.curse_leaks, current.curse_control },
            );
        }

        if (options.duel) {
            print(
                io,
                "           duel: ready {d}, swings thrown {d}\n",
                .{ current.duel_ready, current.duel_swings },
            );
        }

        previous = current;
    }

    stop.store(true, .release);
    for (threads[0..running]) |thread| thread.join();
    for (bots[0..running]) |bot| bot.deinit();

    const final = Snapshot.take(&counters);
    print(
        io,
        "\nsummary: started {d} connected {d} spawned {d} failed {d} closed {d} kicked {d}\n" ++
            "         sent {d} packets ({d} bytes)  received {d} packets ({d} bytes)\n" ++
            "         chunks {d}  movement updates {d}\n",
        .{
            counters.started.load(.monotonic),
            counters.connected.load(.monotonic),
            counters.spawned.load(.monotonic),
            counters.failed.load(.monotonic),
            counters.dead.load(.monotonic),
            counters.kicked.load(.monotonic),
            final.packets_sent,
            final.bytes_sent,
            final.packets_received,
            final.bytes_received,
            final.chunk_packets,
            final.move_packets,
        },
    );

    if (options.inventory) {
        print(
            io,
            "         inventory: {d} drags, {d} responses, {d} errors, {d} content packets, {d} slot packets\n" ++
                "         container bytes: content {d:.1} B/packet, slot {d:.1} B/packet\n",
            .{
                final.inv_requests,
                final.inv_responses,
                final.inv_errors,
                final.inv_content_packets,
                final.inv_slot_packets,
                perPacket(final.inv_content_bytes, final.inv_content_packets),
                perPacket(final.inv_slot_bytes, final.inv_slot_packets),
            },
        );
    }

    if (options.give_items) {
        print(
            io,
            "         setup: {d} commands sent, {d} answered, {d} refused\n",
            .{ final.commands_sent, final.command_outputs, final.command_failures },
        );
    }

    if (options.curse_binding) {
        print(
            io,
            "         curse of binding: {d} refusals, {d} leaks, {d} refused controls ({d} armor requests)\n",
            .{ final.curse_held, final.curse_leaks, final.curse_control, final.inv_requests },
        );
        if (final.inv_requests == 0) {
            print(io, "         the scenario sent no armor request: nothing was proven\n", .{});
        } else if (final.curse_held == 0) {
            print(io, "         no bot ever saw the removal refused: nothing was proven\n", .{});
        }
    }

    if (options.duel) {
        print(
            io,
            "         duel: ready {d}, swings thrown {d}\n",
            .{ final.duel_ready, final.duel_swings },
        );
        if (final.duel_swings == 0) {
            print(io, "         the attacker threw no swing: nothing was proven\n", .{});
        } else if (final.duel_swings < options.duel_swings) {
            print(io, "         the swing budget was not used up; see the bot verdicts\n", .{});
        }
    }
}

fn parseArgs(args: []const [:0]const u8) ?Options {
    var options = Options{};
    var index: usize = 1;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return null;

        if (std.mem.eql(u8, arg, "--walk")) {
            options.walk = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-compress")) {
            options.compress = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--inventory")) {
            options.inventory = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--give-items")) {
            options.give_items = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--enchant-items")) {
            options.give_items = true;
            options.enchant_items = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--curse-binding")) {
            options.give_items = true;
            options.curse_binding = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--duel")) {
            options.duel = true;
            continue;
        }

        if (index + 1 >= args.len) return null;
        const value = args[index + 1];
        index += 1;

        if (std.mem.eql(u8, arg, "--host")) {
            options.host = value;
        } else if (std.mem.eql(u8, arg, "--port")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--bots")) {
            options.bots = std.fmt.parseInt(usize, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--ramp")) {
            options.ramp_per_second = std.fmt.parseInt(usize, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--hold")) {
            options.hold_seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--name-prefix")) {
            options.name_prefix = value;
        } else if (std.mem.eql(u8, arg, "--chunk-radius")) {
            options.chunk_radius = std.fmt.parseInt(i32, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--speed")) {
            options.speed = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, arg, "--layout")) {
            options.layout = std.meta.stringToEnum(Layout, value) orelse return null;
        } else if (std.mem.eql(u8, arg, "--spacing")) {
            options.spacing = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, arg, "--spawn-y")) {
            options.spawn_y = std.fmt.parseFloat(f32, value) catch return null;
        } else if (std.mem.eql(u8, arg, "--inventory-hz")) {
            options.inventory_hz = std.fmt.parseInt(u32, value, 10) catch return null;
            if (options.inventory_hz == 0 or options.inventory_hz > 20) return null;
            options.inventory = true;
        } else if (std.mem.eql(u8, arg, "--duel-pieces")) {
            options.duel_pieces = std.fmt.parseInt(u8, value, 10) catch return null;
            if (options.duel_pieces > 4) return null;
        } else if (std.mem.eql(u8, arg, "--duel-enchant")) {
            options.duel_enchant = value;
        } else if (std.mem.eql(u8, arg, "--duel-level")) {
            options.duel_level = std.fmt.parseInt(u8, value, 10) catch return null;
            if (options.duel_level == 0) return null;
        } else if (std.mem.eql(u8, arg, "--duel-thorns")) {
            options.duel_thorns = std.fmt.parseInt(u8, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--duel-swings")) {
            options.duel_swings = std.fmt.parseInt(u32, value, 10) catch return null;
            if (options.duel_swings == 0) return null;
        } else if (std.mem.eql(u8, arg, "--duel-weapon")) {
            options.duel_weapon = value;
        } else if (std.mem.eql(u8, arg, "--report")) {
            options.report_seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--mtu")) {
            options.mtu_size = std.fmt.parseInt(u16, value, 10) catch return null;
        } else {
            return null;
        }
    }

    // Scenarios drive mutually exclusive setup flows; mixing them would leave
    // one pump accounting for steps another sends.
    if (options.duel and options.curse_binding) return null;
    if (options.duel and options.inventory) return null;
    if (options.curse_binding and options.inventory) return null;

    // Checked once both values are final, so flag order does not matter.
    if (options.duel_thorns > options.duel_pieces) return null;
    if (options.report_seconds == 0) return null;
    return options;
}

fn rate(delta: u64, seconds: f64) f64 {
    return @as(f64, @floatFromInt(delta)) / seconds;
}

fn perPacket(bytes: u64, packets: u64) f64 {
    if (packets == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(packets));
}

fn formatBytes(out: []u8, delta: u64, seconds: f64) []const u8 {
    const per_second = @as(f64, @floatFromInt(delta)) / seconds;
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };

    var value = per_second;
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;

    return std.fmt.bufPrint(out, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

/// Movement updates per bot per second.
fn movementPerBot(out: []u8, spawned: u64, move_delta: u64, seconds: f64) []const u8 {
    if (spawned == 0) return "";

    const per_bot = @as(f64, @floatFromInt(move_delta)) / seconds / @as(f64, @floatFromInt(spawned));
    return std.fmt.bufPrint(out, " ({d:.1}/bot)", .{per_bot}) catch "";
}

fn print(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

test "parseArgs reads every option" {
    const argv = [_][:0]const u8{
        "tecton-loadbot",
        "--host",
        "10.0.0.5",
        "--port",
        "19133",
        "--bots",
        "64",
        "--ramp",
        "0",
        "--hold",
        "30",
        "--walk",
        "--layout",
        "cluster",
        "--spacing",
        "8",
        "--spawn-y",
        "-57",
        "--no-compress",
        "--inventory-hz",
        "5",
    };

    const options = parseArgs(&argv) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("10.0.0.5", options.host);
    try testing.expectEqual(@as(u16, 19133), options.port);
    try testing.expectEqual(@as(usize, 64), options.bots);
    try testing.expectEqual(@as(usize, 0), options.ramp_per_second);
    try testing.expectEqual(@as(u64, 30), options.hold_seconds);
    try testing.expect(options.walk);
    try testing.expectEqual(Layout.cluster, options.layout);
    try testing.expectEqual(@as(f32, 8), options.spacing);
    try testing.expectEqual(@as(f32, -57), options.spawn_y);
    try testing.expect(!options.compress);
    try testing.expect(options.inventory);
    try testing.expectEqual(@as(u32, 5), options.inventory_hz);
    try testing.expect(!options.give_items);
}

test "enchanting the items implies giving them first" {
    const enchant = [_][:0]const u8{ "tecton-loadbot", "--enchant-items" };
    const options = parseArgs(&enchant) orelse return error.TestUnexpectedResult;
    try testing.expect(options.give_items);
    try testing.expect(options.enchant_items);
}

test "the curse scenario implies giving the item it wears" {
    const curse = [_][:0]const u8{ "tecton-loadbot", "--curse-binding" };
    const options = parseArgs(&curse) orelse return error.TestUnexpectedResult;
    try testing.expect(options.curse_binding);
    try testing.expect(options.give_items);
    try testing.expect(!options.enchant_items);
    try testing.expect(!options.inventory);
}

test "the duel flags describe both sides of the ladder" {
    const ladder = [_][:0]const u8{
        "tecton-loadbot", "--duel",     "--bots",        "2",
        "--duel-pieces",  "2",          "--duel-thorns", "1",
        "--duel-enchant", "protection", "--duel-level",  "4",
        "--duel-swings",  "8",          "--duel-weapon", "none",
    };

    const options = parseArgs(&ladder) orelse return error.TestUnexpectedResult;
    try testing.expect(options.duel);
    try testing.expectEqual(@as(u8, 2), options.duel_pieces);
    try testing.expectEqual(@as(u8, 1), options.duel_thorns);
    try testing.expectEqualStrings("protection", options.duel_enchant);
    try testing.expectEqual(@as(u8, 4), options.duel_level);
    try testing.expectEqual(@as(u32, 8), options.duel_swings);
    try testing.expectEqualStrings("none", options.duel_weapon);

    const braceless = [_][:0]const u8{ "tecton-loadbot", "--duel" };
    const defaults = parseArgs(&braceless) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 4), defaults.duel_pieces);
    try testing.expectEqual(@as(u8, 0), defaults.duel_thorns);
    try testing.expectEqual(@as(u8, 4), defaults.duel_level);
    try testing.expectEqual(@as(u32, 20), defaults.duel_swings);
    try testing.expectEqualStrings("protection", defaults.duel_enchant);
    try testing.expectEqualStrings("diamond_sword", defaults.duel_weapon);

    const too_many = [_][:0]const u8{ "tecton-loadbot", "--duel-pieces", "5" };
    try testing.expect(parseArgs(&too_many) == null);

    const no_piece = [_][:0]const u8{ "tecton-loadbot", "--duel-pieces", "0", "--duel-thorns", "1" };
    try testing.expect(parseArgs(&no_piece) == null);

    const no_swings = [_][:0]const u8{ "tecton-loadbot", "--duel-swings", "0" };
    try testing.expect(parseArgs(&no_swings) == null);

    // Thorns may arrive before pieces; the budget check runs once both are final.
    const reversed = [_][:0]const u8{ "tecton-loadbot", "--duel-thorns", "1", "--duel-pieces", "0" };
    try testing.expect(parseArgs(&reversed) == null);
}

test "overlapping scenarios are rejected instead of silently picking one" {
    const duel_curse = [_][:0]const u8{ "tecton-loadbot", "--duel", "--curse-binding" };
    try testing.expect(parseArgs(&duel_curse) == null);

    const duel_inventory = [_][:0]const u8{ "tecton-loadbot", "--duel", "--inventory" };
    try testing.expect(parseArgs(&duel_inventory) == null);

    const curse_inventory = [_][:0]const u8{ "tecton-loadbot", "--curse-binding", "--inventory" };
    try testing.expect(parseArgs(&curse_inventory) == null);

    // `--inventory-hz` implies `--inventory`, so it conflicts the same way.
    const duel_hz = [_][:0]const u8{ "tecton-loadbot", "--duel", "--inventory-hz", "5" };
    try testing.expect(parseArgs(&duel_hz) == null);
}

test "the inventory drag rate is opt in and stays under the input tick rate" {
    const off = [_][:0]const u8{"tecton-loadbot"};
    const default_options = parseArgs(&off) orelse return error.TestUnexpectedResult;
    try testing.expect(!default_options.inventory);

    const too_fast = [_][:0]const u8{ "tecton-loadbot", "--inventory-hz", "21" };
    try testing.expect(parseArgs(&too_fast) == null);

    const zero = [_][:0]const u8{ "tecton-loadbot", "--inventory-hz", "0" };
    try testing.expect(parseArgs(&zero) == null);
}

test "parseArgs rejects unknown flags and missing values" {
    const unknown = [_][:0]const u8{ "tecton-loadbot", "--wat" };
    try testing.expect(parseArgs(&unknown) == null);

    const missing_value = [_][:0]const u8{ "tecton-loadbot", "--bots" };
    try testing.expect(parseArgs(&missing_value) == null);

    const bad_layout = [_][:0]const u8{ "tecton-loadbot", "--layout", "spiral" };
    try testing.expect(parseArgs(&bad_layout) == null);
}
