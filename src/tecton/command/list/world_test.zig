pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const isValidWorldName = scope.isValidWorldName;

        pub fn case_000() !void {
            try std.testing.expect(isValidWorldName("world"));
            try std.testing.expect(isValidWorldName("World_2-test"));
            try std.testing.expect(isValidWorldName("a"));
            try std.testing.expect(isValidWorldName("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"));

            try std.testing.expect(!isValidWorldName(""));
            try std.testing.expect(!isValidWorldName("."));
            try std.testing.expect(!isValidWorldName(".."));
            try std.testing.expect(!isValidWorldName("../etc"));
            try std.testing.expect(!isValidWorldName("a/b"));
            try std.testing.expect(!isValidWorldName("a b"));
            try std.testing.expect(!isValidWorldName("world!"));
            try std.testing.expect(!isValidWorldName("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"));
        }
    };
}
