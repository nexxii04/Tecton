const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const Protocol = @import("protocol");

const NetworkHandler = @import("../network/network-handler.zig").NetworkHandler;
const Player = @import("../player/player.zig").Player;
const Tecton = @import("../tecton.zig").Tecton;

pub const CommandContext = struct {
    player: ?*Player = null,
    args: []const u8,
    network: *NetworkHandler,
    tecton: *Tecton,
    allocator: std.mem.Allocator,
    command_userdata: ?*anyopaque = null,

    origin_type: []const u8 = "player",
    uuid: [16]u8 = .{0} ** 16,
    request_id: []const u8 = "",

    single_target_buf: [1]*Player = undefined,
    multi_target_buf: std.ArrayList(*Player) = .empty,

    pub fn deinit(self: *CommandContext) void {
        self.multi_target_buf.deinit(self.allocator);
    }

    pub fn sendOutput(self: *CommandContext, success: bool, message: []const u8) void {
        const player = self.player orelse {
            printMcToConsole(message);
            return;
        };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const msgs = [_]Protocol.CommandOutputMessage{
            .{ .success = success, .message = message, .parameters = &.{} },
        };

        var output = Protocol.CommandOutputPacket{
            .origin_type = self.origin_type,
            .uuid = self.uuid,
            .request_id = self.request_id,
            .player_unique_id = player.entity.runtime_id,
            .output_type = "alloutput",
            .success_count = if (success) 1 else 0,
            .messages = &msgs,
        };

        const serialized = output.serialize(&stream) catch return;
        self.network.sendPacket(player.connection, serialized) catch {};
    }

    pub fn resolvePlayer(self: *CommandContext, name: []const u8) ?*Player {
        if (name.len > 0 and name[0] == '@') return self.resolveSelector(name);
        const snapshots = self.tecton.getPlayerSnapshots();
        for (snapshots) |player| {
            if (std.ascii.eqlIgnoreCase(player.username, name)) return player;
        }
        return null;
    }

    pub fn resolvePlayers(self: *CommandContext, name: []const u8) ?[]const *Player {
        if (name.len >= 2 and name[0] == '@') {
            const kind = name[1];
            if (kind == 'a' or kind == 'e') {
                const snapshots = self.tecton.getPlayerSnapshots();
                if (snapshots.len == 0) return null;
                self.multi_target_buf.clearRetainingCapacity();
                self.multi_target_buf.appendSlice(self.allocator, snapshots) catch return null;
                return self.multi_target_buf.items;
            }
        }
        const single = self.resolvePlayer(name) orelse return null;
        self.single_target_buf = .{single};
        return &self.single_target_buf;
    }

    pub fn resolveSelector(self: *CommandContext, selector: []const u8) ?*Player {
        if (selector.len < 2 or selector[0] != '@') return null;
        const kind = selector[1];
        return switch (kind) {
            's' => self.player,
            'p' => if (self.player) |p| self.nearestPlayer(p) else null,
            'r' => self.randomPlayer(),
            'a', 'e' => self.player,
            else => null,
        };
    }

    fn nearestPlayer(self: *CommandContext, origin: *Player) ?*Player {
        const snapshots = self.tecton.getPlayerSnapshots();
        var best: ?*Player = null;
        var best_dist: f32 = std.math.inf(f32);
        for (snapshots) |player| {
            if (!player.spawned) continue;
            const dist = origin.entity.position.distance(player.entity.position);
            if (dist < best_dist) {
                best_dist = dist;
                best = player;
            }
        }
        return best;
    }

    fn randomPlayer(self: *CommandContext) ?*Player {
        const snapshots = self.tecton.getPlayerSnapshots();
        if (snapshots.len == 0) return null;
        var spawned_count: usize = 0;
        for (snapshots) |p| {
            if (p.spawned) spawned_count += 1;
        }
        if (spawned_count == 0) return null;
        const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(self.tecton.io, .real).nanoseconds)));
        const idx = seed % spawned_count;
        var i: usize = 0;
        for (snapshots) |p| {
            if (!p.spawned) continue;
            if (i == idx) return p;
            i += 1;
        }
        return snapshots[0];
    }

    pub fn parseCoord(str: []const u8, current: f32) ?f32 {
        if (str.len == 0) return null;
        if (str[0] == '~') {
            if (str.len == 1) return current;
            const offset = std.fmt.parseFloat(f32, str[1..]) catch return null;
            return current + offset;
        }
        return std.fmt.parseFloat(f32, str) catch null;
    }
};

fn printMcToConsole(message: []const u8) void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < message.len and len < buf.len) {
        if (i + 1 < message.len and message[i] == '\xc2' and message[i + 1] == '\xa7') {
            i += 2;
            if (i < message.len) {
                const ansi = mcCodeToAnsi(message[i]);
                i += 1;
                if (ansi.len > 0 and len + ansi.len <= buf.len) {
                    @memcpy(buf[len..][0..ansi.len], ansi);
                    len += ansi.len;
                }
            }
        } else {
            if (len < buf.len) {
                buf[len] = message[i];
                len += 1;
            }
            i += 1;
        }
    }
    if (len + 5 <= buf.len) {
        @memcpy(buf[len..][0..5], "\x1b[0m\n");
        len += 5;
    }
    std.debug.print("{s}", .{buf[0..len]});
}

fn mcCodeToAnsi(code: u8) []const u8 {
    return switch (code) {
        '0' => "\x1b[30m",
        '1' => "\x1b[34m",
        '2' => "\x1b[32m",
        '3' => "\x1b[36m",
        '4' => "\x1b[31m",
        '5' => "\x1b[35m",
        '6' => "\x1b[33m",
        '7' => "\x1b[37m",
        '8' => "\x1b[90m",
        '9' => "\x1b[94m",
        'a' => "\x1b[92m",
        'b' => "\x1b[96m",
        'c' => "\x1b[91m",
        'd' => "\x1b[95m",
        'e' => "\x1b[93m",
        'f' => "\x1b[97m",
        'l' => "\x1b[1m",
        'r' => "\x1b[0m",
        else => "",
    };
}
