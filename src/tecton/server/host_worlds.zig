const std = @import("std");

pub fn Suite(comptime Tecton: type, comptime World: type) type {
    return struct {
        fn cast(ctx: *anyopaque) *Tecton {
            return @ptrCast(@alignCast(ctx));
        }

        pub fn getWorld(ctx: *anyopaque, name: []const u8) ?*World {
            return cast(ctx).worlds.get(name);
        }

        pub fn hasWorld(ctx: *anyopaque, name: []const u8) bool {
            return cast(ctx).worlds.has(name);
        }

        pub fn countWorlds(ctx: *anyopaque) usize {
            return cast(ctx).worlds.count();
        }

        pub fn worldOpInFlight(ctx: *anyopaque, name: []const u8) bool {
            return cast(ctx).worlds.opInFlight(name);
        }

        pub fn beginWorldOp(ctx: *anyopaque, owned_name: []u8) bool {
            return cast(ctx).worlds.beginOp(owned_name);
        }

        pub fn detachWorld(ctx: *anyopaque, world: *World) void {
            cast(ctx).worlds.detach(world);
        }

        pub fn collectWorldNames(ctx: *anyopaque, names_allocator: std.mem.Allocator, names: *std.ArrayList([]const u8)) anyerror!void {
            var it = cast(ctx).worlds.keyIterator();
            while (it.next()) |key| {
                try names.append(names_allocator, key.*);
            }
        }

        pub fn worldDirExists(ctx: *anyopaque, name: []const u8) bool {
            const tecton = cast(ctx);
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ tecton.paths.worlds, name }) catch return false;
            if (std.Io.Dir.cwd().openDir(tecton.io, path, .{})) |dir_val| {
                var dir = dir_val;
                dir.close(tecton.io);
                return true;
            } else |_| {
                return false;
            }
        }

        pub fn adoptWorld(ctx: *anyopaque, world: *World) anyerror!void {
            return cast(ctx).worlds.adopt(world);
        }

        pub fn destroyWorld(ctx: *anyopaque, world: *World) void {
            cast(ctx).worlds.destroy(world);
        }

        pub fn endOp(ctx: *anyopaque, name: []const u8) void {
            cast(ctx).worlds.endOp(name);
        }
    };
}
