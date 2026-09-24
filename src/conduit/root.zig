//! Conduit — public API
const std = @import("std");

pub const binary_stream = @import("BinaryStream");
pub const nbt = @import("nbt");
pub const protocol = @import("protocol");

pub const command = @import("./command/root.zig");
pub const Conduit = @import("./conduit.zig").Conduit;
pub const Server = Conduit;
pub const ServerOptions = @import("./conduit.zig").ServerOptions;
pub const ServerPaths = @import("./conduit.zig").ServerPaths;
pub const CommandPermissionChecker = @import("./conduit.zig").CommandPermissionChecker;
pub const ServerProperties = @import("./config.zig").ServerProperties;
pub const container = @import("./container/root.zig");
pub const entity = @import("./entity/root.zig");
pub const events = @import("./events/root.zig");
pub const items = @import("./items/root.zig");
pub const network = @import("./network/root.zig");
pub const SendPriority = network.SendPriority;
pub const player = @import("./player/root.zig");
pub const plugins = @import("./plugins/root.zig");
pub const tasks = @import("./tasks/root.zig");
pub const version = @import("./version.zig").version;
pub const block = @import("./world/block/root.zig");
pub const world = @import("./world/root.zig");

test {
    std.testing.refAllDecls(@This());
}
