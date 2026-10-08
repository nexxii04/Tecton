const std = @import("std");

const signature = @import("signature.zig");

pub const root_public_key_base64 =
    "MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAECRXueJeTDqNRRgJi/vlRufByu/2G0i2Ebt6YMar5QX/R0DIIyrJMcUpruK4QveTfJSTp3Shlq4Gk34cD/4GUWwkv0DVuzeuB+tXija7HBxii03NHDbPAD0AKnLr2wdAp";

pub const spki_length = signature.secp384r1_spki_prefix.len + 97;

const decoded_spki: [spki_length]u8 = blk: {
    var buffer: [spki_length]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(root_public_key_base64) catch
        @compileError("the pinned Mojang root key is not valid base64");
    if (size != spki_length) {
        @compileError("the pinned Mojang root key is not a secp384r1 SubjectPublicKeyInfo");
    }
    _ = std.base64.standard.Decoder.decode(&buffer, root_public_key_base64) catch
        @compileError("the pinned Mojang root key is not valid base64");
    break :blk buffer;
};

pub fn rootPublicKey() signature.Secp384PublicKey {
    return .{ .bytes = decoded_spki[signature.secp384r1_spki_prefix.len..][0..97].* };
}

const testing = std.testing;

test "the pinned root key is a secp384r1 point on the curve" {
    try testing.expect(std.mem.eql(
        u8,
        decoded_spki[0..signature.secp384r1_spki_prefix.len],
        &signature.secp384r1_spki_prefix,
    ));
    try testing.expectEqual(@as(u8, 0x04), decoded_spki[signature.secp384r1_spki_prefix.len]);

    _ = try signature.Secp384PublicKey.fromSec1(&rootPublicKey().bytes);
    try testing.expectEqual(@as(usize, 160), root_public_key_base64.len);
}

test "the anchor decodes from its base64 spelling to the same point" {
    const from_base64 = try signature.Secp384PublicKey.fromBase64(root_public_key_base64);
    try testing.expect(signature.Secp384PublicKey.eql(rootPublicKey(), from_base64));
}
