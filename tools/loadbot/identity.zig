//! Mints the login chain of a fake client: offline mode only decodes it, while
//! online mode refuses a chain not anchored at Mojang's root key.
const std = @import("std");

pub const Params = struct {
    server_address: []const u8,
    game_version: []const u8,
    device_model: []const u8 = "Conduit LoadBot",
    device_os: i64 = 7,
};

pub const Credentials = struct {
    identity: []u8,
    client: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Credentials) void {
        self.allocator.free(self.identity);
        self.allocator.free(self.client);
    }
};

/// Both slices are owned by the caller through `Credentials.deinit`.
pub fn forge(
    allocator: std.mem.Allocator,
    name: []const u8,
    index: usize,
    params: Params,
) !Credentials {
    const xuid = try std.fmt.allocPrint(allocator, "2535{d:0>10}", .{index});
    defer allocator.free(xuid);

    var key_bytes: [97]u8 = [_]u8{0} ** 97;
    key_bytes[0] = 0x04;
    var key_base64: [std.base64.standard.Encoder.calcSize(97)]u8 = undefined;
    const public_key = std.base64.standard.Encoder.encode(&key_base64, &key_bytes);

    const identity_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"xid\":\"{s}\",\"xname\":\"{s}\",\"tid\":\"89692877\",\"cpk\":\"{s}\"}}",
        .{ xuid, name, public_key },
    );
    defer allocator.free(identity_payload);

    const token = try jwt(allocator, identity_payload);
    defer allocator.free(token);

    const identity = try std.fmt.allocPrint(
        allocator,
        "{{\"AuthenticationType\":1,\"Token\":\"{s}\"}}",
        .{token},
    );
    errdefer allocator.free(identity);

    const self_signed_id = try std.fmt.allocPrint(allocator, "00000000-0000-4000-8000-{d:0>12}", .{index});
    defer allocator.free(self_signed_id);

    const client_payload = try std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"SkinId\":\"Standard_Custom\"," ++
            "\"PlayFabId\":\"\"," ++
            "\"SkinResourcePatch\":\"\"," ++
            "\"SkinImageHeight\":0," ++
            "\"SkinImageWidth\":0," ++
            "\"SkinData\":\"\"," ++
            "\"CapeImageHeight\":0," ++
            "\"CapeImageWidth\":0," ++
            "\"CapeData\":\"\"," ++
            "\"CapeId\":\"\"," ++
            "\"SkinGeometryData\":\"\"," ++
            "\"SkinGeometryDataEngineVersion\":\"\"," ++
            "\"SkinAnimationData\":\"\"," ++
            "\"AnimatedImageData\":[]," ++
            "\"PersonaSkin\":false," ++
            "\"PremiumSkin\":false," ++
            "\"CapeOnClassicSkin\":false," ++
            "\"TrustedSkin\":true," ++
            "\"ArmSize\":\"wide\"," ++
            "\"SkinColor\":\"#b37b62\"," ++
            "\"PersonaPieces\":[]," ++
            "\"PieceTintColors\":[]," ++
            "\"DeviceModel\":\"{s}\"," ++
            "\"DeviceOS\":{d}," ++
            "\"DeviceId\":\"{s}\"," ++
            "\"GameVersion\":\"{s}\"," ++
            "\"LanguageCode\":\"en_US\"," ++
            "\"ServerAddress\":\"{s}\"," ++
            "\"ThirdPartyName\":\"\"," ++
            "\"PlatformOnlineId\":\"\"," ++
            "\"SelfSignedId\":\"{s}\"," ++
            "\"UIProfile\":0," ++
            "\"CurrentInputMode\":1," ++
            "\"DefaultInputMode\":1," ++
            "\"GuiScale\":-1" ++
            "}}",
        .{
            params.device_model,
            params.device_os,
            self_signed_id,
            params.game_version,
            params.server_address,
            self_signed_id,
        },
    );
    errdefer allocator.free(client_payload);

    const client = try jwt(allocator, client_payload);
    allocator.free(client_payload);

    return .{ .identity = identity, .client = client, .allocator = allocator };
}

const jwt_header = "{\"alg\":\"ES384\",\"x5u\":\"MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE\"}";

/// `header.payload.signature`, base64url without padding; the signature is filler.
fn jwt(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const signature = [_]u8{0} ** 96;

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header_len = encoder.calcSize(jwt_header.len);
    const payload_len = encoder.calcSize(payload.len);
    const signature_len = encoder.calcSize(signature.len);

    const total = header_len + 1 + payload_len + 1 + signature_len;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    var offset: usize = 0;
    offset += encoder.encode(out[offset..], jwt_header).len;
    out[offset] = '.';
    offset += 1;
    offset += encoder.encode(out[offset..], payload).len;
    out[offset] = '.';
    offset += 1;
    offset += encoder.encode(out[offset..], &signature).len;
    std.debug.assert(offset == total);

    return out;
}

const testing = std.testing;

test "jwt parts are base64url without padding" {
    const allocator = testing.allocator;
    const token = try jwt(allocator, "{\"a\":1}");
    defer allocator.free(token);

    var parts = std.mem.splitScalar(u8, token, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        try testing.expect(std.mem.indexOfScalar(u8, part, '=') == null);
        try testing.expect(std.mem.indexOfScalar(u8, part, '+') == null);
        try testing.expect(std.mem.indexOfScalar(u8, part, '/') == null);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "names and versions land in the decoded payload" {
    const allocator = testing.allocator;
    var creds = try forge(allocator, "LoadBot0002", 2, .{
        .server_address = "10.0.0.5:19133",
        .game_version = "1.26.50",
    });
    defer creds.deinit();

    const chain = try std.json.parseFromSlice(std.json.Value, allocator, creds.identity, .{});
    defer chain.deinit();

    const payload = try decodeJwtPayload(allocator, chain.value.object.get("Token").?.string);
    defer allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\"xname\":\"LoadBot0002\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"xid\":\"25350000000002\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "\"cpk\":\"") != null);

    const client = try decodeJwtPayload(allocator, creds.client);
    defer allocator.free(client);
    try testing.expect(std.mem.indexOf(u8, client, "\"ServerAddress\":\"10.0.0.5:19133\"") != null);
    try testing.expect(std.mem.indexOf(u8, client, "\"GuiScale\":-1") != null);
}

fn decodeJwtPayload(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const payload = parts.next() orelse return error.TestUnexpectedResult;

    const decoded = try allocator.alloc(u8, try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload));
    errdefer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload);
    return decoded;
}
