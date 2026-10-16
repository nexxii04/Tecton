const std = @import("std");

pub const max_display_name_length = 16;

pub const Error = error{
    EmptyDisplayName,
    DisplayNameTooLong,
    DisplayNameHasControlCharacters,
    DisplayNameHasEdgeWhitespace,
};

pub fn validateDisplayName(display_name: []const u8) Error!void {
    if (display_name.len == 0) return error.EmptyDisplayName;
    if (display_name.len > max_display_name_length) return error.DisplayNameTooLong;

    for (display_name) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.DisplayNameHasControlCharacters;
    }

    if (std.ascii.isWhitespace(display_name[0]) or
        std.ascii.isWhitespace(display_name[display_name.len - 1]))
    {
        return error.DisplayNameHasEdgeWhitespace;
    }
}

pub fn uuidForDisplayName(allocator: std.mem.Allocator, display_name: []const u8) ![]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});

    md5.update("tecton-offline:");
    md5.update(display_name);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var out_idx: usize = 0;
    for (digest, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[out_idx] = '-';
            out_idx += 1;
        }
        out[out_idx] = hex[byte >> 4];
        out[out_idx + 1] = hex[byte & 0x0f];
        out_idx += 2;
    }

    return allocator.dupe(u8, &out);
}

const testing = std.testing;

test "valid display names pass" {
    try validateDisplayName("Steve");
    try validateDisplayName("TestBot0000");
    try validateDisplayName("a");
    try validateDisplayName("name with space");
    try validateDisplayName("x" ** max_display_name_length);
}

test "display names that would confuse the server are refused" {
    try testing.expectError(error.EmptyDisplayName, validateDisplayName(""));
    try testing.expectError(error.DisplayNameTooLong, validateDisplayName("x" ** (max_display_name_length + 1)));
    try testing.expectError(error.DisplayNameHasControlCharacters, validateDisplayName("bad\nname"));
    try testing.expectError(error.DisplayNameHasControlCharacters, validateDisplayName("ansi\x1b[31m"));
    try testing.expectError(error.DisplayNameHasControlCharacters, validateDisplayName("null\x00byte"));
    try testing.expectError(error.DisplayNameHasEdgeWhitespace, validateDisplayName(" leading"));
    try testing.expectError(error.DisplayNameHasEdgeWhitespace, validateDisplayName("trailing "));
}

test "the uuid is stable per name and different across names" {
    const allocator = testing.allocator;

    const first = try uuidForDisplayName(allocator, "Steve");
    defer allocator.free(first);
    const again = try uuidForDisplayName(allocator, "Steve");
    defer allocator.free(again);
    const other = try uuidForDisplayName(allocator, "Alex");
    defer allocator.free(other);

    try testing.expectEqual(@as(usize, 36), first.len);
    try testing.expectEqualStrings(first, again);
    try testing.expect(!std.mem.eql(u8, first, other));
    try testing.expectEqual(@as(u8, '3'), first[14]);
    try testing.expect(first[19] == '8' or first[19] == '9' or first[19] == 'a' or first[19] == 'b');
}
