const std = @import("std");
const tecton_mod = @import("../tecton.zig");
const bootstrap = @import("bootstrap.zig");
const dispatch = @import("../network/dispatch.zig");
const services = @import("services.zig");

pub const options = @import("options.zig");
pub const ServerOptions = tecton_mod.ServerOptions;
pub const ServerPaths = options.ServerPaths;
pub const CommandPermissionChecker = options.CommandPermissionChecker;

pub const Composition = tecton_mod.Composition;

pub const composition: Composition = .{
    .prepare = bootstrap.prepare,
    .dispatch = dispatch.dispatchFromHost,
    .command_views = services.commandViews,
};

pub fn defaultOptions(io: std.Io, allocator: std.mem.Allocator) ServerOptions {
    return .{
        .io = io,
        .allocator = allocator,
        .composition = composition,
    };
}
