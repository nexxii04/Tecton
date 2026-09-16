const std = @import("std");
const Protocol = @import("protocol");
const api = @import("../plugins/api.zig");

pub const PluginStateChange = struct {
    instance: u32,
    position: Protocol.BlockPosition,
    identifier: []const u8,
};

pub const PluginState = struct {};

pub fn setActive(_: *PluginState) void {}

fn manifest() api.PluginManifest {
    return .{
        .name = "core-empty",
        .version = "1.0.0",
        .api = .{ .major = api.api_major, .minor = api.api_minor, .protocol = Protocol.PROTOCOL },
    };
}

fn initPlugin(_: *api.PluginContext) !void {}
fn startPlugin() !void {}
fn stopPlugin(_: api.StopReason) void {}

pub const descriptor = api.PluginDescriptor{
    .manifest = manifest,
    .init = initPlugin,
    .start = startPlugin,
    .stop = stopPlugin,
};
