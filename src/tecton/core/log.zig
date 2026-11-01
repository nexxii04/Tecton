const std = @import("std");

const scope = .tecton;
const scoped = std.log.scoped(scope);

var level_filter = std.atomic.Value(u8).init(@intFromEnum(std.log.default_level));

/// Raises or lowers the runtime threshold. It can only silence messages that
/// the compile-time `std.log_level` already kept.
pub fn setLevel(threshold: std.log.Level) void {
    level_filter.store(@intFromEnum(threshold), .release);
}

pub fn level() std.log.Level {
    return @enumFromInt(level_filter.load(.acquire));
}

pub fn enabled(comptime message_level: std.log.Level) bool {
    return std.log.logEnabled(message_level, scope) and
        @intFromEnum(message_level) <= level_filter.load(.monotonic);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    scoped.debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    scoped.info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    scoped.warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    scoped.err(fmt, args);
}

/// `std_options.logFn` implementation for the executable. It writes one
/// complete line under the stderr lock so concurrent writers never interleave.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime record_scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(message_level)) return;

    const io = std.Options.debug_io;
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);

    var buffer: [64]u8 = undefined;
    const terminal = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    writeRecord(terminal, message_level, record_scope, format, args) catch {};
}

const Stamp = struct {
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
};

fn stamp(timestamp: std.Io.Timestamp) Stamp {
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    const day = @mod(seconds, 86_400);
    return .{
        .hour = @intCast(@divFloor(day, 3_600)),
        .minute = @intCast(@divFloor(@mod(day, 3_600), 60)),
        .second = @intCast(@mod(day, 60)),
        .millisecond = @intCast(@mod(@divFloor(timestamp.nanoseconds, std.time.ns_per_ms), 1_000)),
    };
}

fn levelColor(message_level: std.log.Level) std.Io.Terminal.Color {
    return switch (message_level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    };
}

fn writeRecord(
    terminal: std.Io.Terminal,
    comptime message_level: std.log.Level,
    comptime record_scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    const now = stamp(std.Io.Clock.real.now(std.Options.debug_io));

    terminal.setColor(.dim) catch {};
    try terminal.writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} ", .{
        now.hour,
        now.minute,
        now.second,
        now.millisecond,
    });

    terminal.setColor(levelColor(message_level)) catch {};
    try terminal.writer.writeAll(message_level.asText());
    terminal.setColor(.reset) catch {};

    if (record_scope != .default) {
        try terminal.writer.print(" ({t})", .{record_scope});
    }

    try terminal.writer.writeAll(": ");
    try terminal.writer.print(format ++ "\n", args);
}

test "stamp breaks nanoseconds into a UTC clock" {
    const timestamp = std.Io.Timestamp{
        .nanoseconds = @as(i96, 3_725) * std.time.ns_per_s + 42 * std.time.ns_per_ms,
    };
    const result = stamp(timestamp);
    try std.testing.expectEqual(@as(u8, 1), result.hour);
    try std.testing.expectEqual(@as(u8, 2), result.minute);
    try std.testing.expectEqual(@as(u8, 5), result.second);
    try std.testing.expectEqual(@as(u16, 42), result.millisecond);
}

test "stamp wraps at midnight" {
    const result = stamp(.{ .nanoseconds = 86_400 * std.time.ns_per_s });
    try std.testing.expectEqual(@as(u8, 0), result.hour);
    try std.testing.expectEqual(@as(u8, 0), result.minute);
    try std.testing.expectEqual(@as(u8, 0), result.second);
}

test "record carries level, scope, message and one newline" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const terminal = std.Io.Terminal{ .writer = &writer, .mode = .no_color };

    try writeRecord(terminal, .info, .tecton, "hello {d}", .{7});

    const out = std.Io.Writer.buffered(&writer);
    try std.testing.expect(std.mem.endsWith(u8, out, " info (tecton): hello 7\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\n"));
    try std.testing.expect(out[0] >= '0' and out[0] <= '9');
    try std.testing.expectEqual(@as(u8, ':'), out[2]);
    try std.testing.expectEqual(@as(u8, '.'), out[8]);
}

test "default scope omits the scope tag" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const terminal = std.Io.Terminal{ .writer = &writer, .mode = .no_color };

    try writeRecord(terminal, .warn, .default, "plain", .{});

    try std.testing.expect(std.mem.endsWith(u8, std.Io.Writer.buffered(&writer), " warning: plain\n"));
}

test "runtime level filters messages the build kept" {
    const previous = level();
    defer setLevel(previous);

    setLevel(.warn);
    try std.testing.expect(enabled(.warn));
    try std.testing.expect(!enabled(.info));
    try std.testing.expect(!enabled(.debug));

    setLevel(.err);
    try std.testing.expect(!enabled(.warn));
    try std.testing.expect(enabled(.err));
}

test "record formatting keeps no shared state across threads" {
    const Worker = struct {
        fn run(failures: *std.atomic.Value(bool)) void {
            for (0..64) |i| {
                var buffer: [128]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buffer);
                const terminal = std.Io.Terminal{ .writer = &writer, .mode = .no_color };
                writeRecord(terminal, .debug, .worker, "line {d}", .{i}) catch {
                    failures.store(true, .monotonic);
                    return;
                };
                const out = std.Io.Writer.buffered(&writer);
                if (std.mem.indexOf(u8, out, " debug (worker): line ") == null) {
                    failures.store(true, .monotonic);
                    return;
                }
            }
        }
    };

    var failures = std.atomic.Value(bool).init(false);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&failures});
    }
    for (&threads) |*thread| thread.join();

    try std.testing.expect(!failures.load(.monotonic));
}
