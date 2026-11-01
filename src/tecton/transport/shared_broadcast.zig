const std = @import("std");

const connection_mod = @import("connection.zig");
const NetworkHandler = @import("network_handler.zig").NetworkHandler;
const port_mod = @import("port.zig");
const priority_mod = @import("priority.zig");
const SendPriority = priority_mod.SendPriority;
const Compression = @import("./compression/root.zig").Compression;
const PayloadBuffers = @import("./payload_buffers.zig").PayloadBuffers;

/// Packs a packet once and hands the same bytes to every recipient.
pub const SharedBroadcast = struct {
    buffers: *PayloadBuffers,
    buffer: ?[]u8,
    len: usize,
    port: ?port_mod.Port,

    pub fn begin(network: *NetworkHandler, packet: []const u8) !SharedBroadcast {
        const packets = [_][]const u8{packet};
        const capacity = Compression.frameCapacity(&packets, network.options);
        const allocator = network.payload_buffers.allocator();
        const buffer = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buffer);

        const framed = try Compression.compressInto(&packets, network.options, buffer);
        return .{
            .buffers = &network.payload_buffers,
            .buffer = buffer,
            .len = framed.len,
            .port = network.port,
        };
    }

    pub fn bytes(self: *const SharedBroadcast) []const u8 {
        const buffer = self.buffer orelse return &.{};
        return buffer[0..self.len];
    }

    pub fn send(self: *const SharedBroadcast, conn: *connection_mod.Connection, priority: SendPriority) void {
        const port = self.port orelse return;
        const frame = self.bytes();
        if (frame.len == 0) return;
        // One unreachable recipient must not stop the broadcast to the rest.
        port.sendBytes(conn, frame, .reliable, priority) catch |err| {
            std.log.debug("shared broadcast to connection {d} failed: {}", .{ conn.id, err });
        };
    }

    pub fn deinit(self: *SharedBroadcast) void {
        if (self.buffer) |buffer| {
            self.buffers.allocator().free(buffer);
            self.buffer = null;
            self.len = 0;
        }
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const SharedBroadcast = test_owner.SharedBroadcast;
    pub const NetworkHandler = test_owner.NetworkHandler;
    pub const PayloadBuffers = test_owner.PayloadBuffers;
    pub const Compression = test_owner.Compression;
    pub const TransportFake = @import("./fake_port.zig").TransportFake;
    pub const Connection = connection_mod.Connection;
    pub const ConnectionRegistry = connection_mod.ConnectionRegistry;
    pub const events_mod = @import("events.zig");
};

test "a broadcast packs once and frees its buffer idempotently" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_000();
}

test "a broadcast decodes back to the original packet" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_001();
}

test "every recipient receives the same pooled frame through the port" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_002();
}

test "a broadcast without a transport is a silent no-op" {
    try @import("shared_broadcast_test.zig").Suite(test_scope).case_003();
}
