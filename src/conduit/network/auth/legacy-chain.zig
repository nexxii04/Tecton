const std = @import("std");

const jwt = @import("jwt.zig");
const signature = @import("signature.zig");
const identity = @import("identity.zig");

pub const issuer = "Mojang";

pub const Error = error{
    EmptyChain,
    UnexpectedChainLength,
    MissingClientPublicKey,
    MissingIdentityPublicKey,
    MissingExtraData,
    InvalidSignature,
    InvalidIssuer,
    ExpiredToken,
    TokenNotYetValid,
    /// The chain verifies only against itself, so it proves nothing.
    NotAnchoredAtRoot,
    /// The XUID disagrees with whether the chain was anchored.
    IdentityMismatch,
    InvalidIdentity,
    OutOfMemory,
} || jwt.Error || identity.Error;

pub const Result = identity.Verified;

/// Authenticated only when the key its first link claims is exactly `anchor`;
/// every other link is verified against the key the previous one claimed.
pub fn verify(
    allocator: std.mem.Allocator,
    chain: []const []const u8,
    anchor: signature.Secp384PublicKey,
    now: i64,
) Error!Result {
    if (chain.len == 0) return error.EmptyChain;
    if (chain.len != 1 and chain.len != 3) return error.UnexpectedChainLength;
    if (chain.len == 1) return error.NotAnchoredAtRoot;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    var link = try jwt.Token.parse(scratch, chain[0]);
    const x5u = (try jwt.stringClaim(link.header.value, "x5u")) orelse return error.MissingClientPublicKey;
    var key = signature.Secp384PublicKey.fromBase64(x5u) catch return error.MissingClientPublicKey;
    if (!key.verifyEs384(link.signature, link.signed_data)) return error.InvalidSignature;
    try validateTime(&link, now);

    key = try claimedPublicKey(&link) orelse return error.MissingIdentityPublicKey;
    if (!signature.Secp384PublicKey.eql(key, anchor)) return error.NotAnchoredAtRoot;

    var middle = try jwt.Token.parse(scratch, chain[1]);
    if (!key.verifyEs384(middle.signature, middle.signed_data)) return error.InvalidSignature;
    try validateTime(&middle, now);
    try validateIssuer(&middle);

    key = try claimedPublicKey(&middle) orelse return error.MissingIdentityPublicKey;
    var last = try jwt.Token.parse(scratch, chain[2]);
    if (!key.verifyEs384(last.signature, last.signed_data)) return error.InvalidSignature;
    try validateTime(&last, now);
    try validateIssuer(&last);

    const client_key = try claimedPublicKey(&last) orelse return error.MissingClientPublicKey;
    const verified = try fromExtraData(allocator, &last, .legacy_chain);
    errdefer {
        var owned = verified;
        owned.deinit(allocator);
    }
    if (verified.xuid.len == 0) return error.IdentityMismatch;
    return .{ .identity = verified, .client_public_key = client_key };
}

fn validateTime(link: *const jwt.Token, now: i64) Error!void {
    const expires = (try link.payloadInt("exp")) orelse return error.ExpiredToken;
    if (expires <= now) return error.ExpiredToken;
    if (try link.payloadInt("nbf")) |not_before| {
        if (not_before > now) return error.TokenNotYetValid;
    }
}

fn validateIssuer(link: *const jwt.Token) Error!void {
    const iss = (try link.payloadString("iss")) orelse return error.InvalidIssuer;
    if (!std.mem.eql(u8, iss, issuer)) return error.InvalidIssuer;
}

fn claimedPublicKey(link: *const jwt.Token) Error!?signature.Secp384PublicKey {
    const encoded = (try link.payloadString("identityPublicKey")) orelse return null;
    return signature.Secp384PublicKey.fromBase64(encoded) catch return error.MissingIdentityPublicKey;
}

fn fromExtraData(
    allocator: std.mem.Allocator,
    link: *const jwt.Token,
    source: identity.Source,
) Error!identity.Identity {
    const payload = link.payload.value;
    if (payload != .object) return error.MissingExtraData;
    const extra = payload.object.get("extraData") orelse return error.MissingExtraData;
    if (extra != .object) return error.MissingExtraData;

    const xuid = (try jwt.stringClaim(extra, "XUID")) orelse return error.InvalidIdentity;
    const display_name = (try jwt.stringClaim(extra, "displayName")) orelse return error.InvalidIdentity;
    const claimed_uuid = (try jwt.stringClaim(extra, "identity")) orelse return error.InvalidIdentity;
    const title_id = (try jwt.stringClaim(extra, "titleId")) orelse return error.InvalidIdentity;

    return identity.build(allocator, .{
        .xuid = xuid,
        .display_name = display_name,
        .claimed_uuid = claimed_uuid,
        .title_id = title_id,
        .source = source,
        .require_xuid = false,
    });
}

const testing = std.testing;

fn testKey(seed: u8) std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair {
    const secret = std.crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.fromBytes([_]u8{seed} ** 48) catch unreachable;
    return std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.fromSecretKey(secret) catch unreachable;
}

fn base64Of(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    errdefer allocator.free(out);
    _ = encoder.encode(out, bytes);
    return out;
}

fn spkiOf(allocator: std.mem.Allocator, key: signature.Secp384PublicKey) ![]u8 {
    var spki: [signature.secp384r1_spki_prefix.len + 97]u8 = undefined;
    @memcpy(spki[0..signature.secp384r1_spki_prefix.len], &signature.secp384r1_spki_prefix);
    @memcpy(spki[signature.secp384r1_spki_prefix.len..], &key.bytes);
    return base64Of(allocator, &spki);
}

fn signToken(
    allocator: std.mem.Allocator,
    key: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    header: []const u8,
    payload: []const u8,
) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const signed_data = try allocator.alloc(u8, encoder.calcSize(header.len) + 1 + encoder.calcSize(payload.len));
    defer allocator.free(signed_data);

    var offset: usize = 0;
    offset += encoder.encode(signed_data[offset..], header).len;
    signed_data[offset] = '.';
    offset += 1;
    offset += encoder.encode(signed_data[offset..], payload).len;
    std.debug.assert(offset == signed_data.len);

    const sig = try key.sign(signed_data, null);
    const sig_bytes = sig.toBytes();
    const token = try allocator.alloc(u8, signed_data.len + 1 + encoder.calcSize(sig_bytes.len));
    errdefer allocator.free(token);

    @memcpy(token[0..signed_data.len], signed_data);
    token[signed_data.len] = '.';
    _ = encoder.encode(token[signed_data.len + 1 ..], &sig_bytes);
    return token;
}

const Chain = struct {
    tokens: [3][]u8,

    fn deinit(self: Chain, allocator: std.mem.Allocator) void {
        for (self.tokens) |token| allocator.free(token);
    }

    fn slice(self: *const Chain) []const []const u8 {
        return &self.tokens;
    }
};

fn buildChain(
    allocator: std.mem.Allocator,
    claimed_key: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    signer: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    client: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair,
    xuid: []const u8,
    now: i64,
) !Chain {
    const client_key = try SecpKey.public(client);
    const middle_key = try SecpKey.public(claimed_key);
    const client_spki = try spkiOf(allocator, client_key);
    defer allocator.free(client_spki);
    const anchor_spki = try spkiOf(allocator, middle_key);
    defer allocator.free(anchor_spki);
    const middle_spki = try spkiOf(allocator, middle_key);
    defer allocator.free(middle_spki);

    const first_header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"ES384\",\"x5u\":\"{s}\"}}", .{client_spki});
    defer allocator.free(first_header);
    const first_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"identityPublicKey\":\"{s}\",\"certificateAuthority\":true,\"exp\":{d},\"nbf\":{d}}}",
        .{ anchor_spki, now + 3600, now - 3600 },
    );
    defer allocator.free(first_payload);

    const second_header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"ES384\",\"x5u\":\"{s}\"}}", .{client_spki});
    defer allocator.free(second_header);
    const second_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"identityPublicKey\":\"{s}\",\"iss\":\"Mojang\",\"exp\":{d},\"nbf\":{d}}}",
        .{ middle_spki, now + 3600, now - 3600 },
    );
    defer allocator.free(second_payload);

    const third_header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"ES384\",\"x5u\":\"{s}\"}}", .{client_spki});
    defer allocator.free(third_header);
    const third_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"identityPublicKey\":\"{s}\",\"iss\":\"Mojang\",\"exp\":{d},\"nbf\":{d}," ++
            "\"extraData\":{{\"XUID\":\"{s}\",\"displayName\":\"Verified\",\"identity\":\"{s}\",\"titleId\":\"896928775\"}}}}",
        .{ client_spki, now + 3600, now - 3600, xuid, "10c34284-6c51-3583-be20-0047fe91d0d0" },
    );
    defer allocator.free(third_payload);

    return .{ .tokens = .{
        try signToken(allocator, client, first_header, first_payload),
        try signToken(allocator, signer, second_header, second_payload),
        try signToken(allocator, claimed_key, third_header, third_payload),
    } };
}

const SecpKey = struct {
    fn public(key: std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair) !signature.Secp384PublicKey {
        return signature.Secp384PublicKey.fromSec1(&key.public_key.toUncompressedSec1());
    }
};

test "a chain signed by the pinned root key yields the identity it carries" {
    const allocator = testing.allocator;
    const now: i64 = 1800000000;

    const anchor = testKey(1);
    const client = testKey(3);
    const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", now);
    defer chain.deinit(allocator);

    var result = try verify(allocator, chain.slice(), try SecpKey.public(anchor), now);
    defer result.identity.deinit(allocator);

    const expected_uuid = try identity.uuidFromXuid(allocator, "2533274799999999");
    defer allocator.free(expected_uuid);

    try testing.expectEqualStrings("2533274799999999", result.identity.xuid);
    try testing.expectEqualStrings("Verified", result.identity.display_name);
    try testing.expectEqualStrings(expected_uuid, result.identity.uuid);
    try testing.expectEqualStrings("896928775", result.identity.title_id);
    try testing.expectEqual(identity.Source.legacy_chain, result.identity.source);
    try testing.expect(signature.Secp384PublicKey.eql(result.client_public_key, try SecpKey.public(client)));
}

test "a chain that only verifies against itself is not anchored" {
    const allocator = testing.allocator;
    const now: i64 = 1800000000;

    const anchor = testKey(1);
    const forger = testKey(9);
    const client = testKey(3);
    const chain = try buildChain(allocator, forger, forger, client, "2533274799999999", now);
    defer chain.deinit(allocator);

    try testing.expectError(
        error.NotAnchoredAtRoot,
        verify(allocator, chain.slice(), try SecpKey.public(anchor), now),
    );
    var result = try verify(allocator, chain.slice(), try SecpKey.public(forger), now);
    defer result.identity.deinit(allocator);
}

test "a chain whose links do not sign each other is refused" {
    const allocator = testing.allocator;
    const now: i64 = 1800000000;

    const anchor = testKey(1);
    const client = testKey(3);
    const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", now);
    defer chain.deinit(allocator);

    const swapped = [_][]const u8{ chain.tokens[0], chain.tokens[2], chain.tokens[1] };
    try testing.expectError(error.InvalidSignature, verify(allocator, &swapped, try SecpKey.public(anchor), now));
}

test "an expired chain, a wrong issuer and an unknown length are refused" {
    const allocator = testing.allocator;

    const anchor = testKey(1);
    const client = testKey(3);
    const expired_at: i64 = 1800000000;
    const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", expired_at);
    defer chain.deinit(allocator);

    try testing.expectError(
        error.ExpiredToken,
        verify(allocator, chain.slice(), try SecpKey.public(anchor), expired_at + 7200),
    );
    try testing.expectError(
        error.UnexpectedChainLength,
        verify(allocator, chain.slice()[0..2], try SecpKey.public(anchor), expired_at),
    );
    try testing.expectError(
        error.EmptyChain,
        verify(allocator, &.{}, try SecpKey.public(anchor), expired_at),
    );
}

test "an anchored chain that carries no xuid is a mismatch" {
    const allocator = testing.allocator;
    const now: i64 = 1800000000;

    const anchor = testKey(1);
    const client = testKey(3);
    const chain = try buildChain(allocator, anchor, anchor, client, "", now);
    defer chain.deinit(allocator);

    try testing.expectError(
        error.IdentityMismatch,
        verify(allocator, chain.slice(), try SecpKey.public(anchor), now),
    );
}

test "a single self-signed link proves nothing" {
    const allocator = testing.allocator;
    const now: i64 = 1800000000;

    const client = testKey(3);
    const client_key = try SecpKey.public(client);
    const client_spki = try spkiOf(allocator, client_key);
    defer allocator.free(client_spki);

    const header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"ES384\",\"x5u\":\"{s}\"}}", .{client_spki});
    defer allocator.free(header);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"identityPublicKey\":\"{s}\",\"iss\":\"self\",\"exp\":{d}," ++
            "\"extraData\":{{\"XUID\":\"2533274799999999\",\"displayName\":\"Offliner\",\"identity\":\"{s}\",\"titleId\":\"\"}}}}",
        .{ client_spki, now + 3600, "00000000-0000-4000-8000-000000000001" },
    );
    defer allocator.free(payload);

    const token = try signToken(allocator, client, header, payload);
    defer allocator.free(token);

    try testing.expectError(
        error.NotAnchoredAtRoot,
        verify(allocator, &.{token}, try SecpKey.public(testKey(1)), now),
    );
}
