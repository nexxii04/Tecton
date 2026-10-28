/// Smallest frames (control replies, keepalives) are built in this per-thread scratch,
/// so the common send never touches the pool and never contends for a slot.
const inline_frame_size: usize = 4096;
threadlocal var tl_frame: [inline_frame_size]u8 = undefined;

pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Connection = scope.Connection;
        const NetworkHandler = scope.NetworkHandler;
        const CompressionOptions = scope.CompressionOptions;
        const Compression = scope.Compression;
        const SendPriority = scope.SendPriority;

        pub fn sendUncompressedPacket(self: *NetworkHandler, conn: *Connection, packet: []const u8) !void {
            const packets = [_][]const u8{packet};
            return sendPacketsFramed(self, conn, &packets, .{ .compression_method = .NotPresent, .compression_threshold = 255 }, .reliable, .normal);
        }

        pub fn sendPacket(self: *NetworkHandler, conn: *Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .normal);
        }

        pub fn sendPacketWith(self: *NetworkHandler, conn: *Connection, packet: []const u8, priority: SendPriority) !void {
            const packets = [_][]const u8{packet};
            return sendPacketsFramed(self, conn, &packets, self.options, .reliable, priority);
        }

        pub fn sendImmediate(self: *NetworkHandler, conn: *Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .immediate);
        }

        pub fn sendPackets(self: *NetworkHandler, conn: *Connection, packets: []const []const u8) !void {
            return self.sendPacketsWith(conn, packets, .normal);
        }

        pub fn sendPacketsWith(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, priority: SendPriority) !void {
            return sendPacketsOn(self, conn, packets, .reliable, priority);
        }

        pub fn sendPacketsUncompressed(self: *NetworkHandler, conn: *Connection, packets: []const []const u8) !void {
            return self.sendPacketsUncompressedWith(conn, packets, .normal);
        }

        pub fn sendPacketsUncompressedWith(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, priority: SendPriority) !void {
            return sendPacketsUncompressedOn(self, conn, packets, .reliable, priority);
        }

        pub fn sendPacketsOn(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, channel: scope.Channel, priority: SendPriority) !void {
            return sendPacketsFramed(self, conn, packets, self.options, channel, priority);
        }

        pub fn sendPacketsUncompressedOn(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, channel: scope.Channel, priority: SendPriority) !void {
            var options = self.options;
            options.compression_threshold = std.math.maxInt(u16);
            return sendPacketsFramed(self, conn, packets, options, channel, priority);
        }

        fn recordOutboundDrop(self: *NetworkHandler) void {
            _ = self.outbound_dropped.fetchAdd(1, .monotonic);
        }

        /// Delivers bytes that are already one Bedrock frame, as the chunk cache keeps them.
        pub fn sendFramed(self: *NetworkHandler, conn: *Connection, framed: []const u8, priority: SendPriority) !void {
            const port = self.port orelse {
                recordOutboundDrop(self);
                return error.Closed;
            };
            if (framed.len == 0) return;

            const max_payload = port.maxPayload(conn);
            if (max_payload == 0) {
                recordOutboundDrop(self);
                return error.Closed;
            }
            // A single frame cannot be split without breaking its own framing.
            if (framed.len > max_payload) {
                _ = self.oversize_sends.fetchAdd(1, .monotonic);
                recordOutboundDrop(self);
                scope.log.debug("dropping a {d}-byte frame for connection {d}: the transport allows {d}", .{ framed.len, conn.id, max_payload });
                return error.PayloadTooLarge;
            }
            return sendThroughPort(self, port, conn, framed, .reliable, priority);
        }

        fn sendPacketsFramed(
            self: *NetworkHandler,
            conn: *Connection,
            packets: []const []const u8,
            options: CompressionOptions,
            channel: scope.Channel,
            priority: SendPriority,
        ) !void {
            const port = self.port orelse {
                recordOutboundDrop(self);
                return error.Closed;
            };
            const max_payload = port.maxPayload(conn);
            if (max_payload == 0) {
                recordOutboundDrop(self);
                return error.Closed;
            }

            // `frameCapacity` is an upper bound, so a frame that fits by it fits for real.
            const capacity = Compression.frameCapacity(packets, options);
            if (capacity <= max_payload) {
                if (capacity <= inline_frame_size) {
                    return sendFrame(self, port, conn, packets, options, channel, priority, &tl_frame);
                }
                if (capacity <= self.send_buffers.slotSize()) {
                    const buffer = self.send_buffers.acquire() orelse {
                        _ = self.backpressure_sends.fetchAdd(1, .monotonic);
                        return error.Backpressure;
                    };
                    defer self.send_buffers.release(buffer);
                    return sendFrame(self, port, conn, packets, options, channel, priority, buffer);
                }
            }

            // Halving keeps the order and bounds the recursion: each half is sent before the
            // next one, so the client sees the same packet sequence.
            if (packets.len < 2) {
                _ = self.oversize_sends.fetchAdd(1, .monotonic);
                recordOutboundDrop(self);
                scope.log.debug("dropping a {d}-byte message for connection {d}: the transport allows {d}", .{ capacity, conn.id, max_payload });
                return error.PayloadTooLarge;
            }
            const half = packets.len / 2;
            try sendPacketsFramed(self, conn, packets[0..half], options, channel, priority);
            try sendPacketsFramed(self, conn, packets[half..], options, channel, priority);
        }

        fn sendFrame(
            self: *NetworkHandler,
            port: scope.Port,
            conn: *Connection,
            packets: []const []const u8,
            options: CompressionOptions,
            channel: scope.Channel,
            priority: SendPriority,
            buffer: []u8,
        ) !void {
            const framed = Compression.compressInto(packets, options, buffer) catch |err| switch (err) {
                error.CompressionBufferTooSmall => {
                    _ = self.oversize_sends.fetchAdd(1, .monotonic);
                    recordOutboundDrop(self);
                    return error.PayloadTooLarge;
                },
                else => return err,
            };
            return sendThroughPort(self, port, conn, framed, channel, priority);
        }

        /// Splitting a compressed frame would break its framing, so only the reliable path
        /// gets the fixed limit the port negotiates.
        fn sendThroughPort(
            self: *NetworkHandler,
            port: scope.Port,
            conn: *Connection,
            framed: []const u8,
            channel: scope.Channel,
            priority: SendPriority,
        ) !void {
            const max_payload = port.maxPayload(conn);
            if (max_payload == 0) {
                recordOutboundDrop(self);
                return error.Closed;
            }
            if (channel == .unreliable and framed.len > max_payload) {
                _ = self.oversize_sends.fetchAdd(1, .monotonic);
                recordOutboundDrop(self);
                return error.PayloadTooLarge;
            }
            port.sendBytes(conn, framed, channel, priority) catch |err| {
                switch (err) {
                    error.Backpressure => _ = self.backpressure_sends.fetchAdd(1, .monotonic),
                    error.Closed, error.UnknownConnection, error.PayloadTooLarge => recordOutboundDrop(self),
                }
                return err;
            };
        }
    };
}
