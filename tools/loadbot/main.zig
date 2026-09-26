const std = @import("std");

const Protocol = @import("protocol");
const Raknet = @import("Raknet");

const bot_mod = @import("bot.zig");
const Bot = bot_mod.Bot;
const Counters = bot_mod.Counters;
const Layout = bot_mod.Layout;

const usage =
    \\Usage: conduit-loadbot [options]
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

    fn take(counters: *const Counters) Snapshot {
        return .{
            .packets_sent = counters.packets_sent.load(.monotonic),
            .bytes_sent = counters.bytes_sent.load(.monotonic),
            .packets_received = counters.packets_received.load(.monotonic),
            .bytes_received = counters.bytes_received.load(.monotonic),
            .move_packets = counters.move_packets.load(.monotonic),
            .chunk_packets = counters.chunk_packets.load(.monotonic),
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
        .frame_options = .{ .compress = options.compress },
        .server_address = server_address,
        .game_version = Protocol.MINECRAFT_VERSION,
        .verbose = options.verbose,
        .stop = &stop,
    };

    print(
        io,
        "conduit-loadbot -> {s}  bots={d} ramp={d}/s hold={d}s layout={s} walk={} compress={}\n",
        .{
            server_address,
            options.bots,
            options.ramp_per_second,
            options.hold_seconds,
            @tagName(options.layout),
            options.walk,
            options.compress,
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
        } else if (std.mem.eql(u8, arg, "--report")) {
            options.report_seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--mtu")) {
            options.mtu_size = std.fmt.parseInt(u16, value, 10) catch return null;
        } else {
            return null;
        }
    }

    if (options.report_seconds == 0) return null;
    return options;
}

fn rate(delta: u64, seconds: f64) f64 {
    return @as(f64, @floatFromInt(delta)) / seconds;
}

fn formatBytes(out: []u8, delta: u64, seconds: f64) []const u8 {
    const per_second = @as(f64, @floatFromInt(delta)) / seconds;
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };

    var value = per_second;
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;

    return std.fmt.bufPrint(out, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

/// Movement updates per bot per second; a walking bot fans out to every bot
/// that can see it.
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

const testing = std.testing;

test "parseArgs reads every option" {
    const argv = [_][:0]const u8{
        "conduit-loadbot",
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
        "--no-compress",
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
    try testing.expect(!options.compress);
}

test "parseArgs rejects unknown flags and missing values" {
    const unknown = [_][:0]const u8{ "conduit-loadbot", "--wat" };
    try testing.expect(parseArgs(&unknown) == null);

    const missing_value = [_][:0]const u8{ "conduit-loadbot", "--bots" };
    try testing.expect(parseArgs(&missing_value) == null);

    const bad_layout = [_][:0]const u8{ "conduit-loadbot", "--layout", "spiral" };
    try testing.expect(parseArgs(&bad_layout) == null);
}
