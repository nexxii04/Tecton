const std = @import("std");

const signature = @import("signature.zig");

pub const Error = error{
    MissingXuid,
    InvalidXuid,
    EmptyDisplayName,
    DisplayNameTooLong,
    DisplayNameHasEdgeWhitespace,
    DisplayNameStartsWithDigit,
    DisplayNameHasInvalidCharacters,
    DisplayNameHasRepeatedSpaces,
    InvalidUuid,
    OutOfMemory,
};

pub const Source = enum { multiplayer_token, legacy_chain };

pub const Claims = struct {
    xuid: []const u8,
    display_name: []const u8,
    claimed_uuid: []const u8,
    title_id: []const u8,
    source: Source,
    require_xuid: bool,
};

pub const Identity = struct {
    xuid: []const u8,
    display_name: []const u8,
    uuid: []const u8,
    title_id: []const u8,
    source: Source,

    pub fn deinit(self: *Identity, allocator: std.mem.Allocator) void {
        allocator.free(self.xuid);
        allocator.free(self.display_name);
        allocator.free(self.uuid);
        allocator.free(self.title_id);
        self.* = undefined;
    }
};

pub const Verified = struct {
    identity: Identity,
    client_public_key: signature.Secp384PublicKey,

    pub fn deinit(self: *Verified, allocator: std.mem.Allocator) void {
        self.identity.deinit(allocator);
    }
};

/// An authenticated uuid derives from the xuid: `leguuid` is set by self-signed
/// offline logins and would let them pick someone else's saved data.
pub fn build(allocator: std.mem.Allocator, claims: Claims) Error!Identity {
    var uuid: []const u8 = undefined;
    if (claims.xuid.len == 0) {
        if (claims.require_xuid) return error.MissingXuid;
        try validateUuid(claims.claimed_uuid);
        uuid = try allocator.dupe(u8, claims.claimed_uuid);
    } else {
        try validateXuid(claims.xuid);
        uuid = try uuidFromXuid(allocator, claims.xuid);
    }
    errdefer allocator.free(uuid);

    try validateDisplayName(claims.display_name);

    const xuid = try allocator.dupe(u8, claims.xuid);
    errdefer allocator.free(xuid);
    const display_name = try allocator.dupe(u8, claims.display_name);
    errdefer allocator.free(display_name);
    const title_id = try allocator.dupe(u8, claims.title_id);
    errdefer allocator.free(title_id);

    return .{
        .xuid = xuid,
        .display_name = display_name,
        .uuid = uuid,
        .title_id = title_id,
        .source = claims.source,
    };
}

pub fn validateDisplayName(name: []const u8) Error!void {
    if (name.len == 0) return error.EmptyDisplayName;
    if (name.len > 15) return error.DisplayNameTooLong;
    if (name[0] == ' ' or name[name.len - 1] == ' ') return error.DisplayNameHasEdgeWhitespace;
    if (name[0] >= '0' and name[0] <= '9') return error.DisplayNameStartsWithDigit;

    for (name, 0..) |byte, index| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9' => {},
            ' ' => if (index == 0 or name[index - 1] == ' ') return error.DisplayNameHasRepeatedSpaces,
            else => return error.DisplayNameHasInvalidCharacters,
        }
    }
}

pub fn validateXuid(xuid: []const u8) Error!void {
    if (xuid.len == 0) return error.MissingXuid;
    _ = std.fmt.parseInt(i64, xuid, 10) catch return error.InvalidXuid;
}

pub fn validateUuid(uuid: []const u8) Error!void {
    if (uuid.len != 36) return error.InvalidUuid;
    for (uuid, 0..) |byte, index| {
        const is_dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (is_dash) {
            if (byte != '-') return error.InvalidUuid;
            continue;
        }
        switch (byte) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return error.InvalidUuid,
        }
    }
}

pub fn uuidFromXuid(allocator: std.mem.Allocator, xuid: []const u8) Error![]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("pocket-auth-1-xuid:");
    md5.update(xuid);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, 36);
    errdefer allocator.free(out);

    var offset: usize = 0;
    for (digest, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            out[offset] = '-';
            offset += 1;
        }
        out[offset] = hex[byte >> 4];
        out[offset + 1] = hex[byte & 0x0f];
        offset += 2;
    }
    std.debug.assert(offset == out.len);
    return out;
}

const testing = std.testing;
const Protocol = @import("protocol");

test "a display name is accepted only if a client could really hold it" {
    try validateDisplayName("Steve");
    try validateDisplayName("Notch Second");
    try validateDisplayName("Player 123");

    try testing.expectError(error.EmptyDisplayName, validateDisplayName(""));
    try testing.expectError(error.DisplayNameTooLong, validateDisplayName("abcdefghijklmnop"));
    try testing.expectError(error.DisplayNameHasEdgeWhitespace, validateDisplayName(" Steve"));
    try testing.expectError(error.DisplayNameHasEdgeWhitespace, validateDisplayName("Steve "));
    try testing.expectError(error.DisplayNameStartsWithDigit, validateDisplayName("1Steve"));
    try testing.expectError(error.DisplayNameHasRepeatedSpaces, validateDisplayName("Steve  Notch"));
    try testing.expectError(error.DisplayNameHasInvalidCharacters, validateDisplayName("Steve\n"));
    try testing.expectError(error.DisplayNameHasInvalidCharacters, validateDisplayName("Gotán"));
}

test "an xuid must be a number when it is present" {
    try validateXuid("2533274799999999");
    try testing.expectError(error.MissingXuid, validateXuid(""));
    try testing.expectError(error.InvalidXuid, validateXuid("not-a-number"));
    try testing.expectError(error.InvalidXuid, validateXuid("12 34"));
}

test "a uuid claim is only kept when it is canonical" {
    try validateUuid("10c34284-6c51-3583-be20-0047fe91d0d0");
    try testing.expectError(error.InvalidUuid, validateUuid("10c342846c513583be200047fe91d0d0"));
    try testing.expectError(error.InvalidUuid, validateUuid("10c34284-6c51-3583-be20-0047fe91d0dz"));
    try testing.expectError(error.InvalidUuid, validateUuid(""));
}

test "a verified identity derives its uuid from the xuid, never from the claim" {
    const allocator = testing.allocator;

    var verified = try build(allocator, .{
        .xuid = "2533274799999999",
        .display_name = "Verified",
        .claimed_uuid = "00000000-0000-4000-8000-000000000123",
        .title_id = "896928775",
        .source = .multiplayer_token,
        .require_xuid = true,
    });
    defer verified.deinit(allocator);

    const expected = try uuidFromXuid(allocator, "2533274799999999");
    defer allocator.free(expected);

    try testing.expectEqualStrings(expected, verified.uuid);
    try testing.expectEqualStrings("Verified", verified.display_name);
    try testing.expectEqual(Source.multiplayer_token, verified.source);
}

test "an identity without an xuid keeps its claimed uuid and needs a canonical one" {
    const allocator = testing.allocator;

    var offline = try build(allocator, .{
        .xuid = "",
        .display_name = "Offliner",
        .claimed_uuid = "00000000-0000-4000-8000-000000000001",
        .title_id = "",
        .source = .legacy_chain,
        .require_xuid = false,
    });
    defer offline.deinit(allocator);
    try testing.expectEqualStrings("00000000-0000-4000-8000-000000000001", offline.uuid);

    try testing.expectError(error.MissingXuid, build(allocator, .{
        .xuid = "",
        .display_name = "Offliner",
        .claimed_uuid = "00000000-0000-4000-8000-000000000001",
        .title_id = "",
        .source = .multiplayer_token,
        .require_xuid = true,
    }));
    try testing.expectError(error.InvalidUuid, build(allocator, .{
        .xuid = "",
        .display_name = "Offliner",
        .claimed_uuid = "not-a-uuid",
        .title_id = "",
        .source = .legacy_chain,
        .require_xuid = false,
    }));
}

test "the xuid-derived uuid matches the one the login decoder derives" {
    const allocator = testing.allocator;
    const xuid = "2533274799999999";

    const derived = try uuidFromXuid(allocator, xuid);
    defer allocator.free(derived);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"xid\":\"{s}\",\"xname\":\"Steve\",\"tid\":\"89692877\",\"cpk\":\"AQ==\"}}",
        .{xuid},
    );
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    var decoded = try Protocol.Login.IdentityData.parse(allocator, parsed.value);
    defer decoded.deinit(allocator);

    try testing.expectEqualStrings(decoded.identity, derived);
    try testing.expectEqual(@as(usize, 36), derived.len);
}
