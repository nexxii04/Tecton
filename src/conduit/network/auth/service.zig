const std = @import("std");

const Raknet = @import("Raknet");
const Protocol = @import("protocol");

const identity = @import("identity.zig");
const jwks = @import("jwks.zig");
const jwt = @import("jwt.zig");
const legacy = @import("legacy-chain.zig");
const mojang_root_key = @import("mojang-root-key.zig");
const oidc = @import("oidc.zig");
const signature = @import("signature.zig");
const wire = @import("wire.zig");

pub const default_discovery_url = "https://client.discovery.minecraft-services.net";
pub const default_application_type = "MinecraftPE";
/// Refetched when a token names an unknown key id. The id is attacker-controlled,
/// so it can trigger at most one refetch per interval.
pub const default_refresh_min_interval_seconds: i64 = 60;
pub const supported_signing_algorithm = "RS256";

pub const Error = error{
    DiscoveryFailed,
    MissingAuthEnvironment,
    ConfigurationFailed,
    UnsupportedSigningAlgorithm,
    KeyFetchFailed,
    NothingToVerify,
    OutOfMemory,
} || wire.Error || jwks.Error || oidc.Error || legacy.Error;

pub const KeyFetcher = *const fn (*wire.HttpClient, std.mem.Allocator, []const u8) Error!jwks.KeySet;

pub const Options = struct {
    discovery_url: []const u8 = default_discovery_url,
    application_type: []const u8 = default_application_type,
    game_version: []const u8 = Protocol.MINECRAFT_VERSION,
    refresh_min_interval_seconds: i64 = default_refresh_min_interval_seconds,
    issuer: ?[]const u8 = null,
    jwks_uri: ?[]const u8 = null,
    keys: ?jwks.KeySet = null,
    anchor: ?signature.Secp384PublicKey = null,
    fetcher: KeyFetcher = fetchKeys,
};

pub const LoginMaterial = struct {
    authentication_type: i64,
    chain: []const []const u8,
    multiplayer_token: ?[]const u8,
    client_data_token: []const u8,
};

pub const Verified = identity.Verified;

const guest_authentication_type: i64 = 1;

/// Verifies logins; only `init` and `refreshKeys` touch the network.
pub const AuthService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: wire.HttpClient,
    issuer: []const u8,
    jwks_uri: []const u8,
    keys: jwks.KeySet,
    keys_fetched_at: i64,
    refresh_min_interval_seconds: i64,
    anchor: signature.Secp384PublicKey,
    fetcher: KeyFetcher,
    lock: std.Io.RwLock = .init,
    refresh_lock: std.Io.Mutex = .init,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) Error!AuthService {
        var http = wire.HttpClient.init(allocator, io);
        errdefer http.deinit();

        const issuer = try resolveIssuer(&http, allocator, options);
        errdefer allocator.free(issuer);

        const jwks_uri = try resolveJwksUri(&http, allocator, issuer, options);
        errdefer allocator.free(jwks_uri);

        const keys = options.keys orelse try fetchKeys(&http, allocator, jwks_uri);
        errdefer {
            var owned = keys;
            owned.deinit();
        }

        return .{
            .allocator = allocator,
            .io = io,
            .http = http,
            .issuer = issuer,
            .jwks_uri = jwks_uri,
            .keys = keys,
            .keys_fetched_at = 0,
            .refresh_min_interval_seconds = options.refresh_min_interval_seconds,
            .anchor = options.anchor orelse mojang_root_key.rootPublicKey(),
            .fetcher = options.fetcher,
        };
    }

    pub fn deinit(self: *AuthService) void {
        self.allocator.free(self.issuer);
        self.allocator.free(self.jwks_uri);
        self.keys.deinit();
        self.http.deinit();
    }

    /// Every error means the login proved nothing.
    pub fn verifyLogin(self: *AuthService, material: LoginMaterial, now: i64) Error!Verified {
        if (material.authentication_type == guest_authentication_type) return error.NothingToVerify;

        if (material.multiplayer_token) |token| {
            if (token.len != 0) {
                const result = self.verifyMultiplayerToken(token, now) catch |err| switch (err) {
                    error.UnknownKeyId => blk: {
                        // Rotation or an invented key id; the interval stops a storm.
                        try self.refreshKeys(now);
                        break :blk try self.verifyMultiplayerToken(token, now);
                    },
                    else => return err,
                };
                errdefer {
                    var owned = result;
                    owned.deinit(self.allocator);
                }
                try oidc.verifyClientData(self.allocator, material.client_data_token, result.client_public_key);
                return result;
            }
        }

        if (material.chain.len > 0) {
            var result = try legacy.verify(self.allocator, material.chain, self.anchor, now);
            errdefer result.identity.deinit(self.allocator);
            // A verified login always carries the xuid of the account it proved.
            if (result.identity.xuid.len == 0) return error.NotAnchoredAtRoot;
            try oidc.verifyClientData(self.allocator, material.client_data_token, result.client_public_key);
            return result;
        }

        return error.NothingToVerify;
    }

    fn verifyMultiplayerToken(self: *AuthService, token: []const u8, now: i64) Error!Verified {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        return oidc.verify(self.allocator, token, .{
            .issuer = self.issuer,
            .keys = &self.keys,
            .now = now,
        });
    }

    fn refreshKeys(self: *AuthService, now: i64) Error!void {
        self.refresh_lock.lockUncancelable(self.io);
        defer self.refresh_lock.unlock(self.io);

        self.lock.lockSharedUncancelable(self.io);
        const rate_limited = self.keys_fetched_at != 0 and now - self.keys_fetched_at < self.refresh_min_interval_seconds;
        self.lock.unlockShared(self.io);
        if (rate_limited) return;

        const keys = try self.fetcher(&self.http, self.allocator, self.jwks_uri);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.keys.deinit();
        self.keys = keys;
        self.keys_fetched_at = now;
        Raknet.Logger.INFO("Refreshed {d} signing key(s) from the Minecraft authorization service", .{keys.kidCount()});
    }
};

fn resolveIssuer(http: *wire.HttpClient, allocator: std.mem.Allocator, options: Options) Error![]const u8 {
    if (options.issuer) |issuer| return withTrailingSlash(allocator, issuer);

    const url = std.fmt.allocPrint(
        allocator,
        "{s}/api/v1.0/discovery/{s}/builds/{s}",
        .{ options.discovery_url, options.application_type, options.game_version },
    ) catch return error.OutOfMemory;
    defer allocator.free(url);

    var document = http.getJson(url) catch return error.DiscoveryFailed;
    defer document.deinit();

    if (document.value != .object) return error.DiscoveryFailed;
    // Services answer with the payload nested under "result".
    const result = document.value.object.get("result") orelse return error.DiscoveryFailed;
    const auth = try authEnvironment(result);
    const issuer = (try jwt.stringClaim(auth, "issuer")) orelse return error.MissingAuthEnvironment;
    return withTrailingSlash(allocator, issuer);
}

fn resolveJwksUri(
    http: *wire.HttpClient,
    allocator: std.mem.Allocator,
    issuer: []const u8,
    options: Options,
) Error![]const u8 {
    if (options.jwks_uri) |uri| return allocator.dupe(u8, uri);

    const url = try std.fmt.allocPrint(allocator, "{s}.well-known/openid-configuration", .{issuer});
    defer allocator.free(url);

    var document = http.getJson(url) catch return error.ConfigurationFailed;
    defer document.deinit();
    if (document.value != .object) return error.ConfigurationFailed;

    const document_issuer = (try jwt.stringClaim(document.value, "issuer")) orelse
        return error.ConfigurationFailed;
    const normalised = try withTrailingSlash(allocator, document_issuer);
    defer allocator.free(normalised);
    if (!std.mem.eql(u8, normalised, issuer)) return error.ConfigurationFailed;

    if (try jwt.stringClaim(document.value, "jwks_uri")) |uri| {
        // An algorithm this server cannot check must not be accepted quietly.
        const algorithms = document.value.object.get("id_token_signing_alg_values_supported") orelse
            return error.UnsupportedSigningAlgorithm;
        if (algorithms != .array) return error.UnsupportedSigningAlgorithm;
        for (algorithms.array.items) |algorithm| {
            if (algorithm == .string and std.mem.eql(u8, algorithm.string, supported_signing_algorithm)) {
                return allocator.dupe(u8, uri);
            }
        }
        return error.UnsupportedSigningAlgorithm;
    }

    return error.ConfigurationFailed;
}

fn authEnvironment(discovery: std.json.Value) Error!std.json.Value {
    if (discovery != .object) return error.MissingAuthEnvironment;
    const environments = discovery.object.get("serviceEnvironments") orelse return error.MissingAuthEnvironment;
    if (environments != .object) return error.MissingAuthEnvironment;
    const auth = environments.object.get("auth") orelse return error.MissingAuthEnvironment;
    if (auth != .object) return error.MissingAuthEnvironment;
    const prod = auth.object.get("prod") orelse return error.MissingAuthEnvironment;
    if (prod != .object) return error.MissingAuthEnvironment;
    return prod;
}

fn fetchKeys(http: *wire.HttpClient, allocator: std.mem.Allocator, jwks_uri: []const u8) Error!jwks.KeySet {
    const document = http.getText(jwks_uri) catch return error.KeyFetchFailed;
    defer allocator.free(document);

    return jwks.KeySet.parse(allocator, document) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoUsableKeys => error.NoUsableKeys,
        else => error.KeyFetchFailed,
    };
}

fn withTrailingSlash(allocator: std.mem.Allocator, value: []const u8) Error![]const u8 {
    if (std.mem.endsWith(u8, value, "/")) return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "{s}/", .{value});
}

const testing = std.testing;

test "the discovery document is only read for the auth environment" {
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

var stub_fetch_calls: usize = 0;

fn stubFetcher(http: *wire.HttpClient, allocator: std.mem.Allocator, jwks_uri: []const u8) Error!jwks.KeySet {
    _ = http;
    _ = jwks_uri;
    stub_fetch_calls += 1;
    return jwks.KeySet.parse(allocator, "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"present\",\"n\":\"AQAB\",\"e\":\"AQAB\"}]}");
}

fn tokenWithKeyId(allocator: std.mem.Allocator, kid: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = try std.fmt.allocPrint(allocator, "{{\"alg\":\"RS256\",\"kid\":\"{s}\"}}", .{kid});
    defer allocator.free(header);

    const payload = "{}";
    const placeholder_signature = &[_]u8{0} ** 96;
    const token = try allocator.alloc(u8, base64Length(header.len) + 1 + base64Length(payload.len) + 1 + base64Length(placeholder_signature.len));

    var offset: usize = 0;
    offset += encoder.encode(token[offset..], header).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], payload).len;
    token[offset] = '.';
    offset += 1;
    offset += encoder.encode(token[offset..], placeholder_signature).len;
    return token[0..offset];
}

fn base64Length(source_len: usize) usize {
    return (4 * source_len + 2) / 3;
}

test "an unknown key id refetches the keys at most once per interval" {
    const allocator = testing.allocator;
    stub_fetch_calls = 0;

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
    try testing.expectEqual(@as(usize, 1), stub_fetch_calls);

    try testing.expectError(error.UnknownKeyId, service.verifyLogin(material, 1000));
    try testing.expectEqual(@as(usize, 1), stub_fetch_calls);

    try testing.expectError(error.UnknownKeyId, service.verifyLogin(material, 1000 + default_refresh_min_interval_seconds));
    try testing.expectEqual(@as(usize, 2), stub_fetch_calls);
}

test "a guest login is never verified and never talks to the network" {
    const allocator = testing.allocator;
    stub_fetch_calls = 0;

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
    try testing.expectEqual(@as(usize, 0), stub_fetch_calls);

    try testing.expectError(error.NothingToVerify, service.verifyLogin(.{
        .authentication_type = 0,
        .chain = &.{},
        .multiplayer_token = null,
        .client_data_token = "",
    }, 1000));
    try testing.expectEqual(@as(usize, 0), stub_fetch_calls);
}

test "an issuer without a trailing slash is normalised" {
    const allocator = testing.allocator;
    const normalised = try withTrailingSlash(allocator, "https://authorization.test");
    defer allocator.free(normalised);
    try testing.expectEqualStrings("https://authorization.test/", normalised);

    const kept = try withTrailingSlash(allocator, "https://authorization.test/");
    defer allocator.free(kept);
    try testing.expectEqualStrings("https://authorization.test/", kept);
}
