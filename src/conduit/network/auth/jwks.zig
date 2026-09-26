const std = @import("std");

const signature = @import("signature.zig");

pub const Error = error{
    InvalidJwks,
    NoUsableKeys,
};

pub const Key = struct {
    kid: []const u8,
    modulus: []const u8,
    exponent: []const u8,

    pub fn verify(self: *const Key, token_signature: []const u8, signed_data: []const u8) bool {
        return signature.verifyRs256(self.modulus, self.exponent, token_signature, signed_data);
    }
};

pub const KeySet = struct {
    allocator: std.mem.Allocator,
    keys: []Key,

    pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !KeySet {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
            return error.InvalidJwks;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidJwks;
        const list = parsed.value.object.get("keys") orelse return error.InvalidJwks;
        if (list != .array) return error.InvalidJwks;

        var keys: std.ArrayList(Key) = .empty;
        errdefer {
            for (keys.items) |key| deinitKey(allocator, key);
            keys.deinit(allocator);
        }

        for (list.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            if (try stringField(object, "kty")) |kty| {
                if (!std.mem.eql(u8, kty, "RSA")) continue;
            } else continue;
            if (try stringField(object, "use")) |use| {
                if (!std.mem.eql(u8, use, "sig")) continue;
            }
            const kid = (try stringField(object, "kid")) orelse continue;
            const modulus_b64 = (try stringField(object, "n")) orelse continue;
            const exponent_b64 = (try stringField(object, "e")) orelse continue;

            const modulus = decodeBase64Url(allocator, modulus_b64) catch continue;
            errdefer allocator.free(modulus);
            const exponent = decodeBase64Url(allocator, exponent_b64) catch {
                allocator.free(modulus);
                continue;
            };
            errdefer allocator.free(exponent);

            const owned_kid = try allocator.dupe(u8, kid);
            errdefer allocator.free(owned_kid);
            try keys.append(allocator, .{
                .kid = owned_kid,
                .modulus = modulus,
                .exponent = exponent,
            });
        }

        if (keys.items.len == 0) return error.NoUsableKeys;
        return .{ .allocator = allocator, .keys = try keys.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *KeySet) void {
        for (self.keys) |key| deinitKey(self.allocator, key);
        self.allocator.free(self.keys);
    }

    pub fn find(self: *const KeySet, kid: []const u8) ?*const Key {
        for (self.keys) |*key| {
            if (std.mem.eql(u8, key.kid, kid)) return key;
        }
        return null;
    }

    pub fn kidCount(self: *const KeySet) usize {
        return self.keys.len;
    }
};

fn deinitKey(allocator: std.mem.Allocator, key: Key) void {
    allocator.free(key.kid);
    allocator.free(key.modulus);
    allocator.free(key.exponent);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn decodeBase64Url(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidBase64;
    return decoded;
}

const testing = std.testing;

const service_document =
    \\{"keys":[
    \\{"kty":"RSA","use":"sig","kid":"472E53B520276E1F3B6BA6F95EBF09D61C2568BE",
    \\ "x5t":"472E53B520276E1F3B6BA6F95EBF09D61C2568BE",
    \\ "n":"-nr2A74AK1-AqrGPw5VCFpznoWDIH9AGinoFRsIdakvsauqblvC30ZkzUi6p1_4009aV_Wn1e4M-V98-Rpj1SEyK1EiQoj5DRMmye3an-3NfHKB8SoXl1TvQSYCYBkLN-TTz27aHYsL3eR3xFRvcmJ0Pr37BFlkf0x3aWp3zuH3-qTY08M5M39IY1mBR0k3DVB7MAeJ6dEcjeVclI3-Fc9-qr6qtG9m8PssWt_Q0jKr2RXPhvAPjd7UOYjjWVySR6sL7IoPUDO5ITElUI9XPpNCrUaP2Ig5ytfAgYqdAMAZsScDdSnJXuQ5gd2p8TkTGB3Y5vD9upnfrtQP8d7PmjQ",
    \\ "e":"AQAB"},
    \\{"kty":"EC","use":"sig","kid":"ignored","crv":"P-384","x":"AA","y":"AA"}
    \\]}
;

test "a jwks document yields the rsa signing keys only" {
    const allocator = testing.allocator;
    var set = try KeySet.parse(allocator, service_document);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 1), set.kidCount());
    const key = set.find("472E53B520276E1F3B6BA6F95EBF09D61C2568BE").?;
    try testing.expectEqual(@as(usize, 256), key.modulus.len);
    try testing.expectEqualStrings(&[_]u8{ 1, 0, 1 }, key.exponent);
    try testing.expectEqual(@as(?*const Key, null), set.find("unknown"));
}

test "a jwks document without any usable key is refused" {
    const allocator = testing.allocator;
    try testing.expectError(error.NoUsableKeys, KeySet.parse(allocator, "{\"keys\":[]}"));
    try testing.expectError(error.NoUsableKeys, KeySet.parse(
        allocator,
        "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"a\",\"n\":\"!!!\",\"e\":\"AQAB\"}]}",
    ));
    try testing.expectError(error.InvalidJwks, KeySet.parse(allocator, "[]"));
    try testing.expectError(error.InvalidJwks, KeySet.parse(allocator, "{\"keys\":\"no\"}"));
}
