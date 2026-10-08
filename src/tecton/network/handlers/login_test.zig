pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const offline_identity = scope.offline_identity;
        const applyOfflineIdentity = scope.applyOfflineIdentity;
        const applyVerifiedIdentity = scope.applyVerifiedIdentity;
        const Policy = scope.Policy;
        const policyFor = scope.policyFor;
        const chainTokens = scope.chainTokens;
        const testing = scope.testing;
        const testJwt = scope.testJwt;
        const testChain = scope.testChain;
        const testVerified = scope.testVerified;

        pub fn case_000() !void {
            const allocator = testing.allocator;
            const victim_uuid = "00000000-0000-4000-8000-000000000123";
            const victim_xuid = "2533274799999999";

            const tokens = try testChain(allocator, victim_xuid, "LoadBot", victim_uuid);
            defer allocator.free(tokens.chain);
            defer allocator.free(tokens.client);

            var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
            defer data.deinit();

            try testing.expectEqualStrings(victim_uuid, data.identity_data.identity);
            try testing.expectEqualStrings(victim_xuid, data.identity_data.xuid);

            try applyOfflineIdentity(allocator, &data);

            const expected = try offline_identity.uuidForDisplayName(allocator, "LoadBot");
            defer allocator.free(expected);

            try testing.expectEqualStrings(expected, data.identity_data.identity);
            try testing.expect(!std.mem.eql(u8, victim_uuid, data.identity_data.identity));
            try testing.expectEqual(@as(usize, 0), data.identity_data.xuid.len);
            try testing.expectEqualStrings("LoadBot", data.identity_data.display_name);
        }

        pub fn case_001() !void {
            const allocator = testing.allocator;

            const first = try testChain(allocator, "2533274799999999", "Steve", null);
            defer allocator.free(first.chain);
            defer allocator.free(first.client);
            const second = try testChain(allocator, "9999999999999999", "Steve", "00000000-0000-4000-8000-000000000456");
            defer allocator.free(second.chain);
            defer allocator.free(second.client);

            var first_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, first.chain, first.client);
            defer first_data.deinit();
            var second_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, second.chain, second.client);
            defer second_data.deinit();

            try applyOfflineIdentity(allocator, &first_data);
            try applyOfflineIdentity(allocator, &second_data);

            try testing.expectEqualStrings(first_data.identity_data.identity, second_data.identity_data.identity);
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;
            const tokens = try testChain(allocator, "9999999999999999", "Victim", "00000000-0000-4000-8000-000000000123");
            defer allocator.free(tokens.chain);
            defer allocator.free(tokens.client);

            var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
            defer data.deinit();

            var verified = try testVerified(allocator);
            defer verified.deinit(allocator);
            try applyVerifiedIdentity(allocator, &data, &verified);

            try testing.expectEqualStrings("2533274799999999", data.identity_data.xuid);
            try testing.expectEqualStrings("Verified", data.identity_data.display_name);
            try testing.expectEqualStrings(verified.identity.uuid, data.identity_data.identity);
            try testing.expectEqualStrings("20CA2", data.identity_data.title_id);
            try testing.expect(!std.mem.eql(u8, "00000000-0000-4000-8000-000000000123", data.identity_data.identity));
        }

        pub fn case_003() !void {
            try testing.expectEqual(Policy.offline, policyFor(false, false));
            try testing.expectEqual(Policy.offline, policyFor(false, true));
            try testing.expectEqual(Policy.reject, policyFor(true, false));
            try testing.expectEqual(Policy.offline, policyFor(true, true));
        }

        pub fn case_004() !void {
            const allocator = testing.allocator;

            const oidc = try testChain(allocator, "2533274799999999", "Steve", null);
            defer allocator.free(oidc.chain);
            defer allocator.free(oidc.client);
            var oidc_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, oidc.chain, oidc.client);
            defer oidc_data.deinit();
            try testing.expectEqual(@as(usize, 0), (try chainTokens(allocator, &oidc_data)).len);

            const last = try testJwt(
                allocator,
                "{\"identityPublicKey\":\"AQ==\",\"extraData\":{\"XUID\":\"2533274799999999\"," ++
                    "\"displayName\":\"Steve\",\"identity\":\"00000000-0000-4000-8000-000000000001\",\"titleId\":\"89692877\"}}",
            );
            defer allocator.free(last);
            const chain_json = try std.fmt.allocPrint(
                allocator,
                "{{\"AuthenticationType\":2,\"Certificate\":\"{{\\\"chain\\\":[\\\"first\\\",\\\"{s}\\\"]}}\"}}",
                .{last},
            );
            defer allocator.free(chain_json);

            var chain_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, chain_json, oidc.client);
            defer chain_data.deinit();
            const tokens = try chainTokens(allocator, &chain_data);
            defer allocator.free(tokens);
            try testing.expectEqual(@as(usize, 2), tokens.len);
            try testing.expectEqualStrings("first", tokens[0]);
            try testing.expectEqualStrings(last, tokens[1]);
        }

        pub fn case_005() !void {
            const allocator = testing.allocator;

            const tokens = try testChain(allocator, "2533274799999999", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", null);
            defer allocator.free(tokens.chain);
            defer allocator.free(tokens.client);

            var data = try Protocol.Login.Decoder.decodeLoginChain(allocator, tokens.chain, tokens.client);
            defer data.deinit();

            try testing.expectError(error.DisplayNameTooLong, applyOfflineIdentity(allocator, &data));
            try testing.expectEqual(@as(usize, 36), data.identity_data.identity.len);
        }
    };
}
