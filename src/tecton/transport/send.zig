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
            const options = CompressionOptions{ .compression_method = .NotPresent, .compression_threshold = 255 };
            const compressed = try Compression.compress(&packets, options, self.allocator);
            defer self.allocator.free(compressed);
            deliver(conn, compressed, .normal);
        }

        pub fn sendPacket(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .normal);
        }

        pub fn sendPacketWith(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8, priority: SendPriority) !void {
            const packets = [_][]const u8{packet};
            const compressed = try Compression.compress(&packets, self.options, self.allocator);
            defer self.allocator.free(compressed);
            deliver(conn, compressed, priority);
        }

        pub fn sendImmediate(self: *NetworkHandler, conn: *Raknet.Connection, packet: []const u8) !void {
            return self.sendPacketWith(conn, packet, .immediate);
        }

        pub fn sendPackets(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
            return self.sendPacketsWith(conn, packets, .normal);
        }

        pub fn sendPacketsWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
            const compressed = try Compression.compress(packets, self.options, self.allocator);
            defer self.allocator.free(compressed);
            deliver(conn, compressed, priority);
        }

        pub fn sendPacketsUncompressed(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) !void {
            return self.sendPacketsUncompressedWith(conn, packets, .normal);
        }

        pub fn sendPacketsUncompressedWith(self: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8, priority: SendPriority) !void {
            var options = self.options;
            options.compression_threshold = std.math.maxInt(u16);
            const compressed = try Compression.compress(packets, options, self.allocator);
            defer self.allocator.free(compressed);
            deliver(conn, compressed, priority);
        }

        fn deliver(conn: *Raknet.Connection, bytes: []const u8, priority: SendPriority) void {
            conn.sendReliableMessage(bytes, switch (priority) {
                .normal => .Normal,
                .immediate => .Immediate,
            });
        }
    };
}
