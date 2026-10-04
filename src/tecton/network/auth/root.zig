pub const service = @import("service.zig");
pub const AuthService = service.AuthService;
pub const Options = service.Options;
pub const LoginMaterial = service.LoginMaterial;
pub const Verified = service.Verified;

pub const identity = @import("identity.zig");
pub const legacy_chain = @import("legacy-chain.zig");
pub const jwt = @import("jwt.zig");
pub const jwks = @import("jwks.zig");
pub const signature = @import("signature.zig");
pub const wire = @import("wire.zig");
pub const mojang_root_key = @import("mojang-root-key.zig");

test {
    _ = jwks;
    _ = wire;
    _ = mojang_root_key;
}
