const FrameBuffers = @import("./frame_buffers.zig").FrameBuffers;

pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Raknet = scope.Raknet;
        const NetworkHandler = scope.NetworkHandler;
        const CompressionOptions = scope.CompressionOptions;
        const Compression = scope.Compression;
        const SendPriority = scope.SendPriority;

        pub fn sendUncompressedPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
            const packets = [_][]const u8{packet};
            return sendFramed(self, conn, &packets, .{ .compression_method = .NotPresent, .compression_threshold = 255 }, .normal);
        }

        pub fn sendPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .normal);
        }

        pub fn sendPacketWith(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8, priority: SendPriority) !void {
            const packets = [_][]const u8{packet};
            return sendFramed(self, conn, &packets, self.options, priority);
        }

        pub fn sendImmediate(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .immediate);
        }

        pub fn sendPackets(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
            return self.sendPacketsWith(conn, packets, .normal);
        }

        pub fn sendPacketsWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
            return sendFramed(self, conn, packets, self.options, priority);
        }

        pub fn sendPacketsUncompressed(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
            return self.sendPacketsUncompressedWith(conn, packets, .normal);
        }

        pub fn sendPacketsUncompressedWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
            if (priority == .immediate and self.options.compression_method != .NotPresent) {
                conn.sendPacketBatch(packets, switch (priority) {
                    .normal => .Normal,
                    .immediate => .Immediate,
                });
                return;
            }
            var options = self.options;
            options.compression_threshold = std.math.maxInt(u16);
            return sendFramed(self, conn, packets, options, priority);
        }

        fn sendFramed(
            self: *NetworkHandler,
            conn: *Raknet.Connection,
            packets: []const []const u8,
            options: CompressionOptions,
            priority: SendPriority,
        ) !void {
            const capacity = Compression.frameCapacity(packets, options);
            if (self.frame_buffers) |frame_buffers| {
                if (capacity <= FrameBuffers.slot_size and capacity <= maxFramePayload(conn)) {
                    const buffers = frame_buffers.allocator();
                    const buffer = try buffers.alloc(u8, capacity);
                    const framed = Compression.compressInto(packets, options, buffer) catch |err| {
                        buffers.free(buffer);
                        return err;
                    };

                    const frame = Raknet.Proto.Frame.init(null, null, null, 0, .ReliableOrdered, framed, null, null, null, buffers);
                    conn.sendFrame(frame, switch (priority) {
                        .normal => .Normal,
                        .immediate => .Immediate,
                    });
                    return;
                }
            }

            const framed = try Compression.compress(packets, options, self.allocator);
            deliverOwned(self, conn, framed, priority);
        }

        fn maxFramePayload(conn: *Raknet.Connection) usize {
            return if (conn.mtu_size > 36) conn.mtu_size - 36 else 0;
        }

        fn deliverOwned(self: *NetworkHandler, conn: *Raknet.Connection, bytes: []const u8, priority: SendPriority) void {
            const transport_allocator = conn.server.options.allocator;
            if (self.allocator.ptr != transport_allocator.ptr or self.allocator.vtable != transport_allocator.vtable) {
                defer self.allocator.free(bytes);
                conn.sendReliableMessage(bytes, switch (priority) {
                    .normal => .Normal,
                    .immediate => .Immediate,
                });
                return;
            }
            conn.sendReliableMessageOwned(bytes, switch (priority) {
                .normal => .Normal,
                .immediate => .Immediate,
            });
        }
    };
}
