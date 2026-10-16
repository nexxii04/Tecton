const Helpers = @import("services_test_helpers.zig").Fixture;

pub fn Suite(comptime scope: type) type {
    return struct {
        const F = Helpers(scope);
        const std = F.std;
        const testing = F.testing;
        const allocator = F.allocator;

        const Tecton = F.Tecton;
        const host = F.host;
        const commandViews = F.commandViews;
        const CommandContext = F.CommandContext;
        const Command = F.Command;
        const Player = F.Player;

        const CommandRegistry = F.CommandRegistry;
        const PermissionManager = F.PermissionManager;

        const stubNetwork = F.stubNetwork;
        const baseTecton = F.baseTecton;

        const PermissionProbe = struct {
            allow: bool,
            calls: usize = 0,
            xuid: []const u8 = "",
            permission: []const u8 = "",

            fn check(raw: ?*anyopaque, xuid: []const u8, permission: []const u8) bool {
                const self: *@This() = @ptrCast(@alignCast(raw.?));
                self.calls += 1;
                self.xuid = xuid;
                self.permission = permission;
                return self.allow;
            }
        };

        pub fn case_023() !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});

            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.permission_manager = PermissionManager.init(testing.io, allocator, path, "member");
            defer tecton.permission_manager.deinit();

            const h = host(&tecton);
            try std.testing.expectEqualStrings("member", h.permission_manager.getPlayerGroup("Alice"));
            try tecton.permission_manager.setPlayerGroup("Alice", "operator");
            try std.testing.expectEqualStrings("operator", h.permission_manager.getPlayerGroup("Alice"));
        }

        pub fn case_031() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);
            tecton.command_permission_checker = null;
            tecton.command_permission_userdata = null;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});
            tecton.permission_manager = PermissionManager.init(testing.io, allocator, path, "member");
            defer tecton.permission_manager.deinit();
            const view = commandViews(&tecton).permissions;
            try testing.expect(view.hasPermission("Limited", "xuid-1", "tecton.command.about"));
            try testing.expect(!view.hasPermission("Limited", "xuid-1", "tecton.command.op"));
            try tecton.permission_manager.setPlayerGroup("Operator", "operator");
            try testing.expect(view.hasPermission("Operator", "xuid-2", "tecton.command.op"));
            var deny: PermissionProbe = .{ .allow = false };
            tecton.command_permission_checker = PermissionProbe.check;
            tecton.command_permission_userdata = &deny;
            try testing.expect(!view.hasPermission("Operator", "xuid-2", "tecton.command.op"));
            try testing.expectEqualStrings("xuid-2", deny.xuid);
            try testing.expectEqualStrings("tecton.command.op", deny.permission);
            try testing.expectEqual(@as(usize, 1), deny.calls);
            try testing.expect(view.hasPermission("Operator", "xuid-2", ""));
            try testing.expectEqual(@as(usize, 1), deny.calls);
            var allow: PermissionProbe = .{ .allow = true };
            tecton.command_permission_userdata = &allow;
            try testing.expect(view.hasPermission("Limited", "xuid-1", "tecton.command.op"));
            try testing.expectEqual(@as(usize, 1), allow.calls);
            tecton.command_permission_checker = null;
            try testing.expect(!view.hasPermission("Limited", "xuid-1", "tecton.command.op"));
            try tecton.permission_manager.setPlayerGroup("Limited", "operator");
            try testing.expect(view.hasPermission("Limited", "xuid-1", "tecton.command.op"));
        }

        fn dispatched(raw: *anyopaque) void {
            const ctx: *CommandContext = @ptrCast(@alignCast(raw));
            const calls: *usize = @ptrCast(@alignCast(ctx.command_userdata.?));
            calls.* += 1;
        }

        pub fn case_034() !void {
            var stub = stubNetwork();
            var tecton: Tecton = undefined;
            baseTecton(&tecton, &stub);

            tecton.command_permission_checker = null;
            tecton.command_permission_userdata = null;
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/permissions.json", .{&tmp.sub_path});
            tecton.permission_manager = PermissionManager.init(testing.io, allocator, path, "member");
            defer tecton.permission_manager.deinit();
            var registry = CommandRegistry.init(allocator);
            defer registry.deinit();
            var calls: usize = 0;
            const command = try Command.init(allocator, "restricted", "test", "tecton.command.op", &.{}, dispatched);
            command.setUserdata(&calls);
            try registry.registerCommand(command);
            var player: Player = undefined;
            player.username = "Limited";
            player.xuid = "xuid-limited";
            const views = commandViews(&tecton);
            const denied = registry.dispatch(&player, views, &stub, "restricted", "player", .{0} ** 16, "req");
            try testing.expect(!denied.success);
            try testing.expectEqualStrings("You do not have permission to run this command", denied.message);
            try testing.expectEqual(@as(usize, 0), calls);
            var probe: PermissionProbe = .{ .allow = true };
            tecton.command_permission_checker = PermissionProbe.check;
            tecton.command_permission_userdata = &probe;
            const allowed = registry.dispatch(&player, views, &stub, "restricted", "player", .{0} ** 16, "req");
            try testing.expect(allowed.success);
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqual(@as(usize, 1), probe.calls);
            probe.allow = false;
            registry.dispatchConsole(views, &stub, "restricted");
            try testing.expectEqual(@as(usize, 2), calls);
            try testing.expectEqual(@as(usize, 1), probe.calls);
        }
    };
}
