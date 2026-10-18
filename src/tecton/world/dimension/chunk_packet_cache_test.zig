pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const ChunkPacketCache = scope.ChunkPacketCache;

        fn filled(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
            return allocator.dupe(u8, bytes);
        }

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            try std.testing.expectEqual(@as(usize, 0), cache.count());
            try std.testing.expectEqual(@as(usize, 0), cache.bytesHeld());
            try std.testing.expect(cache.get(1, 0) == null);

            cache.put(1, 0, try filled(allocator, "packet-a"));

            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 8), cache.bytesHeld());
            try std.testing.expectEqualStrings("packet-a", cache.get(1, 0).?);
            try std.testing.expectEqual(@as(u64, 0), cache.evictions);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            cache.put(7, 0, try filled(allocator, "stale"));

            try std.testing.expect(cache.get(7, 1) == null);
            try std.testing.expectEqual(@as(usize, 0), cache.count());
            try std.testing.expectEqual(@as(usize, 0), cache.bytesHeld());

            cache.put(7, 1, try filled(allocator, "fresh"));
            try std.testing.expectEqualStrings("fresh", cache.get(7, 1).?);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            cache.put(1, 0, try filled(allocator, "aaaaaaaa"));
            try std.testing.expectEqual(@as(usize, 8), cache.bytesHeld());

            cache.put(1, 0, try filled(allocator, "bb"));

            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 2), cache.bytesHeld());
            try std.testing.expectEqualStrings("bb", cache.get(1, 0).?);
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();
            cache.budget = 12;

            cache.put(1, 0, try filled(allocator, "aaaa"));
            cache.put(2, 0, try filled(allocator, "bbbb"));
            try std.testing.expectEqual(@as(usize, 8), cache.bytesHeld());

            try std.testing.expectEqualStrings("aaaa", cache.get(1, 0).?);

            cache.put(3, 0, try filled(allocator, "cccc"));
            try std.testing.expectEqual(@as(usize, 3), cache.count());
            try std.testing.expectEqual(@as(u64, 0), cache.evictions);

            cache.put(4, 0, try filled(allocator, "dddd"));
            try std.testing.expectEqual(@as(u64, 1), cache.evictions);
            try std.testing.expectEqual(@as(usize, 3), cache.count());
            try std.testing.expectEqual(@as(usize, 12), cache.bytesHeld());

            try std.testing.expect(cache.get(2, 0) == null);
            try std.testing.expect(cache.get(1, 0) != null);
            try std.testing.expect(cache.get(3, 0) != null);
            try std.testing.expect(cache.get(4, 0) != null);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();
            cache.budget = 4;

            cache.put(1, 0, try filled(allocator, "0123456789"));
            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 10), cache.bytesHeld());
            try std.testing.expectEqual(@as(u64, 0), cache.evictions);

            cache.put(2, 0, try filled(allocator, "xy"));
            try std.testing.expectEqual(@as(u64, 1), cache.evictions);
            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 2), cache.bytesHeld());
            try std.testing.expect(cache.get(1, 0) == null);
            try std.testing.expectEqualStrings("xy", cache.get(2, 0).?);
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            const packet = try filled(allocator, "same-buffer");
            cache.put(5, 1, packet);
            cache.put(5, 2, packet);

            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 11), cache.bytesHeld());
            try std.testing.expectEqualStrings("same-buffer", cache.get(5, 2).?);

            try std.testing.expect(cache.get(5, 1) == null);
            try std.testing.expectEqual(@as(usize, 0), cache.count());
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            var cache = ChunkPacketCache.init(allocator);
            defer cache.deinit();

            cache.put(1, 0, try filled(allocator, "one"));
            cache.put(2, 0, try filled(allocator, "two"));

            cache.remove(1);
            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 3), cache.bytesHeld());
            try std.testing.expect(cache.get(1, 0) == null);
            try std.testing.expectEqualStrings("two", cache.get(2, 0).?);

            cache.remove(1);
            try std.testing.expectEqual(@as(usize, 1), cache.count());
            try std.testing.expectEqual(@as(usize, 3), cache.bytesHeld());
        }
    };
}
