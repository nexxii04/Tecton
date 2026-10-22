const std = @import("std");
const Raknet = @import("Raknet");

const priority_mod = @import("./priority.zig");
const SendPriority = priority_mod.SendPriority;
const Compression = @import("./compression/root.zig").Compression;
const CompressionOptions = @import("./compression/options.zig").CompressionOptions;
const PayloadBuffers = @import("./payload_buffers.zig").PayloadBuffers;

pub const SharedBroadcast = struct {
    bytes: ?[]const u8 = null,
    shared: ?*Raknet.SharedPayload = null,

    pub fn begin(
        buffers: *PayloadBuffers,
        packet: []const u8,
        options: CompressionOptions,
    ) !SharedBroadcast {
        const packets = [_][]const u8{packet};
        const capacity = Compression.frameCapacity(&packets, options);
        const allocator = buffers.allocator();
        const buffer = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buffer);

        const framed = try Compression.compressInto(&packets, options, buffer);
        const shared = try Raknet.SharedPayload.create(allocator, buffer[0..framed.len]);
        return .{ .bytes = shared.bytes, .shared = shared };
    }

    pub fn send(self: *const SharedBroadcast, conn: *Raknet.Connection, priority: SendPriority) void {
        const shared = self.shared orelse return;
        if (shared.bytes.len <= maxFramePayload(conn)) {
            conn.sendReliableMessageShared(shared, switch (priority) {
                .normal => .Normal,
                .immediate => .Immediate,
            });
            return;
        }
        conn.sendReliableMessage(shared.bytes, switch (priority) {
            .normal => .Normal,
            .immediate => .Immediate,
        });
    }

    pub fn deinit(self: *SharedBroadcast) void {
        if (self.shared) |shared| {
            self.bytes = null;
            self.shared = null;
            shared.release();
        }
    }
};

fn maxFramePayload(conn: *Raknet.Connection) usize {
    return if (conn.mtu_size > 36) conn.mtu_size - 36 else 0;
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Raknet = test_owner.Raknet;
    pub const SharedBroadcast = test_owner.SharedBroadcast;
    pub const PayloadBuffers = test_owner.PayloadBuffers;
    pub const Compression = test_owner.Compression;
    pub const maxFramePayload = test_owner.maxFramePayload;
};

test "a broadcast packs once and frees its buffer idempotently" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_000();
}

test "a broadcast decodes back to the original packet" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_001();
}

test "every recipient frames the same pooled payload without allocating" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_002();
}

test "oversize broadcasts fall back to the copying send path" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_003();
}
