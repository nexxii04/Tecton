const tecton_mod = @import("../tecton.zig");
const bootstrap = @import("bootstrap.zig");
const dispatch = @import("../network/dispatch.zig");

pub const options = @import("options.zig");
pub const ServerOptions = options.ServerOptions;
pub const ServerPaths = options.ServerPaths;
pub const CommandPermissionChecker = options.CommandPermissionChecker;

pub const Composition = tecton_mod.Composition;

pub const composition: Composition = .{
    .prepare = bootstrap.prepare,
    .dispatch = dispatch.dispatchFromHost,
};
