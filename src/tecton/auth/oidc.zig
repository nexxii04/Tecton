const std = @import("std");

const jwt = @import("jwt.zig");
const jwks = @import("jwks.zig");
const signature = @import("signature.zig");
const identity = @import("identity.zig");

pub const audience = "api://auth-minecraft-services/multiplayer";

pub const max_clock_skew_seconds: i64 = 60;

pub const Error = error{
    UnsupportedAlgorithm,
    MissingKeyId,
    UnknownKeyId,
    InvalidSignature,
    InvalidIssuer,
    InvalidAudience,
    ExpiredToken,
    TokenNotYetValid,
    IssuedInTheFuture,
    MissingClientPublicKey,
    InvalidClientPublicKey,
    OutOfMemory,
} || jwt.Error || identity.Error;

pub const Params = struct {
    issuer: []const u8,
    keys: *const jwks.KeySet,
    now: i64,
};

pub const Result = identity.Verified;

pub fn verify(allocator: std.mem.Allocator, raw_token: []const u8, params: Params) Error!Result {
    var token = try jwt.Token.parse(allocator, raw_token);
    defer token.deinit();

    if (try token.algorithm() != .rs256) return error.UnsupportedAlgorithm;

    const kid = token.keyId() orelse return error.MissingKeyId;
    if (kid.len == 0) return error.MissingKeyId;
    const key = params.keys.find(kid) orelse return error.UnknownKeyId;
    if (!key.verify(token.signature, token.signed_data)) return error.InvalidSignature;

    const iss = (try token.payloadString("iss")) orelse return error.InvalidIssuer;
    if (!std.mem.eql(u8, iss, params.issuer)) return error.InvalidIssuer;
    if (!token.audienceMatches(audience)) return error.InvalidAudience;

    const expires = (try token.expiresOf()) orelse return error.ExpiredToken;
    if (expires <= params.now) return error.ExpiredToken;
    if (try token.payloadInt("nbf")) |not_before| {
        if (not_before > params.now + max_clock_skew_seconds) return error.TokenNotYetValid;
    }
    if (try token.payloadInt("iat")) |issued_at| {
        if (issued_at > params.now + max_clock_skew_seconds) return error.IssuedInTheFuture;
    }

    const cpk = (try token.payloadString("cpk")) orelse return error.MissingClientPublicKey;
    const client_public_key = signature.Secp384PublicKey.fromBase64(cpk) catch
        return error.InvalidClientPublicKey;

    const xuid = (try token.payloadString("xid")) orelse "";
    const display_name = (try token.payloadString("xname")) orelse "";
    const title_id = (try token.payloadString("tid")) orelse "";

    var verified = try identity.build(allocator, .{
        .xuid = xuid,
        .display_name = display_name,
        .claimed_uuid = "",
        .title_id = title_id,
        .source = .multiplayer_token,
        .require_xuid = true,
    });
    errdefer verified.deinit(allocator);

    return .{ .identity = verified, .client_public_key = client_public_key };
}

pub fn verifyClientData(
    allocator: std.mem.Allocator,
    client_data_token: []const u8,
    client_public_key: signature.Secp384PublicKey,
) Error!void {
    var token = try jwt.Token.parse(allocator, client_data_token);
    defer token.deinit();

    if (try token.algorithm() != .es384) return error.UnsupportedAlgorithm;
    if (!client_public_key.verifyEs384(token.signature, token.signed_data)) return error.InvalidSignature;
}

const testing = std.testing;

const now: i64 = 1800000000;

fn testKeys(allocator: std.mem.Allocator) !jwks.KeySet {
    return jwks.KeySet.parse(allocator, fixture_jwks);
}

test "a token signed by a published key yields the identity of its claims" {
    const allocator = testing.allocator;
    var keys = try testKeys(allocator);
    defer keys.deinit();

    var result = try verify(allocator, fixture_valid, .{
        .issuer = fixture_issuer,
        .keys = &keys,
        .now = now,
    });
    defer result.identity.deinit(allocator);

    const expected_uuid = try identity.uuidFromXuid(allocator, "2533274799999999");
    defer allocator.free(expected_uuid);

    try testing.expectEqualStrings("2533274799999999", result.identity.xuid);
    try testing.expectEqualStrings("Verified", result.identity.display_name);
    try testing.expectEqualStrings(expected_uuid, result.identity.uuid);
    try testing.expectEqualStrings("20CA2", result.identity.title_id);
    try testing.expectEqual(identity.Source.multiplayer_token, result.identity.source);

    const expected_cpk = try signature.Secp384PublicKey.fromBase64(fixture_cpk);
    try testing.expect(signature.Secp384PublicKey.eql(expected_cpk, result.client_public_key));
}

test "a token is refused for every way it can be wrong" {
    const allocator = testing.allocator;
    var keys = try testKeys(allocator);
    defer keys.deinit();

    const params = Params{ .issuer = fixture_issuer, .keys = &keys, .now = now };

    try testing.expectError(error.ExpiredToken, verify(allocator, fixture_expired, params));
    try testing.expectError(error.InvalidAudience, verify(allocator, fixture_wrong_audience, params));
    try testing.expectError(error.InvalidIssuer, verify(allocator, fixture_wrong_issuer, params));
    try testing.expectError(error.TokenNotYetValid, verify(allocator, fixture_future, params));
    try testing.expectError(error.MissingXuid, verify(allocator, fixture_no_xuid, params));
    try testing.expectError(error.DisplayNameStartsWithDigit, verify(allocator, fixture_bad_name, params));
    try testing.expectError(error.InvalidSignature, verify(allocator, fixture_foreign, params));
    try testing.expectError(error.InvalidIssuer, verify(allocator, fixture_valid, .{
        .issuer = "https://example.test/",
        .keys = &keys,
        .now = now,
    }));
}

test "a token is refused before its signature when the key or algorithm is wrong" {
    const allocator = testing.allocator;
    var keys = try testKeys(allocator);
    defer keys.deinit();

    const params = Params{ .issuer = fixture_issuer, .keys = &keys, .now = now };

    try testing.expectError(error.UnknownKeyId, verify(allocator, unsignedToken(allocator, "RS256", "other"), params));
    try testing.expectError(error.MissingKeyId, verify(allocator, unsignedToken(allocator, "RS256", ""), params));
    try testing.expectError(error.UnsupportedAlgorithm, verify(allocator, unsignedToken(allocator, "none", "test-key-1"), params));
    try testing.expectError(error.UnsupportedAlgorithm, verify(allocator, unsignedToken(allocator, "ES384", "test-key-1"), params));
}

test "client data is only trusted when it is signed by the key the token vouches for" {
    const allocator = testing.allocator;
    const cpk = try signature.Secp384PublicKey.fromBase64(fixture_cpk);

    try verifyClientData(allocator, fixture_client_data, cpk);

    const other_key = std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.fromSecretKey(
        std.crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.fromBytes([_]u8{5} ** 48) catch unreachable,
    ) catch unreachable;
    const other = try signature.Secp384PublicKey.fromSec1(&other_key.public_key.toUncompressedSec1());
    try testing.expectError(error.InvalidSignature, verifyClientData(allocator, fixture_client_data, other));

    const tampered = try std.mem.replaceOwned(u8, allocator, fixture_client_data, "l_frRtWv", "l_frRtWw");
    defer allocator.free(tampered);
    try testing.expectError(error.InvalidSignature, verifyClientData(allocator, tampered, cpk));

    try testing.expectError(error.MalformedToken, verifyClientData(allocator, "", cpk));
}

fn unsignedToken(allocator: std.mem.Allocator, alg: []const u8, kid: []const u8) []const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = std.fmt.allocPrint(
        allocator,
        "{{\"alg\":\"{s}\",\"kid\":\"{s}\"}}",
        .{ alg, kid },
    ) catch unreachable;
    defer allocator.free(header);

    var token: [512]u8 = undefined;
    var offset: usize = 0;
    offset += encoder.encode(token[offset..], header).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], "{}").len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], &[_]u8{0} ** 96).len;
    return token[0..offset];
}

const fixture_jwks =
    \\{"keys":[{"kty":"RSA","use":"sig","kid":"test-key-1","alg":"RS256","n":"7CSTWxEgmyBIoc-S5s7MlT2ycP0MvHp7XAyZbu_SRjzTot6NJ2eDlaJ6tbTP4DSLdLrWJ-ZjZ6c79aG8teG85RGk_YE2Xw04RzhfzN7wDUU_Q-zbC7RdM1DbwZ8Iua7HGL_dCxmmo44jr50gIo5WTHRSeHbXN1ZObFB3qAYIEtNxIRtlPmRQJcFOtG1f4wvubyPHxpx7U9R37I0H6P8-UFwd7VRBAl6kdgH2oKUZG2Atl7clvClOeWuhhcvcxkigXFjAJmBbMtgoZjUDMpLzIbMP5K5HDeOqJF38VjWnovGRx394Wxu-OWsb1nPIeu5eNnXS2-UgFBKpEoErQhhtnw","e":"AQAB"}]}
;

const fixture_cpk =
    "MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEaqkB1aY2B+2FOCU8/e3JAzxCDwt4v52xZQlIuEX4o+8xaWMNdb2loNzZCEoNf2pVZS3Ju6ysVD9ZW5PeYAQRHZXhlvwmHVDLZDZaooBNR1cbnxOYHsP8OWG5VkjXnlwP";

const fixture_issuer = "https://authorization.franchise.minecraft-services.net/";

const fixture_valid =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE4MDAwMDM2MDAsIm5iZiI6MTc5OTk5NjQwMCwiaWF0IjoxNzk5OTk2NDAwLCJ4aWQiOiIyNTMzMjc0Nzk5OTk5OTk5IiwieG5hbWUiOiJWZXJpZmllZCIsInRpZCI6IjIwQ0EyIiwibWlkIjoiYWJjIiwiY3BrIjoiTUhZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUNJRFlnQUVhcWtCMWFZMkIrMkZPQ1U4L2UzSkF6eENEd3Q0djUyeFpRbEl1RVg0bys4eGFXTU5kYjJsb056WkNFb05mMnBWWlMzSnU2eXNWRDlaVzVQZVlBUVJIWlhobHZ3bUhWRExaRFphb29CTlIxY2JueE9ZSHNQOE9XRzVWa2pYbmx3UCJ9.RfCStnshqjhITNDy_V7xhkGliwsxEOvLReplS3jBRpUfrVFVuT2TP0M9BJ9LMKkKFAKXVXfXXA_i3xteN5iRZIKY-Ebpg65bgFgohvFKVLzm4M-oADldyBF1Lv_3CRZPTBKkVGoNOLo_Iu-_fFoEObPWhJvRi9x4JyL9SsO3gl1kDAh79lOMF3Z2Qs4kGkWBb4W1FU0sG4nClEHvnCgS2XRiks5nvcnSez0LcTLEwzUGa9uFpP_KSyEjNUJF_cZ4cV59my2Aja_ZsD2I5iCJnGyWt0GkC41bEuCPfhBEEXUHDv0oKJ1OJqVvWLH-lDEoYSAz7FmtFWVh6METRwLKng";

const fixture_expired =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE3OTk5OTk5OTksIm5iZiI6MTc5OTk5NjQwMCwiaWF0IjoxNzk5OTk2NDAwLCJ4aWQiOiIyNTMzMjc0Nzk5OTk5OTk5IiwieG5hbWUiOiJWZXJpZmllZCIsInRpZCI6IjIwQ0EyIiwibWlkIjoiYWJjIiwiY3BrIjoiTUhZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUNJRFlnQUVhcWtCMWFZMkIrMkZPQ1U4L2UzSkF6eENEd3Q0djUyeFpRbEl1RVg0bys4eGFXTU5kYjJsb056WkNFb05mMnBWWlMzSnU2eXNWRDlaVzVQZVlBUVJIWlhobHZ3bUhWRExaRFphb29CTlIxY2JueE9ZSHNQOE9XRzVWa2pYbmx3UCJ9.eSubJTaXwLhOaf1gnDH2eswfLiF-GEDa0OEWSe4-EWVxDHjup2__e-BJJTO2fNL_-MahmVSZYXgTzGuU2xQicgBCPo6gBuqjktjrxixghH5ilSNZyvrTMrcqjWyTEn2rqlBSeML1JEZQIcS_kDk6q1auk3oxcO6xqI-K4Nc-TdMATZJtin58KOUenz536lkPmpow4adO9WlqceT5lHHI8idH2fwn7vcLp9AknGPHBYlFM5jZwcl948jOkPGz3dO2LHJYcF1Eq7jjgmkr3oqD2qEDNiGQ8B_T3gHmW2fEwlFm5oHybTkgMmRIk7MHhALsjUqu_B1Z3IM0apzI6GCavA";

const fixture_wrong_audience =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vc29tZW9uZS1lbHNlIiwiZXhwIjoxODAwMDAzNjAwLCJuYmYiOjE3OTk5OTY0MDAsImlhdCI6MTc5OTk5NjQwMCwieGlkIjoiMjUzMzI3NDc5OTk5OTk5OSIsInhuYW1lIjoiVmVyaWZpZWQiLCJ0aWQiOiIyMENBMiIsIm1pZCI6ImFiYyIsImNwayI6Ik1IWXdFQVlIS29aSXpqMENBUVlGSzRFRUFDSURZZ0FFYXFrQjFhWTJCKzJGT0NVOC9lM0pBenhDRHd0NHY1MnhaUWxJdUVYNG8rOHhhV01OZGIybG9OelpDRW9OZjJwVlpTM0p1NnlzVkQ5Wlc1UGVZQVFSSFpYaGx2d21IVkRMWkRaYW9vQk5SMWNibnhPWUhzUDhPV0c1VmtqWG5sd1AifQ.G4F4276wnNmOruvuTvFEMNBTVk_qBuPyk54_vFB6JglBD15gaeSR9dD7zfW_JXsjbOeB2qzYPeMu6Xr9RhnJbEZB75cj1KrgxtVzKGYdbwIa4PrFgX3-KCb5vlHuN2R-mRbQwSTFhlbffwE65i02SM-KoW_3dZh7o1NqMkhNSXBc670bWyiEh9V2OgFcZQnTTSwzL6INkzku3g129lcY5OEGAaOxDqEe7qKk5m1cTzhAbIcEiEIT97yd0no2gaLXjknimWWazwUE0gyPNuxzSmqlac-uX0lPtF0auJ2BfT93cHLCq9daHhj-7rK5ebFCBOtyOyHx7OFxqDaIq6ZGQw";

const fixture_wrong_issuer =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2V4YW1wbGUudGVzdC8iLCJhdWQiOiJhcGk6Ly9hdXRoLW1pbmVjcmFmdC1zZXJ2aWNlcy9tdWx0aXBsYXllciIsImV4cCI6MTgwMDAwMzYwMCwibmJmIjoxNzk5OTk2NDAwLCJpYXQiOjE3OTk5OTY0MDAsInhpZCI6IjI1MzMyNzQ3OTk5OTk5OTkiLCJ4bmFtZSI6IlZlcmlmaWVkIiwidGlkIjoiMjBDQTIiLCJtaWQiOiJhYmMiLCJjcGsiOiJNSFl3RUFZSEtvWkl6ajBDQVFZRks0RUVBQ0lEWWdBRWFxa0IxYVkyQisyRk9DVTgvZTNKQXp4Q0R3dDR2NTJ4WlFsSXVFWDRvKzh4YVdNTmRiMmxvTnpaQ0VvTmYycFZaUzNKdTZ5c1ZEOVpXNVBlWUFRUkhaWGhsdndtSFZETFpEWmFvb0JOUjFjYm54T1lIc1A4T1dHNVZralhubHdQIn0.PXUwBOTg3eMNxrnSZY6VxwgeVOmc-MmSeTQ159zpydNJ7WKbTNH_5BSY5B0_DkOIE6hetkS8EmXZt5gCtpk7zoh_5klnVBdgNC8jpDQwzv4j2plDYq4YgHsBJ8lqsbTKrENhz3miS_rUv-G_jP6V3tQHmUqrFUvVcCqEde9EcJafZTDzUavkh0KXzrDfFAjJgJIngbIENdmqo6LVGOO6X_K64LyRcmsW1bhaUbJ-5NhVwvJEx7FolREInL8TLL-hazdnQLx-p9UUUfKRtJSxZgz6kA0r2F4BeRLVtYqxjCwlyjwNCmuodgVuMQpruQ7W-LrSxe_cf5Fn3JphyIIhzQ";

const fixture_future =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE4MDAwMDM2MDAsIm5iZiI6MTgwMDAwMzYwMCwiaWF0IjoxODAwMDAzNjAwLCJ4aWQiOiIyNTMzMjc0Nzk5OTk5OTk5IiwieG5hbWUiOiJWZXJpZmllZCIsInRpZCI6IjIwQ0EyIiwibWlkIjoiYWJjIiwiY3BrIjoiTUhZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUNJRFlnQUVhcWtCMWFZMkIrMkZPQ1U4L2UzSkF6eENEd3Q0djUyeFpRbEl1RVg0bys4eGFXTU5kYjJsb056WkNFb05mMnBWWlMzSnU2eXNWRDlaVzVQZVlBUVJIWlhobHZ3bUhWRExaRFphb29CTlIxY2JueE9ZSHNQOE9XRzVWa2pYbmx3UCJ9.v88soSDvRRXAABokh7-e5SUYXlCOZxPLCufhm1JlyUl218SRP2qSS5e98i7DGbaiqb3mGDGO4HRfe3jlYWvpmdLXxiZkyUS2dLu08sFpq0jkSIbLN6OtPhy2ifzD1A_NoBKvEUMz43tltegLTF6e_QJSVvIIsb0nsIPcXFbJryvbnuxk8at-4rUyDELYQGiP9UJjqrzA-6BSbsrpj8cCtdgH1wgEKAhI5GwdJ843ob-tA542v2Tc0U2YcnAJe67m34JbJRlOkPi1wFT6a6P_D-fcB6uOB4WWqo2O5EIKGNE4dwVVgHvzu6g1ubCD-cYcJcPRy0Md4YwpQlheS9C4nQ";

const fixture_no_xuid =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE4MDAwMDM2MDAsIm5iZiI6MTc5OTk5NjQwMCwiaWF0IjoxNzk5OTk2NDAwLCJ4bmFtZSI6IlZlcmlmaWVkIiwidGlkIjoiMjBDQTIiLCJtaWQiOiJhYmMiLCJjcGsiOiJNSFl3RUFZSEtvWkl6ajBDQVFZRks0RUVBQ0lEWWdBRWFxa0IxYVkyQisyRk9DVTgvZTNKQXp4Q0R3dDR2NTJ4WlFsSXVFWDRvKzh4YVdNTmRiMmxvTnpaQ0VvTmYycFZaUzNKdTZ5c1ZEOVpXNVBlWUFRUkhaWGhsdndtSFZETFpEWmFvb0JOUjFjYm54T1lIc1A4T1dHNVZralhubHdQIn0.684DDM6hBg4ycVjtzBrFdfWeg6m44fNB4krEUFbWbHl2l4PRPVPqZx2NJQpPPA-RJXaaPTIaAs829sI4Y5uKPjqGQSC7Iq632cYPSnTYsahQ66JRYbEAmh4die-Ej82mHqQvBKwIWKH582M-bDeq24lUeLO66FWON7gSTlpk5U3t51LC6tdBNGxg1ZWmwcpw5sefQZlgurgEWelKWQA4Y-bYvR3UQGZCtW4ArBy_q2MuT-1m-zwlWbNsqJaoiHdFBeuM3Rj_GsC0qk9uYiI8t4Nf0_OPM4hrMHas-TpsAVYknm0kcqNCKyoBphvZFgvHlPWr4avgTu_obYUzoiBM7A";

const fixture_bad_name =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE4MDAwMDM2MDAsIm5iZiI6MTc5OTk5NjQwMCwiaWF0IjoxNzk5OTk2NDAwLCJ4aWQiOiIyNTMzMjc0Nzk5OTk5OTk5IiwieG5hbWUiOiIxYmFkIG5hbWUiLCJ0aWQiOiIyMENBMiIsIm1pZCI6ImFiYyIsImNwayI6Ik1IWXdFQVlIS29aSXpqMENBUVlGSzRFRUFDSURZZ0FFYXFrQjFhWTJCKzJGT0NVOC9lM0pBenhDRHd0NHY1MnhaUWxJdUVYNG8rOHhhV01OZGIybG9OelpDRW9OZjJwVlpTM0p1NnlzVkQ5Wlc1UGVZQVFSSFpYaGx2d21IVkRMWkRaYW9vQk5SMWNibnhPWUhzUDhPV0c1VmtqWG5sd1AifQ.uHFBMjtwf9BWIR473WgCmCKTV6y-Q7F_L_oPJOUSY7HW8-HiS0mI_GiIAxN8nBlhGr2TsjOSzPEKJNYSTc8UVXFZVho8P_qbx5WL2dqCebbG6BipO12bqKhvSsu8GBsTlS_ZcRlYMMJPUpW_fK735n_UHv8u2NDkoEsnsl76nPF_TWB-m_OImRB9nLMHEIz36CR2nJU5X8Z0_bjvaFrt2pEdnLm_J3GlhuSgTV-mdNEYBV_MQDp9T2EpnaQ1q2Ss1lNzrt9Nc_jyiiow6sjHKhe6GahZ-BfwT0oj7CaoKfEQMZknt-MyJhD1PtEeN06ajUAj4TIiA4y3zL6Vj5WldQ";

const fixture_foreign =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Qta2V5LTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24uZnJhbmNoaXNlLm1pbmVjcmFmdC1zZXJ2aWNlcy5uZXQvIiwiYXVkIjoiYXBpOi8vYXV0aC1taW5lY3JhZnQtc2VydmljZXMvbXVsdGlwbGF5ZXIiLCJleHAiOjE4MDAwMDM2MDAsIm5iZiI6MTc5OTk5NjQwMCwiaWF0IjoxNzk5OTk2NDAwLCJ4aWQiOiIyNTMzMjc0Nzk5OTk5OTk5IiwieG5hbWUiOiJWZXJpZmllZCIsInRpZCI6IjIwQ0EyIiwibWlkIjoiYWJjIiwiY3BrIjoiTUhZd0VBWUhLb1pJemowQ0FRWUZLNEVFQUNJRFlnQUVhcWtCMWFZMkIrMkZPQ1U4L2UzSkF6eENEd3Q0djUyeFpRbEl1RVg0bys4eGFXTU5kYjJsb056WkNFb05mMnBWWlMzSnU2eXNWRDlaVzVQZVlBUVJIWlhobHZ3bUhWRExaRFphb29CTlIxY2JueE9ZSHNQOE9XRzVWa2pYbmx3UCJ9.o_Yl3gu1Y0lhBHUE_94lZYrhZWkhe_ZURfUvsm8CqFlba4EnJUOvNTETMPrkGNphZlGsn5MmNPo2YluwPD2oAI2UqmGteU9y2zM0q0SpX2IlguVKptL2MfbwTEvbRFe1zyqEIlFdQYQEoF2qWZvNvg3VDRK4cm8hfJCGb0Lbzm-_hugAFDHv1vTMzxW_koyVM6cS1x89Gd5tWmyUGjBp34ugefsz3y7h9MR6js-XCU5aXGL244qMI0xHiRz-Al65fweI3Oa4OPvqa0eiw5rvGJH72_LjuSDiac7Zku3g9WOKLjxxLHjwembejcPXAk1GT25yeuc4AzmhnC8IHr1iHg";

const fixture_client_data =
    "eyJhbGciOiJFUzM4NCIsIng1dSI6Ik1IWXdFQVlIS29aSXpqMENBUVlGSzRFRUFDSURZZ0FFYXFrQjFhWTJCKzJGT0NVOC9lM0pBenhDRHd0NHY1MnhaUWxJdUVYNG8rOHhhV01OZGIybG9OelpDRW9OZjJwVlpTM0p1NnlzVkQ5Wlc1UGVZQVFSSFpYaGx2d21IVkRMWkRaYW9vQk5SMWNibnhPWUhzUDhPV0c1VmtqWG5sd1AifQ.eyJTa2luSWQiOiJTdGFuZGFyZF9DdXN0b20iLCJEZXZpY2VPUyI6N30.l_frRtWvq-U79wee4y9XsbH6dt597wa2oCAEH--dPtWiATOM3JWiRJSX2V6Blg3_J6RkHUzVjlebRxlJfIFRWcWNwVmbACrp_BQECZmru863jrLssrcBlSut6XXZPnqx";
