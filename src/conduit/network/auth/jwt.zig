const std = @import("std");

pub const Error = error{
    MalformedToken,
    UnsupportedAlgorithm,
    InvalidBase64,
    InvalidJson,
    UnexpectedClaimType,
    OutOfMemory,
};

pub const Algorithm = enum { rs256, es384 };

/// A parsed, *not* verified JWT. `signed_data` stays a slice of the original
/// token: re-serialising the JSON would change the bytes the signature covers.
pub const Token = struct {
    allocator: std.mem.Allocator,
    signed_data: []const u8,
    signature: []u8,
    header: std.json.Parsed(std.json.Value),
    payload: std.json.Parsed(std.json.Value),

    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) Error!Token {
        const last_dot = std.mem.lastIndexOfScalar(u8, raw, '.') orelse return error.MalformedToken;
        const signed_data = raw[0..last_dot];

        var segments = std.mem.splitScalar(u8, signed_data, '.');
        const header_segment = segments.next() orelse return error.MalformedToken;
        const payload_segment = segments.next() orelse return error.MalformedToken;
        if (segments.next() != null) return error.MalformedToken;

        const header_json = try decodeBase64Url(allocator, header_segment);
        defer allocator.free(header_json);
        const header = std.json.parseFromSlice(std.json.Value, allocator, header_json, .{}) catch
            return error.InvalidJson;
        errdefer header.deinit();

        const payload_json = try decodeBase64Url(allocator, payload_segment);
        defer allocator.free(payload_json);
        const payload = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch
            return error.InvalidJson;
        errdefer payload.deinit();

        const signature = try decodeBase64Url(allocator, raw[last_dot + 1 ..]);
        errdefer allocator.free(signature);

        if (header.value != .object or payload.value != .object) return error.InvalidJson;

        return .{
            .allocator = allocator,
            .signed_data = signed_data,
            .signature = signature,
            .header = header,
            .payload = payload,
        };
    }

    pub fn deinit(self: *Token) void {
        self.header.deinit();
        self.payload.deinit();
        self.allocator.free(self.signature);
    }

    pub fn algorithm(self: *const Token) Error!Algorithm {
        const alg = (try stringClaim(self.header.value, "alg")) orelse return error.UnsupportedAlgorithm;
        if (std.mem.eql(u8, alg, "RS256")) return .rs256;
        if (std.mem.eql(u8, alg, "ES384")) return .es384;
        return error.UnsupportedAlgorithm;
    }

    pub fn keyId(self: *const Token) ?[]const u8 {
        return stringClaim(self.header.value, "kid") catch null;
    }

    pub fn payloadString(self: *const Token, name: []const u8) Error!?[]const u8 {
        return stringClaim(self.payload.value, name);
    }

    pub fn payloadInt(self: *const Token, name: []const u8) Error!?i64 {
        return intClaim(self.payload.value, name);
    }

    /// `aud` is a string in some tokens and an array of strings in others.
    pub fn audienceMatches(self: *const Token, expected: []const u8) bool {
        const aud = objectOf(self.payload.value).get("aud") orelse return false;
        switch (aud) {
            .string => |s| return std.mem.eql(u8, s, expected),
            .array => |items| {
                for (items.items) |item| {
                    if (item == .string and std.mem.eql(u8, item.string, expected)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn expiresOf(self: *const Token) Error!?i64 {
        return self.payloadInt("exp");
    }
};

pub fn objectOf(value: std.json.Value) std.json.ObjectMap {
    return value.object;
}

pub fn stringClaim(container: std.json.Value, name: []const u8) Error!?[]const u8 {
    if (container != .object) return error.UnexpectedClaimType;
    const value = container.object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => error.UnexpectedClaimType,
    };
}

pub fn intClaim(container: std.json.Value, name: []const u8) Error!?i64 {
    if (container != .object) return error.UnexpectedClaimType;
    const value = container.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .null => null,
        else => error.UnexpectedClaimType,
    };
}

pub fn boolClaim(container: std.json.Value, name: []const u8) Error!?bool {
    if (container != .object) return error.UnexpectedClaimType;
    const value = container.object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        .null => null,
        else => error.UnexpectedClaimType,
    };
}

fn decodeBase64Url(allocator: std.mem.Allocator, encoded: []const u8) Error![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch {
        return decodeBase64UrlPadded(allocator, encoded) catch error.InvalidBase64;
    };
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidBase64;
    return decoded;
}

fn decodeBase64UrlPadded(allocator: std.mem.Allocator, encoded: []const u8) Error![]u8 {
    const decoder = std.base64.url_safe.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidBase64;
    return decoded;
}

const testing = std.testing;

fn tokenWith(allocator: std.mem.Allocator, header: []const u8, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    var signature: [96]u8 = [_]u8{0xab} ** 96;
    const total = encoder.calcSize(header.len) + 1 +
        encoder.calcSize(payload.len) + 1 +
        encoder.calcSize(signature.len);
    const token = try allocator.alloc(u8, total);
    errdefer allocator.free(token);

    var offset: usize = 0;
    offset += encoder.encode(token[offset..], header).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], payload).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], &signature).len;
    std.debug.assert(offset == total);
    return token;
}

test "a token exposes its header, payload and the exact signed bytes" {
    const allocator = testing.allocator;
    const raw = try tokenWith(
        allocator,
        "{\"alg\":\"RS256\",\"kid\":\"AB12\"}",
        "{\"iss\":\"https://example.test/\",\"exp\":1893456000,\"aud\":[\"one\",\"two\"]}",
    );
    defer allocator.free(raw);

    var token = try Token.parse(allocator, raw);
    defer token.deinit();

    try testing.expectEqual(Algorithm.rs256, try token.algorithm());
    try testing.expectEqualStrings("AB12", token.keyId().?);
    try testing.expectEqualStrings("https://example.test/", (try token.payloadString("iss")).?);
    try testing.expectEqual(@as(i64, 1893456000), (try token.expiresOf()).?);
    try testing.expect(token.audienceMatches("two"));
    try testing.expect(!token.audienceMatches("three"));
    try testing.expectEqualStrings(raw[0..token.signed_data.len], token.signed_data);
    try testing.expectEqual(@as(u8, '.'), raw[token.signed_data.len]);
    try testing.expectEqual(@as(usize, 96), token.signature.len);
}

test "a token with an unknown or missing algorithm is refused" {
    const allocator = testing.allocator;
    const none = try tokenWith(allocator, "{\"alg\":\"none\"}", "{}");
    defer allocator.free(none);
    var none_token = try Token.parse(allocator, none);
    defer none_token.deinit();
    try testing.expectError(error.UnsupportedAlgorithm, none_token.algorithm());

    const missing = try tokenWith(allocator, "{}", "{}");
    defer allocator.free(missing);
    var missing_token = try Token.parse(allocator, missing);
    defer missing_token.deinit();
    try testing.expectError(error.UnsupportedAlgorithm, missing_token.algorithm());
}

test "a malformed token is refused instead of being partially read" {
    const allocator = testing.allocator;
    try testing.expectError(error.MalformedToken, Token.parse(allocator, "no-dots"));
    try testing.expectError(error.MalformedToken, Token.parse(allocator, "a.b.c.d"));

    const not_json = try tokenWith(allocator, "not json", "{}");
    defer allocator.free(not_json);
    try testing.expectError(error.InvalidJson, Token.parse(allocator, not_json));
}

test "a claim of the wrong type is an error, a missing claim is null" {
    const allocator = testing.allocator;
    const raw = try tokenWith(allocator, "{\"alg\":\"ES384\"}", "{\"xid\":7}");
    defer allocator.free(raw);

    var token = try Token.parse(allocator, raw);
    defer token.deinit();

    try testing.expectError(error.UnexpectedClaimType, token.payloadString("xid"));
    try testing.expectEqual(@as(?[]const u8, null), try token.payloadString("xname"));
}
