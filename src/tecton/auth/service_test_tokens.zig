const std = @import("std");

pub fn tokenWithKeyId(allocator: std.mem.Allocator, kid: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"RS256\",\"kid\":\"{s}\"}}", .{kid});
    defer allocator.free(header);

    const payload = "{}";
    const placeholder_signature = &[_]u8{0} ** 96;
    const token = try allocator.alloc(u8, base64Length(header.len) + 1 + base64Length(payload.len) + 1 + base64Length(placeholder_signature.len));

    var offset: usize = 0;
    offset += encoder.encode(token[offset..], header).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], payload).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], placeholder_signature).len;
    return token[0..offset];
}

fn base64Length(source_len: usize) usize {
    return (4 * source_len + 2) / 3;
}
