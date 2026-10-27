const FrameBuffers = @import("./frame_buffers.zig").FrameBuffers;

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
            return sendPacketsFramed(self, conn, &packets, .{ .compression_method = .NotPresent, .compression_threshold = 255 }, .normal);
        }

        pub fn sendPacket(self: *NetworkHandler, conn: *Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .normal);
        }

        pub fn sendPacketWith(self: *NetworkHandler, conn: *Connection, packet: []const u8, priority: SendPriority) !void {
            const packets = [_][]const u8{packet};
            return sendPacketsFramed(self, conn, &packets, self.options, priority);
        }

        pub fn sendImmediate(self: *NetworkHandler, conn: *Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .immediate);
        }

        pub fn sendPackets(self: *NetworkHandler, conn: *Connection, packets: []const []const u8) !void {
            return self.sendPacketsWith(conn, packets, .normal);
        }

        pub fn sendPacketsWith(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, priority: SendPriority) !void {
            return sendPacketsFramed(self, conn, packets, self.options, priority);
        }

        pub fn sendPacketsUncompressed(self: *NetworkHandler, conn: *Connection, packets: []const []const u8) !void {
            return self.sendPacketsUncompressedWith(conn, packets, .normal);
        }

        pub fn sendPacketsUncompressedWith(self: *NetworkHandler, conn: *Connection, packets: []const []const u8, priority: SendPriority) !void {
            var options = self.options;
            options.compression_threshold = std.math.maxInt(u16);
            return sendPacketsFramed(self, conn, packets, options, priority);
        }

        /// Delivers bytes that are already one Bedrock frame, as the chunk cache keeps them.
        pub fn sendFramed(self: *NetworkHandler, conn: *Connection, framed: []const u8, priority: SendPriority) !void {
            const port = self.port orelse return error.Closed;
            return port.sendBytes(conn, framed, priority);
        }

        fn sendPacketsFramed(
            self: *NetworkHandler,
            conn: *Connection,
            packets: []const []const u8,
            options: CompressionOptions,
            priority: SendPriority,
        ) !void {
            const port = self.port orelse return error.Closed;
            const capacity = Compression.frameCapacity(packets, options);

            if (self.frame_buffers) |frame_buffers| {
                if (capacity <= FrameBuffers.slot_size) {
                    const buffers = frame_buffers.allocator();
                    const buffer = try buffers.alloc(u8, capacity);
                    const framed = Compression.compressInto(packets, options, buffer) catch |err| {
                        buffers.free(buffer);
                        return err;
                    };
                    defer buffers.free(buffer);
                    return port.sendBytes(conn, framed, priority);
                }
            }

            const framed = try Compression.compress(packets, options, self.allocator);
            defer self.allocator.free(framed);
            return port.sendBytes(conn, framed, priority);
        }
    };
}
