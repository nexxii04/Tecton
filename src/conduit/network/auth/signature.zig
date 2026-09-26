const std = @import("std");

const P384 = std.crypto.ecc.P384;
const EcdsaP384Sha384 = std.crypto.sign.ecdsa.EcdsaP384Sha384;
const Sha384 = std.crypto.hash.sha2.Sha384;
const rsa = std.crypto.Certificate.rsa;

/// DER prefix of a SubjectPublicKeyInfo carrying an uncompressed secp384r1 point.
pub const secp384r1_spki_prefix = [_]u8{
    0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86,
    0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b,
    0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
};

pub const Error = error{
    InvalidBase64,
    UnsupportedKeyFormat,
    InvalidPublicKey,
};

/// A P-384 key kept as its uncompressed sec1 point, so encodings compare equal.
pub const Secp384PublicKey = struct {
    const sec1_length = 97;
    const spki_length = secp384r1_spki_prefix.len + sec1_length;

    bytes: [sec1_length]u8,

    pub fn fromSec1(sec1: []const u8) Error!Secp384PublicKey {
        if (sec1.len != sec1_length or sec1[0] != 0x04) return error.UnsupportedKeyFormat;
        var self: Secp384PublicKey = undefined;
        @memcpy(&self.bytes, sec1);
        _ = P384.fromSec1(&self.bytes) catch return error.InvalidPublicKey;
        return self;
    }

    pub fn fromBase64(encoded: []const u8) Error!Secp384PublicKey {
        var buffer: [spki_length + 8]u8 = undefined;
        const decoder = std.base64.standard;
        const len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
        if (len != sec1_length and len != spki_length) return error.UnsupportedKeyFormat;
        decoder.Decoder.decode(buffer[0..len], encoded) catch return error.InvalidBase64;

        if (len == sec1_length) return fromSec1(buffer[0..sec1_length]);

        if (!std.mem.eql(u8, buffer[0..secp384r1_spki_prefix.len], &secp384r1_spki_prefix)) {
            return error.UnsupportedKeyFormat;
        }
        return fromSec1(buffer[secp384r1_spki_prefix.len..][0..sec1_length]);
    }

    pub fn eql(a: Secp384PublicKey, b: Secp384PublicKey) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn verifyEs384(self: Secp384PublicKey, signature: []const u8, signed_data: []const u8) bool {
        if (signature.len != 96) return false;
        const public_key = EcdsaP384Sha384.PublicKey.fromSec1(&self.bytes) catch return false;
        const sig = EcdsaP384Sha384.Signature.fromBytes(signature[0..96].*);

        var hash: [Sha384.digest_length]u8 = undefined;
        Sha384.hash(signed_data, &hash, .{});
        sig.verifyPrehashed(hash, public_key) catch return false;
        return true;
    }
};

pub const rsa_modulus_lengths = [_]usize{ 256, 384, 512 };

pub fn verifyRs256(modulus: []const u8, exponent: []const u8, signature: []const u8, signed_data: []const u8) bool {
    const public_key = rsa.PublicKey.fromBytes(exponent, modulus) catch return false;
    inline for (rsa_modulus_lengths) |length| {
        if (modulus.len == length) return verifyPkcs1Sha256(length, public_key, signature, signed_data);
    }
    return false;
}

fn verifyPkcs1Sha256(
    comptime length: usize,
    public_key: rsa.PublicKey,
    signature: []const u8,
    signed_data: []const u8,
) bool {
    if (signature.len != length) return false;
    var sig: [length]u8 = undefined;
    @memcpy(&sig, signature[0..length]);
    rsa.PKCS1v1_5Signature.verify(length, sig, signed_data, public_key, std.crypto.hash.sha2.Sha256) catch return false;
    return true;
}

const testing = std.testing;

test "a sec1 point round-trips through the spki encoding" {
    const secret = EcdsaP384Sha384.SecretKey.fromBytes([_]u8{7} ** 48) catch unreachable;
    const key_pair = EcdsaP384Sha384.KeyPair.fromSecretKey(secret) catch unreachable;
    const sec1 = key_pair.public_key.toUncompressedSec1();

    const from_sec1 = try Secp384PublicKey.fromSec1(&sec1);
    try testing.expect(Secp384PublicKey.eql(from_sec1, from_sec1));

    var spki: [120]u8 = undefined;
    @memcpy(spki[0..secp384r1_spki_prefix.len], &secp384r1_spki_prefix);
    @memcpy(spki[secp384r1_spki_prefix.len..], &sec1);

    var encoded: [std.base64.standard.Encoder.calcSize(spki.len)]u8 = undefined;
    const from_spki = try Secp384PublicKey.fromBase64(std.base64.standard.Encoder.encode(&encoded, &spki));
    try testing.expect(Secp384PublicKey.eql(from_sec1, from_spki));
}

test "a point that is not on the curve is refused" {
    var sec1 = [_]u8{0} ** 97;
    sec1[0] = 0x04;
    try testing.expectError(error.InvalidPublicKey, Secp384PublicKey.fromSec1(&sec1));
    try testing.expectError(error.UnsupportedKeyFormat, Secp384PublicKey.fromSec1(&[_]u8{0x02} ++ [_]u8{0} ** 96));
}

test "an es384 signature verifies only over the bytes that were signed" {
    const secret = EcdsaP384Sha384.SecretKey.fromBytes([_]u8{9} ** 48) catch unreachable;
    const key_pair = EcdsaP384Sha384.KeyPair.fromSecretKey(secret) catch unreachable;
    const public_key = try Secp384PublicKey.fromSec1(&key_pair.public_key.toUncompressedSec1());

    const signed_data = "eyJhbGciOiJFUzM4NCJ9.eyJ4aWQiOiIxMjMifQ";
    const signature = try key_pair.sign(signed_data, null);

    try testing.expect(public_key.verifyEs384(&signature.toBytes(), signed_data));
    try testing.expect(!public_key.verifyEs384(&signature.toBytes(), "eyJhbGciOiJFUzM4NCJ9.eyJ4aWQiOiI0NTYifQ"));
    try testing.expect(!public_key.verifyEs384(&[_]u8{0} ** 96, signed_data));
    try testing.expect(!public_key.verifyEs384(&[_]u8{0} ** 95, signed_data));
}

test "rs256 rejects a signature of the wrong length and a foreign modulus size" {
    try testing.expect(!verifyRs256(&[_]u8{1} ** 100, &[_]u8{ 1, 0, 1 }, &[_]u8{0} ** 256, "signed"));
    try testing.expect(!verifyRs256(&[_]u8{1} ** 256, &[_]u8{ 1, 0, 1 }, &[_]u8{0} ** 255, "signed"));
}
