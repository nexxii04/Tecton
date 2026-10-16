pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const jwks = scope.jwks;
        const jwt = scope.jwt;
        const default_refresh_min_interval_seconds = scope.default_refresh_min_interval_seconds;
        const LoginMaterial = scope.LoginMaterial;
        const AuthService = scope.AuthService;
        const authEnvironment = scope.authEnvironment;
        const withTrailingSlash = scope.withTrailingSlash;
        const testing = scope.testing;
        const stub_fetch_calls = scope.stub_fetch_calls;
        const stubFetcher = scope.stubFetcher;
        const tokenWithKeyId = scope.tokenWithKeyId;

        pub fn case_000() !void {
            const allocator = testing.allocator;
            var document = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                \\{"result":{"serviceEnvironments":{
                \\"store":{"prod":{"serviceUri":"https://store.mctest"}},
                \\"auth":{"prod":{"serviceUri":"https://authorization.test","issuer":"https://authorization.test","playfabTitleId":"20CA2"}}}}}
            ,
                .{},
            );
            defer document.deinit();

            const result = document.value.object.get("result").?;
            const auth = try authEnvironment(result);
            try testing.expectEqualStrings("https://authorization.test", (try jwt.stringClaim(auth, "issuer")).?);

            const missing = try std.json.parseFromSlice(std.json.Value, allocator, "{\"result\":{}}", .{});
            defer missing.deinit();
            try testing.expectError(
                error.MissingAuthEnvironment,
                authEnvironment(missing.value.object.get("result").?),
            );
        }

        pub fn case_001() !void {
            const allocator = testing.allocator;
            stub_fetch_calls.* = 0;

            const keys = try jwks.KeySet.parse(allocator, "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"present\",\"n\":\"AQAB\",\"e\":\"AQAB\"}]}");
            var service = try AuthService.init(testing.io, allocator, .{
                .issuer = "https://authorization.test",
                .jwks_uri = "https://authorization.test/.well-known/keys",
                .keys = keys,
                .fetcher = stubFetcher,
            });
            defer service.deinit();

            const multiplayer_token = try tokenWithKeyId(allocator, "missing");
            defer allocator.free(multiplayer_token);

            const material = LoginMaterial{
                .authentication_type = 2,
                .chain = &.{},
                .multiplayer_token = multiplayer_token,
                .client_data_token = "",
            };

            try testing.expectError(error.UnknownKeyId, service.verifyLogin(material, 1000));
            try testing.expectEqual(@as(usize, 1), stub_fetch_calls.*);

            try testing.expectError(error.UnknownKeyId, service.verifyLogin(material, 1000));
            try testing.expectEqual(@as(usize, 1), stub_fetch_calls.*);

            try testing.expectError(error.UnknownKeyId, service.verifyLogin(material, 1000 + default_refresh_min_interval_seconds));
            try testing.expectEqual(@as(usize, 2), stub_fetch_calls.*);
        }

        pub fn case_002() !void {
            const allocator = testing.allocator;
            stub_fetch_calls.* = 0;

            const keys = try jwks.KeySet.parse(allocator, "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"present\",\"n\":\"AQAB\",\"e\":\"AQAB\"}]}");
            var service = try AuthService.init(testing.io, allocator, .{
                .issuer = "https://authorization.test",
                .jwks_uri = "https://authorization.test/.well-known/keys",
                .keys = keys,
                .fetcher = stubFetcher,
            });
            defer service.deinit();

            const multiplayer_token = try tokenWithKeyId(allocator, "missing");
            defer allocator.free(multiplayer_token);

            try testing.expectError(error.NothingToVerify, service.verifyLogin(.{
                .authentication_type = 1,
                .chain = &.{},
                .multiplayer_token = multiplayer_token,
                .client_data_token = "",
            }, 1000));
            try testing.expectEqual(@as(usize, 0), stub_fetch_calls.*);

            try testing.expectError(error.NothingToVerify, service.verifyLogin(.{
                .authentication_type = 0,
                .chain = &.{},
                .multiplayer_token = null,
                .client_data_token = "",
            }, 1000));
            try testing.expectEqual(@as(usize, 0), stub_fetch_calls.*);
        }

        pub fn case_003() !void {
            const allocator = testing.allocator;
            const normalised = try withTrailingSlash(allocator, "https://authorization.test");
            defer allocator.free(normalised);
            try testing.expectEqualStrings("https://authorization.test/", normalised);

            const kept = try withTrailingSlash(allocator, "https://authorization.test/");
            defer allocator.free(kept);
            try testing.expectEqualStrings("https://authorization.test/", kept);
        }
    };
}
