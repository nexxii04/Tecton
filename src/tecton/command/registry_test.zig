pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const CommandRegistry = scope.CommandRegistry;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;

            var registry = CommandRegistry.init(allocator);
            defer registry.deinit();

            const initial = try allocator.alloc([]const u8, 1);
            initial[0] = "world";
            const enum_index = try registry.registerEnum(.{
                .name = "TransferWorld",
                .values = initial,
                .owned = true,
            });
            try std.testing.expectEqual(@as(u32, 0), enum_index);

            const updated = try allocator.alloc([]const u8, 2);
            updated[0] = "world";
            updated[1] = "arena";

            try std.testing.expect(try registry.updateEnumValues("TransferWorld", updated));

            try std.testing.expectEqual(@as(usize, 1), registry.enums.items.len);
            try std.testing.expectEqual(@as(usize, 2), registry.enums.items[0].values.len);
            try std.testing.expectEqualStrings("arena", registry.enums.items[0].values[1]);
            try std.testing.expect(registry.enums.items[0].owned);

            const orphaned = try allocator.alloc([]const u8, 1);
            orphaned[0] = "x";
            try std.testing.expect(!(try registry.updateEnumValues("MissingEnum", orphaned)));
            allocator.free(orphaned);
        }
    };
}
