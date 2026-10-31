pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const Compression = scope.Compression;
        const CompressionOptions = scope.CompressionOptions;
        const FloatingText = scope.FloatingText;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;

            const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Hola", Protocol.Vector3f.init(1, 2, 3), 7, 0);
            defer hologram.destroy();

            try std.testing.expectEqualStrings("Hola", hologram.name_tag);

            try hologram.setText("Adios\nLinea 2");

            try std.testing.expectEqualStrings("Adios\nLinea 2", hologram.text);
            try std.testing.expectEqualStrings("Adios\nLinea 2", hologram.name_tag);
            try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.RemoveActor)), hologram.remove_packet[0]);
            try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.AddEntity)), hologram.add_packet[0]);
            try std.testing.expectEqual(@as(usize, 2), hologram.remove_packet.len);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;

            const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Hola", Protocol.Vector3f.init(1, 2, 3), 7, 0);
            defer hologram.destroy();

            try hologram.setText("Adios");

            try std.testing.expect(std.mem.indexOf(u8, hologram.add_packet, "Adios") != null);

            const entries = [_][]const u8{ hologram.remove_packet, hologram.add_packet };
            const options = CompressionOptions{ .compression_method = .Zlib, .compression_threshold = 0 };
            const batch = try Compression.compress(&entries, options, allocator);
            defer allocator.free(batch);

            const result = try Compression.decompress(batch, options, .negotiated, allocator);
            defer result.deinit();

            try std.testing.expectEqual(@as(usize, 2), result.packets.len);
            try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.RemoveActor)), result.packets[0][0]);
            try std.testing.expectEqual(@as(u8, @intCast(Protocol.Packet.AddEntity)), result.packets[1][0]);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;

            const hologram = try FloatingText.create(allocator, undefined, "shop", "", "Uno", Protocol.Vector3f.init(0, 0, 0), 9, 0);
            defer hologram.destroy();

            try hologram.viewers.put(11, {});
            try hologram.viewers.put(22, {});

            try hologram.setText("Dos");
            try hologram.setText("Tres");

            try std.testing.expectEqualStrings("Tres", hologram.name_tag);
            try std.testing.expectEqual(@as(usize, 2), hologram.viewers.count());
        }
    };
}
