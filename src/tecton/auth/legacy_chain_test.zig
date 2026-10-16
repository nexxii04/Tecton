pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const signature = scope.signature;
        const identity = scope.identity;
        const issuer = scope.issuer;
        const verify = scope.verify;
        const testing = scope.testing;
        const testKey = scope.testKey;
        const spkiOf = scope.spkiOf;
        const signToken = scope.signToken;
        const buildChain = scope.buildChain;
        const SecpKey = scope.SecpKey;
        const private_secpkey_public = scope.private_secpkey_public;
        pub fn case_000() !void {
            const allocator = testing.allocator;
            const now: i64 = 1800000000;

            const anchor = testKey(1);
            const client = testKey(3);
            const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", now);
            defer scope.chain_deinit(chain, allocator);

            var result = try verify(allocator, scope.chain_slice(&chain), try private_secpkey_public(anchor), now);
            defer result.identity.deinit(allocator);

            const expected_uuid = try identity.uuidFromXuid(allocator, "2533274799999999");
            defer allocator.free(expected_uuid);

            try testing.expectEqualStrings("2533274799999999", result.identity.xuid);
            try testing.expectEqualStrings("Verified", result.identity.display_name);
            try testing.expectEqualStrings(expected_uuid, result.identity.uuid);
            try testing.expectEqualStrings("896928775", result.identity.title_id);
            try testing.expectEqual(identity.Source.legacy_chain, result.identity.source);
            try testing.expect(signature.Secp384PublicKey.eql(result.client_public_key, try private_secpkey_public(client)));
        }

        pub fn case_001() !void {
            const allocator = testing.allocator;
            const now: i64 = 1800000000;

            const anchor = testKey(1);
            const forger = testKey(9);
            const client = testKey(3);
            const chain = try buildChain(allocator, forger, forger, client, "2533274799999999", now);
            defer scope.chain_deinit(chain, allocator);

            try testing.expectError(
                error.NotAnchoredAtRoot,
                verify(allocator, scope.chain_slice(&chain), try private_secpkey_public(anchor), now),
            );
            var result = try verify(allocator, scope.chain_slice(&chain), try private_secpkey_public(forger), now);
            defer result.identity.deinit(allocator);
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;
            const now: i64 = 1800000000;

            const anchor = testKey(1);
            const client = testKey(3);
            const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", now);
            defer scope.chain_deinit(chain, allocator);

            const swapped = [_][]const u8{ chain.tokens[0], chain.tokens[2], chain.tokens[1] };
            try testing.expectError(error.InvalidSignature, verify(allocator, &swapped, try private_secpkey_public(anchor), now));
        }

        pub fn case_003() !void {
            const allocator = testing.allocator;

            const anchor = testKey(1);
            const client = testKey(3);
            const expired_at: i64 = 1800000000;
            const chain = try buildChain(allocator, anchor, anchor, client, "2533274799999999", expired_at);
            defer scope.chain_deinit(chain, allocator);

            try testing.expectError(
                error.ExpiredToken,
                verify(allocator, scope.chain_slice(&chain), try private_secpkey_public(anchor), expired_at + 7200),
            );
            try testing.expectError(
                error.UnexpectedChainLength,
                verify(allocator, scope.chain_slice(&chain)[0..2], try private_secpkey_public(anchor), expired_at),
            );
            try testing.expectError(
                error.EmptyChain,
                verify(allocator, &.{}, try private_secpkey_public(anchor), expired_at),
            );
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;
            const now: i64 = 1800000000;

            const anchor = testKey(1);
            const client = testKey(3);
            const chain = try buildChain(allocator, anchor, anchor, client, "", now);
            defer scope.chain_deinit(chain, allocator);

            try testing.expectError(
                error.IdentityMismatch,
                verify(allocator, scope.chain_slice(&chain), try private_secpkey_public(anchor), now),
            );
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;
            const now: i64 = 1800000000;

            const client = testKey(3);
            const client_key = try private_secpkey_public(client);
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
                verify(allocator, &.{token}, try private_secpkey_public(testKey(1)), now),
            );
        }
    };
}
