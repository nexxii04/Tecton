const std = @import("std");

/// `immediate` flushes on the current tick; `normal` waits for the next connection tick.
pub const SendPriority = enum {
    normal,
    immediate,

    pub fn parse(value: []const u8) ?SendPriority {
        if (std.mem.eql(u8, value, "normal")) return .normal;
        if (std.mem.eql(u8, value, "immediate")) return .immediate;
        return null;
    }

    pub fn label(self: SendPriority) []const u8 {
        return switch (self) {
            .normal => "normal",
            .immediate => "immediate",
        };
    }
};

test "send priority parses both values and nothing else" {
    try std.testing.expectEqual(SendPriority.normal, SendPriority.parse("normal").?);
    try std.testing.expectEqual(SendPriority.immediate, SendPriority.parse("immediate").?);
    try std.testing.expect(SendPriority.parse("Normal") == null);
    try std.testing.expect(SendPriority.parse("") == null);
    try std.testing.expect(SendPriority.parse("asap") == null);
    try std.testing.expectEqualStrings("normal", SendPriority.normal.label());
    try std.testing.expectEqualStrings("immediate", SendPriority.immediate.label());
}
