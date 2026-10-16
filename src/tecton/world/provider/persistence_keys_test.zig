pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const allocator = std.testing.allocator;
        const Key = scope.Key;
        const chunkKey = scope.chunkKey;
        const Put = scope.Put;
        const Record = scope.Record;

        pub fn case_keys_000() !void {
            const key = chunkKey(.entities, -1, 5, -7);
            try std.testing.expectEqual(@as(u8, 255), key.dim);
            try std.testing.expectEqual(@as(i32, 5), key.x);
            try std.testing.expectEqual(@as(i32, -7), key.z);
            const plain: Key = .{ .kind = .subchunks };
            try std.testing.expectEqual(@as(u8, 0), plain.dim);
            try std.testing.expectEqual(@sizeOf([]u8) * 2, @sizeOf(Put));
        }

        pub fn case_keys_001() !void {
            var record = Record{};
            try std.testing.expect(record.isEmpty());
            try std.testing.expectEqual(@as(usize, 0), record.bytes);
            try record.addPut(allocator, "k1", "v12");
            try record.addDelete(allocator, "k2");
            try std.testing.expect(!record.isEmpty());
            try std.testing.expectEqual(@as(usize, 1), record.puts.items.len);
            try std.testing.expectEqual(@as(usize, 1), record.deletes.items.len);
            try std.testing.expectEqual(@as(usize, 2 + 3 + 2), record.bytes);
            try std.testing.expectEqualStrings("k1", record.puts.items[0].key);
            try std.testing.expectEqualStrings("v12", record.puts.items[0].value);
            record.deinit(allocator);
            try std.testing.expect(record.isEmpty());
            try std.testing.expectEqual(@as(usize, 0), record.bytes);
        }
    };
}
