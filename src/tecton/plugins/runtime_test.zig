pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const abi = scope.abi;
        const SendPriority = scope.SendPriority;
        const MAX_PLUGIN_PACKET_BYTES = scope.MAX_PLUGIN_PACKET_BYTES;
        const PluginRuntime = scope.PluginRuntime;
        const private_pluginruntime_getInterface = scope.private_pluginruntime_getInterface;
        const private_pluginruntime_networkBroadcast = scope.private_pluginruntime_networkBroadcast;
        const private_pluginruntime_networkSend = scope.private_pluginruntime_networkSend;
        const private_pluginruntime_sendPriority = scope.private_pluginruntime_sendPriority;
        pub fn case_000() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();

            var core: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_core, 1, 0, &core));
            try std.testing.expect(core != null);
            try std.testing.expectEqual(abi.interface_core, core.?.interface_id);
            try std.testing.expectEqual(@as(u32, @sizeOf(abi.CoreApi)), core.?.struct_size);

            var scheduler: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_scheduler, 1, 0, &scheduler));
            try std.testing.expect(scheduler != null);
            try std.testing.expectEqual(abi.interface_scheduler, scheduler.?.interface_id);

            var world: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_world, 1, 0, &world));
            try std.testing.expect(world != null);
            try std.testing.expectEqual(abi.interface_world, world.?.interface_id);

            var players: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_players, 1, 0, &players));
            try std.testing.expect(players != null);

            var entities: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_entities, 1, 0, &entities));
            try std.testing.expect(entities != null);

            var items: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_items, 1, 0, &items));
            try std.testing.expect(items != null);

            var blocks: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_blocks, 1, 0, &blocks));
            try std.testing.expect(blocks != null);

            var inventories: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_inventories, 1, 0, &inventories));
            try std.testing.expect(inventories != null);

            var network: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&runtime), abi.interface_network, 1, 0, &network));
            try std.testing.expect(network != null);
            try std.testing.expectEqual(abi.interface_network, network.?.interface_id);
            try std.testing.expectEqual(@as(u32, @sizeOf(abi.NetworkApi)), network.?.struct_size);
            try std.testing.expect(runtime.host.features & abi.feature_network != 0);
        }

        pub fn case_001() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();

            const payload = "packet";
            const view = abi.StringView{ .data = payload.ptr, .length = payload.len };

            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkSend(@ptrCast(&runtime), 1, view, 7));
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkSend(@ptrCast(&runtime), 1, .{}, abi.packet_priority_normal));
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkBroadcast(@ptrCast(&runtime), .{}, abi.packet_priority_immediate));

            const oversized = try std.testing.allocator.alloc(u8, MAX_PLUGIN_PACKET_BYTES + 1);
            defer std.testing.allocator.free(oversized);
            const big = abi.StringView{ .data = oversized.ptr, .length = oversized.len };
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkBroadcast(@ptrCast(&runtime), big, abi.packet_priority_normal));

            try std.testing.expectEqual(abi.result_not_found, private_pluginruntime_networkSend(@ptrCast(&runtime), 1, view, abi.packet_priority_immediate));
            try std.testing.expectEqual(abi.result_not_found, private_pluginruntime_networkBroadcast(@ptrCast(&runtime), view, abi.packet_priority_normal));

            try std.testing.expectEqual(SendPriority.normal, private_pluginruntime_sendPriority(abi.packet_priority_normal).?);
            try std.testing.expectEqual(SendPriority.immediate, private_pluginruntime_sendPriority(abi.packet_priority_immediate).?);
            try std.testing.expect(private_pluginruntime_sendPriority(7) == null);
        }
    };
}
