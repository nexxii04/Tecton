const std = @import("std");
const Raknet = @import("Raknet");

const priority_mod = @import("./priority.zig");
const SendPriority = priority_mod.SendPriority;
const Compression = @import("./compression/root.zig").Compression;
const CompressionOptions = @import("./compression/options.zig").CompressionOptions;

/// Compresses once for a 1-to-many broadcast; the broadcast owns the buffer until `deinit`.
pub const SharedBroadcast = struct {
    bytes: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn begin(
        allocator: std.mem.Allocator,
        packet: []const u8,
        options: CompressionOptions,
    ) !SharedBroadcast {
        const packets = [_][]const u8{packet};
        const compressed = try Compression.compress(&packets, options, allocator);
        return .{ .bytes = compressed, .allocator = allocator };
    }

    pub fn send(self: *const SharedBroadcast, conn: *Raknet.Connection, priority: SendPriority) void {
        conn.sendReliableMessage(self.bytes.?, switch (priority) {
            .normal => .Normal,
            .immediate => .Immediate,
        });
    }

    /// Safe to call twice.
    pub fn deinit(self: *SharedBroadcast) void {
        if (self.bytes) |bytes| {
            self.bytes = null;
            self.allocator.free(bytes);
        }
    }
};

test "a broadcast packs once and frees its buffer idempotently" {
    const allocator = std.testing.allocator;
    const packet = "a packet that will be broadcast";

    var broadcast = try SharedBroadcast.begin(allocator, packet, .{
        .compression_method = .Zlib,
        .compression_threshold = 255,
    });
    try std.testing.expect(broadcast.bytes != null);
    broadcast.deinit();
    broadcast.deinit();
}

test "a broadcast decodes back to the original packet" {
    const allocator = std.testing.allocator;
    const packet = "broadcast payload that repeats across every recipient";

    var broadcast = try SharedBroadcast.begin(allocator, packet, .{
        .compression_method = .Zlib,
        .compression_threshold = 1,
    });
    defer broadcast.deinit();

    const decompressed = try Compression.decompress(broadcast.bytes.?, .{
        .compression_method = .Zlib,
        .compression_threshold = 255,
    }, allocator);
    defer decompressed.deinit();
    try std.testing.expectEqual(@as(usize, 1), decompressed.packets.len);
    try std.testing.expectEqualStrings(packet, decompressed.packets[0]);
}
