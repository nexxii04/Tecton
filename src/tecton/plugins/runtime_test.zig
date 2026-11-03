const std = @import("std");

const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,
    deny_allocations: bool = false,

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn deinit(_: *CountingAllocator) void {}

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        if (self.deny_allocations) return null;
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        return @ptrCast(memory);
    }

    fn resize(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return false;
    }

    fn remap(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return null;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

pub fn Suite(comptime scope: type) type {
    return struct {
        const abi = scope.abi;
        const Events = scope.Events;
        const SendPriority = scope.SendPriority;
        const MAX_PLUGIN_PACKET_BYTES = scope.MAX_PLUGIN_PACKET_BYTES;
        const PluginRuntime = scope.PluginRuntime;
        const HostSlot = scope.HostSlot;
        const private_pluginruntime_getInterface = scope.private_pluginruntime_getInterface;
        const private_pluginruntime_networkBroadcast = scope.private_pluginruntime_networkBroadcast;
        const private_pluginruntime_networkSend = scope.private_pluginruntime_networkSend;
        const private_pluginruntime_sendPriority = scope.private_pluginruntime_sendPriority;
        const private_pluginruntime_dispatch = scope.private_pluginruntime_dispatch;
        const private_pluginruntime_itemHandle = scope.private_pluginruntime_itemHandle;
        pub fn case_000() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 0, .name = "test", .host = undefined };

            var core: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_core, 1, 0, &core));
            try std.testing.expect(core != null);
            try std.testing.expectEqual(abi.interface_core, core.?.interface_id);
            try std.testing.expectEqual(@as(u32, @sizeOf(abi.CoreApi)), core.?.struct_size);

            var scheduler: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_scheduler, 1, 0, &scheduler));
            try std.testing.expect(scheduler != null);
            try std.testing.expectEqual(abi.interface_scheduler, scheduler.?.interface_id);

            var world: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_world, 1, 0, &world));
            try std.testing.expect(world != null);
            try std.testing.expectEqual(abi.interface_world, world.?.interface_id);

            var players: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_players, 1, 0, &players));
            try std.testing.expect(players != null);

            var entities: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_entities, 1, 0, &entities));
            try std.testing.expect(entities != null);

            var items: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_items, 1, 0, &items));
            try std.testing.expect(items != null);

            var blocks: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_blocks, 1, 0, &blocks));
            try std.testing.expect(blocks != null);

            var inventories: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_inventories, 1, 0, &inventories));
            try std.testing.expect(inventories != null);

            var network: ?abi.InterfacePtr = null;
            try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), abi.interface_network, 1, 0, &network));
            try std.testing.expect(network != null);
            try std.testing.expectEqual(abi.interface_network, network.?.interface_id);
            try std.testing.expectEqual(@as(u32, @sizeOf(abi.NetworkApi)), network.?.struct_size);
            try std.testing.expect(runtime.host.features & abi.feature_network != 0);
        }

        pub fn case_002() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 0, .name = "test", .host = undefined };

            const ids = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
            for (ids) |id| {
                var interface: ?abi.InterfacePtr = null;
                try std.testing.expectEqual(abi.result_ok, private_pluginruntime_getInterface(@ptrCast(&slot), id, 1, 0, &interface));
                try std.testing.expect(interface != null);
                try std.testing.expectEqual(id, interface.?.interface_id);
                try std.testing.expectEqual(@as(u16, 1), interface.?.major);
                try std.testing.expectEqual(@as(u16, 0), interface.?.minor);
                try std.testing.expect(interface.?.struct_size >= @sizeOf(abi.InterfaceHeader));

                try std.testing.expectEqual(abi.result_version, private_pluginruntime_getInterface(@ptrCast(&slot), id, 2, 0, &interface));
                try std.testing.expect(interface == null);
                try std.testing.expectEqual(abi.result_version, private_pluginruntime_getInterface(@ptrCast(&slot), id, 1, 1, &interface));
                try std.testing.expect(interface == null);
            }

            var missing: ?abi.InterfacePtr = undefined;
            try std.testing.expectEqual(abi.result_unsupported, private_pluginruntime_getInterface(@ptrCast(&slot), 99, 1, 0, &missing));
            try std.testing.expect(missing == null);
            try std.testing.expect(runtime.host.features & abi.feature_registries != 0);
            try std.testing.expect(runtime.host.features & abi.feature_commands != 0);
            try std.testing.expectEqual(abi.interface_commands, runtime.commands_api.header.interface_id);
        }

        pub fn case_003() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 4, .name = "logging", .host = undefined };

            runtime.logging_api.set_level(@ptrCast(&slot), abi.log_warn);
            try std.testing.expectEqual(@as(i32, 0), runtime.logging_api.is_enabled(@ptrCast(&slot), abi.log_info));
            try std.testing.expectEqual(@as(i32, 1), runtime.logging_api.is_enabled(@ptrCast(&slot), abi.log_error));
            runtime.logging_api.set_level(@ptrCast(&slot), abi.log_error);
            try std.testing.expectEqual(@as(i32, 0), runtime.logging_api.is_enabled(@ptrCast(&slot), abi.log_info));
            try std.testing.expectEqual(@as(i32, 1), runtime.logging_api.is_enabled(@ptrCast(&slot), abi.log_error));

            const scope_name = "net/inbound";
            runtime.logging_api.set_scope(@ptrCast(&slot), .{ .data = scope_name.ptr, .length = scope_name.len });
            try std.testing.expectEqual(@as(u8, scope_name.len), slot.scope_len);
            try std.testing.expectEqualStrings(scope_name, slot.scope[0..@as(usize, slot.scope_len)]);

            const long = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
            runtime.logging_api.set_scope(@ptrCast(&slot), .{ .data = long.ptr, .length = long.len });
            try std.testing.expectEqual(@as(u8, 64), slot.scope_len);
            try std.testing.expectEqualStrings(long[0..64], slot.scope[0..64]);

            runtime.logging_api.set_level(@ptrCast(&slot), abi.log_error);
            const message = "filtered";
            runtime.logging_api.log(@ptrCast(&slot), abi.log_info, .{ .data = message.ptr, .length = message.len });
            runtime.logging_api.set_level(@ptrCast(&slot), abi.log_info);
            runtime.logging_api.log(@ptrCast(&slot), abi.log_info, .{ .data = message.ptr, .length = message.len });
        }

        pub fn case_004() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 5, .name = "events", .host = undefined, .state = .running };

            try std.testing.expectEqual(@intFromPtr(runtime.host.event_subscribe), @intFromPtr(runtime.events_api.subscribe));
            try std.testing.expectEqual(@intFromPtr(runtime.host.event_unsubscribe), @intFromPtr(runtime.events_api.unsubscribe));
            try std.testing.expectEqual(@intFromPtr(runtime.host.emit_custom), @intFromPtr(runtime.events_api.emit));

            const name = "phase03.probe";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));
            try std.testing.expectEqual(@as(u32, (abi.event_custom_base << 8) | 1), schema);

            const Probe = struct {
                runtime: *PluginRuntime,
                slot: *PluginRuntime.HostSlot,
                schema: u32 = 0,
                calls: u32 = 0,
                chained: bool = false,
                last: u16 = 0,

                fn callback(userdata: ?*anyopaque, event: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    const value: *const u16 = @ptrCast(@alignCast(event.data.?));
                    probe.last = value.*;
                    probe.calls += 1;
                    if (probe.chained and probe.calls == 1) {
                        var next: u16 = 3;
                        _ = probe.runtime.events_api.emit(@ptrCast(probe.slot), probe.schema, &next, @sizeOf(u16), 0);
                    }
                }
            };
            var probe = Probe{ .runtime = &runtime, .slot = &slot, .schema = schema };
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.callback, &probe, &subscription));

            var first: u16 = 1;
            var second: u16 = 2;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &first, @sizeOf(u16), 0));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &second, @sizeOf(u16), 0));
            try std.testing.expectEqual(@as(u32, 0), probe.calls);
            try std.testing.expectEqual(@as(usize, 2), runtime.deferredLen());

            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 2), probe.calls);
            try std.testing.expectEqual(@as(u16, 2), probe.last);
            try std.testing.expectEqual(@as(usize, 0), runtime.deferredLen());

            probe.calls = 0;
            probe.chained = true;
            probe.last = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &first, @sizeOf(u16), 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1), probe.calls);
            try std.testing.expectEqual(@as(u16, 1), probe.last);
            try std.testing.expectEqual(@as(usize, 1), runtime.deferredLen());
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 2), probe.calls);
            try std.testing.expectEqual(@as(u16, 3), probe.last);
        }

        pub fn case_005() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 6, .name = "depth", .host = undefined, .state = .running };

            const name = "phase03.depth";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Probe = struct {
                runtime: *PluginRuntime,
                slot: *PluginRuntime.HostSlot,
                schema: u32,
                depth: u32 = 0,
                limit: i32 = abi.result_ok,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.depth += 1;
                    var payload: u8 = 1;
                    const result = probe.runtime.events_api.emit_immediate(@ptrCast(probe.slot), probe.schema, &payload, 1, 0);
                    if (result != abi.result_ok) probe.limit = result;
                }
            };
            var probe = Probe{ .runtime = &runtime, .slot = &slot, .schema = schema };
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.callback, &probe, &subscription));

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit_immediate(@ptrCast(&slot), schema, null, 0, 0));
            try std.testing.expectEqual(@as(u32, 16), probe.depth);
            try std.testing.expectEqual(abi.result_busy, probe.limit);
            try std.testing.expectEqual(@as(u32, 0), runtime.depth);
        }

        pub fn case_006() !void {
            const NBT = @import("nbt");
            const ItemType = @import("../items/item_type.zig").ItemType;
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const first_name = try allocator.dupe(u8, "minecraft:phase03_a");
            const second_name = try allocator.dupe(u8, "minecraft:phase03_b");
            const first = try ItemType.init(allocator, first_name, 9001, 64, true, &.{}, false, 0, .{ .Compound = NBT.CompoundTag.init(allocator, null) });
            try first.register();
            const second = try ItemType.init(allocator, second_name, 9002, 16, false, &.{}, false, 0, .{ .Compound = NBT.CompoundTag.init(allocator, null) });
            try second.register();

            var runtime = PluginRuntime.init(allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 7, .name = "registries", .host = undefined };

            var view: abi.RegistryView = undefined;
            try std.testing.expectEqual(abi.result_ok, runtime.registries_api.items(@ptrCast(&slot), &view));
            try std.testing.expectEqual(@as(usize, 2), view.count);
            try std.testing.expectEqual(@sizeOf(abi.ItemEntry), view.stride);
            try std.testing.expect(view.data != null);

            const entries: [*]const abi.ItemEntry = @ptrCast(@alignCast(view.data.?));
            var total: usize = 0;
            var iteration: usize = 0;
            while (iteration < 2000) : (iteration += 1) {
                for (0..view.count) |index| total += @intCast(entries[index].network_id);
            }
            try std.testing.expectEqual(@as(usize, (9001 + 9002) * 2000), total);

            var again: abi.RegistryView = undefined;
            try std.testing.expectEqual(abi.result_ok, runtime.registries_api.items(@ptrCast(&slot), &again));
            try std.testing.expectEqual(view.data, again.data);
            try std.testing.expectEqual(view.count, again.count);

            var blocks: abi.RegistryView = undefined;
            try std.testing.expectEqual(abi.result_ok, runtime.registries_api.block_states(@ptrCast(&slot), &blocks));
            var entity_types: abi.RegistryView = undefined;
            try std.testing.expectEqual(abi.result_ok, runtime.registries_api.entity_types(@ptrCast(&slot), &entity_types));
        }

        pub fn case_007() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 1, .name = "timers", .host = undefined, .state = .running };

            const Probe = struct {
                calls: u64 = 0,

                fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var probe = Probe{};
            var handles: [64]u64 = undefined;
            for (&handles) |*handle| {
                handle.* = 0;
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 1, Probe.callback, &probe, handle));
            }
            try std.testing.expectEqual(@as(u32, 64), runtime.timerLiveCount());

            var tick: u64 = 1;
            while (tick <= 1000) : (tick += 1) runtime.runTimers(tick);
            try std.testing.expectEqual(@as(u64, 64 * 1000), probe.calls);

            for (handles) |handle| {
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.cancel(@ptrCast(&slot), handle));
                try std.testing.expectEqual(abi.result_not_found, runtime.scheduler_api.cancel(@ptrCast(&slot), handle));
            }
            try std.testing.expectEqual(@as(u32, 0), runtime.timerLiveCount());

            probe.calls = 0;
            var after_handle: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.after(@ptrCast(&slot), 0, Probe.callback, &probe, &after_handle));
            runtime.runTimers(1000);
            try std.testing.expectEqual(@as(u64, 0), probe.calls);
            runtime.runTimers(1001);
            try std.testing.expectEqual(@as(u64, 1), probe.calls);

            var one: u64 = 0;
            var two: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 5, Probe.callback, &probe, &one));
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 5, Probe.callback, &probe, &two));
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.cancel_owner(@ptrCast(&slot)));
            try std.testing.expectEqual(@as(u32, 0), runtime.timerLiveCount());
            try std.testing.expectEqual(abi.result_not_found, runtime.scheduler_api.cancel_owner(@ptrCast(&slot)));
        }

        pub fn case_008() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 8, .name = "custom-sub", .host = undefined, .state = .running };

            const name = "phase03.custom.sub";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Probe = struct {
                runtime: *PluginRuntime,
                slot: *PluginRuntime.HostSlot,
                schema: u32,
                first_calls: u32 = 0,
                late_calls: u32 = 0,
                subscribed: bool = false,
                late_sub: u64 = 0,

                fn first(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.first_calls += 1;
                    if (probe.subscribed) return;
                    probe.subscribed = true;
                    _ = probe.runtime.events_api.subscribe(@ptrCast(probe.slot), probe.schema >> 8, abi.event_phase_pre, 0, late, probe, &probe.late_sub);
                }

                fn late(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.late_calls += 1;
                }
            };
            var probe = Probe{ .runtime = &runtime, .slot = &slot, .schema = schema };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.first, &probe, &sub));

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1), probe.first_calls);
            try std.testing.expectEqual(@as(u32, 0), probe.late_calls);
            try std.testing.expect(probe.late_sub != 0);

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 2), probe.first_calls);
            try std.testing.expectEqual(@as(u32, 1), probe.late_calls);
        }

        pub fn case_009() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 9, .name = "custom-unsub", .host = undefined, .state = .running };

            const name = "phase03.custom.unsub";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Probe = struct {
                slot: *PluginRuntime.HostSlot,
                sub: u64 = 0,
                first_calls: u32 = 0,
                second_calls: u32 = 0,

                fn first(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.first_calls += 1;
                    _ = probe.slot.runtime.events_api.unsubscribe(@ptrCast(probe.slot), probe.sub);
                }

                fn second(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.second_calls += 1;
                }
            };
            var probe = Probe{ .slot = &slot };
            var first_sub: u64 = 0;
            var second_sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.first, &probe, &first_sub));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.second, &probe, &second_sub));
            probe.sub = first_sub;

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1), probe.first_calls);
            try std.testing.expectEqual(@as(u32, 1), probe.second_calls);
            const custom_index: usize = @typeInfo(Events.Event).@"enum".fields.len + @as(usize, schema >> 8) - @as(usize, abi.event_custom_base);
            try std.testing.expectEqual(@as(usize, 1), runtime.buckets[custom_index][abi.event_phase_pre].items.len);
            try std.testing.expectEqual(@as(u32, 0), runtime.dead_total);

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1), probe.first_calls);
            try std.testing.expectEqual(@as(u32, 2), probe.second_calls);
        }

        pub fn case_010() !void {
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 10, .name = "cancel", .host = undefined, .state = .running };

            const Probe = struct {
                calls: [4]u8 = undefined,
                len: usize = 0,

                fn push(self: *@This(), value: u8) void {
                    self.calls[self.len] = value;
                    self.len += 1;
                }

                fn cancel(userdata: ?*anyopaque, event: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.push(1);
                    event.result.* = @intFromEnum(abi.EventResult.cancel);
                }

                fn observe(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.push(2);
                }
            };
            var probe = Probe{};
            var first: u64 = 0;
            var second: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_chat), abi.event_phase_pre, 0, Probe.cancel, &probe, &first));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_chat), abi.event_phase_pre, 0, Probe.observe, &probe, &second));

            var player: @import("../player/player.zig").Player = undefined;
            player.entity.runtime_id = 7;
            var chat = Events.types.PlayerChatEvent{ .player = &player, .message = "hello" };
            try std.testing.expect(!events.emit(.PlayerChat, &chat));
            try std.testing.expectEqual(@as(usize, 1), probe.len);
            try std.testing.expectEqual(@as(u8, 1), probe.calls[0]);

            probe.len = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.cancel, &probe, &first));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.observe, &probe, &second));

            var tick = Events.types.ServerTickEvent{ .tick = 1 };
            try std.testing.expect(events.emit(.ServerTick, &tick));
            try std.testing.expectEqual(@as(usize, 2), probe.len);
            try std.testing.expectEqual(@as(u8, 1), probe.calls[0]);
            try std.testing.expectEqual(@as(u8, 2), probe.calls[1]);
        }

        pub fn case_011() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 11, .name = "timers-full", .host = undefined, .state = .running };

            const callback = struct {
                fn call(_: ?*anyopaque, _: u64) callconv(.c) void {}
            }.call;
            var handles: [4096]u64 = undefined;
            for (&handles) |*handle| {
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 1, callback, null, handle));
            }
            try std.testing.expectEqual(@as(u32, 4096), runtime.timerLiveCount());
            var overflow: u64 = 0;
            try std.testing.expectEqual(abi.result_busy, runtime.scheduler_api.every(@ptrCast(&slot), 1, callback, null, &overflow));
            for (handles) |handle| {
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.cancel(@ptrCast(&slot), handle));
            }
            try std.testing.expectEqual(@as(u32, 0), runtime.timerLiveCount());
            var reused: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 1, callback, null, &reused));
        }

        pub fn case_012() !void {
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 12, .name = "idle", .host = undefined, .state = .running };

            try std.testing.expect(events.idle_hook == null);
            var tick = Events.types.ServerTickEvent{ .tick = 1 };
            _ = events.emit(.ServerTick, &tick);
            try std.testing.expectEqual(@as(u32, 0), runtime.bridge_total);
            try std.testing.expect(events.idle_hook == null);

            const Probe = struct {
                calls: u32 = 0,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var probe = Probe{};
            var subscriptions: [32]u64 = undefined;
            for (&subscriptions) |*subscription| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_start), abi.event_phase_pre, 0, Probe.callback, &probe, subscription));
            }
            try std.testing.expectEqual(@as(u32, 1), runtime.bridge_total);
            try std.testing.expect(runtime.bridges[@intFromEnum(abi.EventId.server_start)][abi.event_phase_pre]);
            try std.testing.expect(!runtime.bridges[@intFromEnum(abi.EventId.server_tick)][abi.event_phase_pre]);
            try std.testing.expectEqual(@as(u32, 0), runtime.bridge_refresh_total);
            try std.testing.expect(events.idle_hook == null);

            _ = events.emit(.ServerTick, &tick);
            try std.testing.expectEqual(@as(u32, 0), probe.calls);
            try std.testing.expectEqual(@as(u32, 0), runtime.depth);

            var start = Events.types.ServerStartEvent{};
            _ = events.emit(.ServerStart, &start);
            try std.testing.expectEqual(@as(u32, 32), probe.calls);
        }

        pub fn case_013() !void {
            const ItemType = @import("../items/item_type.zig").ItemType;
            const NBT = @import("nbt");
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            const name = try allocator.dupe(u8, "minecraft:phase03_hot");
            const item = try ItemType.init(allocator, name, 9100, 64, true, &.{}, false, 0, .{ .Compound = NBT.CompoundTag.init(allocator, null) });
            try item.register();

            var counted = CountingAllocator.init(allocator);
            defer counted.deinit();
            const counted_allocator = counted.allocator();

            var events = Events.Events.init(counted_allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(counted_allocator);
            defer {
                counted.deny_allocations = false;
                runtime.deinit();
            }
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 13, .name = "hot", .host = undefined, .state = .running };

            const Probe = struct {
                calls: u32 = 0,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var probe = Probe{};
            var subscriptions: [32]u64 = undefined;
            for (&subscriptions) |*subscription| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_start), abi.event_phase_pre, 0, Probe.callback, &probe, subscription));
            }

            var start = Events.types.ServerStartEvent{};
            var tick = Events.types.ServerTickEvent{ .tick = 1 };
            _ = events.emit(.ServerStart, &start);
            _ = events.emit(.ServerTick, &tick);

            const timer_callback = struct {
                fn call(_: ?*anyopaque, _: u64) callconv(.c) void {}
            }.call;
            var timer: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.after(@ptrCast(&slot), 1, timer_callback, null, &timer));
            try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.cancel(@ptrCast(&slot), timer));

            const schema_name = "phase03.hot";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = schema_name.ptr, .length = schema_name.len }, 0, &schema));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();

            var view: abi.RegistryView = undefined;
            try std.testing.expectEqual(abi.result_ok, runtime.registries_api.items(@ptrCast(&slot), &view));
            try std.testing.expectEqual(@as(usize, 1), view.count);

            runtime.logging_api.set_level(@ptrCast(&slot), abi.log_error);
            const message = "filtered";
            probe.calls = 0;
            counted.allocations = 0;
            counted.deny_allocations = true;

            for (subscriptions[1..]) |subscription| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.unsubscribe(@ptrCast(&slot), subscription));
            }
            try std.testing.expectEqual(@as(u32, 1), runtime.active[@intFromEnum(abi.EventId.server_start)][abi.event_phase_pre]);

            var iteration: usize = 0;
            while (iteration < 1000) : (iteration += 1) {
                _ = events.emit(.ServerStart, &start);
                _ = events.emit(.ServerTick, &tick);
            }
            try std.testing.expectEqual(@as(u32, 1000), probe.calls);

            var handles: [64]u64 = undefined;
            for (&handles) |*handle| {
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.every(@ptrCast(&slot), 1, timer_callback, null, handle));
            }
            var timer_tick: u64 = 1;
            while (timer_tick <= 1000) : (timer_tick += 1) runtime.runTimers(timer_tick);
            for (handles) |handle| {
                try std.testing.expectEqual(abi.result_ok, runtime.scheduler_api.cancel(@ptrCast(&slot), handle));
            }

            iteration = 0;
            while (iteration < 1000) : (iteration += 1) {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
                runtime.endTick();
            }

            const entries: [*]const abi.ItemEntry = @ptrCast(@alignCast(view.data.?));
            var total: usize = 0;
            iteration = 0;
            while (iteration < 2000) : (iteration += 1) {
                for (0..view.count) |index| total += @intCast(entries[index].network_id);
            }
            try std.testing.expectEqual(@as(usize, 9100 * 2000), total);

            iteration = 0;
            while (iteration < 1000) : (iteration += 1) {
                runtime.logging_api.log(@ptrCast(&slot), abi.log_info, .{ .data = message.ptr, .length = message.len });
            }

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.unsubscribe(@ptrCast(&slot), subscriptions[0]));
            const calls_after_last = probe.calls;
            _ = events.emit(.ServerStart, &start);
            try std.testing.expectEqual(calls_after_last, probe.calls);
            try std.testing.expect(!events.hasListeners(.ServerStart));
            counted.deny_allocations = false;
            try std.testing.expectEqual(@as(usize, 0), counted.allocations);
        }

        pub fn case_014() !void {
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 14, .name = "custom-bridge-install", .host = undefined, .state = .running };

            const name = "phase03.custom.bridge.install";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Probe = struct {
                slot: *PluginRuntime.HostSlot,
                core_calls: u32 = 0,
                subscribed: bool = false,

                fn custom(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    if (probe.subscribed) return;
                    probe.subscribed = true;
                    var subscription: u64 = 0;
                    _ = probe.slot.runtime.events_api.subscribe(@ptrCast(probe.slot), @intFromEnum(abi.EventId.server_start), abi.event_phase_pre, 0, core, probe, &subscription);
                }

                fn core(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.core_calls += 1;
                }
            };
            var probe = Probe{ .slot = &slot };
            var custom_sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.custom, &probe, &custom_sub));

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();

            const start_index = @intFromEnum(abi.EventId.server_start);
            try std.testing.expectEqual(@as(u32, 1), runtime.active[start_index][abi.event_phase_pre]);
            try std.testing.expectEqual(@as(u32, 1), runtime.bridge_total);
            try std.testing.expect(events.hasListeners(.ServerStart));

            var start = Events.types.ServerStartEvent{};
            _ = events.emit(.ServerStart, &start);
            try std.testing.expectEqual(@as(u32, 1), probe.core_calls);
        }

        pub fn case_015() !void {
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 15, .name = "custom-bridge-retire", .host = undefined, .state = .running };

            const Probe = struct {
                slot: *PluginRuntime.HostSlot,
                core_sub: u64 = 0,
                core_calls: u32 = 0,

                fn core(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.core_calls += 1;
                }

                fn custom(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    _ = probe.slot.runtime.events_api.unsubscribe(@ptrCast(probe.slot), probe.core_sub);
                }
            };
            var probe = Probe{ .slot = &slot };
            var core_sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_start), abi.event_phase_pre, 0, Probe.core, &probe, &core_sub));
            probe.core_sub = core_sub;

            const name = "phase03.custom.bridge.retire";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            var custom_sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.custom, &probe, &custom_sub));

            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();

            const start_index = @intFromEnum(abi.EventId.server_start);
            try std.testing.expectEqual(@as(u32, 0), runtime.active[start_index][abi.event_phase_pre]);
            try std.testing.expectEqual(@as(u32, 0), runtime.bridge_total);
            try std.testing.expectEqual(@as(usize, 0), runtime.retire_count);
            try std.testing.expect(!events.hasListeners(.ServerStart));

            var start = Events.types.ServerStartEvent{};
            _ = events.emit(.ServerStart, &start);
            try std.testing.expectEqual(@as(u32, 0), probe.core_calls);
        }

        pub fn case_016() !void {
            const sizes = [_]usize{ 0, 0, 8, 16, 16, 32, 32, 40, 32, 32, 32, 16, 16, 16, 32, 32, 32, 24, 24, 24, 16, 16, 32, 32, 24 };
            const cancelable = [_]bool{ false, false, false, true, false, true, true, true, true, true, true, false, false, false, false, false, false, true, true, true, false, false, true, false, false };
            const mutable = [_]bool{ false, false, false, false, false, true, false, true, true, false, false, false, false, false, false, false, false, true, true, false, false, false, true, false, false };
            try std.testing.expectEqual(@as(usize, 25), std.meta.fields(abi.EventId).len);
            for (0..25) |id| {
                const event: abi.EventId = @enumFromInt(id);
                const meta = abi.eventMeta(event);
                try std.testing.expectEqual(@as(u32, @intCast(id)), meta.external_id);
                try std.testing.expectEqual((@as(u32, @intCast(id)) << 8) | @as(u32, if (id < 2) 0 else 1), meta.schema);
                try std.testing.expectEqual(sizes[id], meta.payload_size);
                const expected_flags = abi.event_flag_callback_only | abi.event_flag_borrowed | (if (cancelable[id]) abi.event_flag_cancelable else 0) | (if (mutable[id]) abi.event_flag_mutable else 0);
                try std.testing.expectEqual(expected_flags, meta.flags);
                try std.testing.expectEqual(id < 2, meta.payload == .none);
            }
            try std.testing.expect(@sizeOf(abi.EventPayload) <= 64);
            try std.testing.expect(@sizeOf(abi.EventView) == 40);
        }

        pub fn case_017() !void {
            const Player = @import("../player/player.zig").Player;
            const Entity = @import("../entity/entity.zig").Entity;
            const EntityId = @import("../ecs/entity_id.zig").EntityId;
            const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
            const ItemStack = @import("../items/item_stack.zig").ItemStack;
            const Enchantment = @import("../items/enchantments/enchantment.zig").Enchantment;

            const Capture = struct {
                seen: [25]bool = std.mem.zeroes([25]bool),
                sizes: [25]usize = std.mem.zeroes([25]usize),
                schemas: [25]u32 = std.mem.zeroes([25]u32),
                payload: [25][64]u8 align(8) = undefined,

                fn callback(userdata: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const self: *@This() = @ptrCast(@alignCast(userdata.?));
                    const id = view.event_id;
                    if (id >= 25) return;
                    self.seen[id] = true;
                    self.sizes[id] = view.data_size;
                    self.schemas[id] = view.schema;
                    if (view.data_size > 0) @memcpy(self.payload[id][0..view.data_size], @as([*]const u8, @ptrCast(view.data.?))[0..view.data_size]);
                }
            };

            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 16, .name = "payloads", .host = undefined, .state = .running };
            var capture = Capture{};
            var subscriptions: [25]u64 = undefined;
            for (0..25) |id| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intCast(id), abi.event_phase_pre, 0, Capture.callback, &capture, &subscriptions[id]));
            }

            var player: Player = undefined;
            player.entity.runtime_id = 7;
            player.on_ground = true;
            var entity: Entity = undefined;
            entity.runtime_id = 9;
            entity.position = .{ .x = 1, .y = 2, .z = 3 };
            var instigator: Entity = undefined;
            instigator.runtime_id = 10;
            var permutation: BlockPermutation = undefined;
            permutation.network_id = 42;
            var stack: ItemStack = undefined;
            var enchantment: Enchantment = undefined;
            enchantment.id = 77;
            const entity_id: EntityId = undefined;

            var start = Events.types.ServerStartEvent{};
            var shutdown = Events.types.ServerShutdownEvent{};
            var tick = Events.types.ServerTickEvent{ .tick = 11 };
            var join = Events.types.PlayerJoinEvent{ .player = &player };
            var disconnect = Events.types.PlayerDisconnectEvent{ .player = &player };
            var chat = Events.types.PlayerChatEvent{ .player = &player, .message = "hi" };
            var item_use = Events.types.ItemUseEvent{ .player = &player, .identifier = "minecraft:stone" };
            var move = Events.types.PlayerMoveEvent{ .player = &player, .from = .{ .x = 1, .y = 2, .z = 3 }, .to = .{ .x = 4, .y = 5, .z = 6 } };
            var damage = Events.types.DamageEvent{ .attacker = null, .victim = &entity, .amount = 3.5, .cause = .fire };
            var place = Events.types.BlockPlaceEvent{ .player = &player, .position = .{ .x = 1, .y = 2, .z = 3 }, .permutation = &permutation };
            var block_break = Events.types.BlockBreakEvent{ .player = &player, .position = .{ .x = 4, .y = 5, .z = 6 }, .permutation = &permutation };
            var open = Events.types.InventoryOpenEvent{ .player = &player, .container_id = 4 };
            var click = Events.types.InventoryClickEvent{ .player = &player, .slot = 5, .button = 2 };
            var close = Events.types.InventoryCloseEvent{ .player = &player, .container_id = 4 };
            var transaction = Events.types.TransactionEvent{ .transaction_id = [_]u8{1} ** 16, .player = &player, .committed = true };
            var combust = Events.types.EntityCombustEvent{ .entity = &entity, .duration = 100, .instigator = &instigator, .source = .lava };
            var apply = Events.types.EnchantmentApplyEvent{ .stack = &stack, .definition = &enchantment, .previous_level = 1, .level = 2, .source = .plugin, .actor = &player };
            var remove = Events.types.EnchantmentRemoveEvent{ .stack = &stack, .definition = null, .definition_id = 88, .previous_level = 2, .source = .plugin, .actor = &player };
            var spawn = Events.types.EntitySpawnEvent{ .id = entity_id, .runtime_id = 12 };
            var despawn = Events.types.EntityDespawnEvent{ .id = entity_id, .runtime_id = 12, .cause = .expired };
            var entity_damage = Events.types.EntityDamageEvent{ .target = entity_id, .target_runtime = 9, .amount = 4.5, .source = null, .source_runtime = null, .cause = .magic };
            var death = Events.types.EntityDeathEvent{ .id = entity_id, .runtime_id = 9, .killer_runtime = 10, .position = .{ .x = 1, .y = 2, .z = 3 } };
            var interact = Events.types.EntityInteractEvent{ .target = entity_id, .target_runtime = 9, .player = &player, .action = @enumFromInt(0) };

            var context = Events.EventContext{ .event = .ServerStart, .phase = .pre };
            _ = private_pluginruntime_dispatch(&runtime, .ServerStart, &context, &start);
            _ = private_pluginruntime_dispatch(&runtime, .ServerShutdown, &context, &shutdown);
            _ = private_pluginruntime_dispatch(&runtime, .ServerTick, &context, &tick);
            _ = private_pluginruntime_dispatch(&runtime, .PlayerJoin, &context, &join);
            _ = private_pluginruntime_dispatch(&runtime, .PlayerDisconnect, &context, &disconnect);
            _ = private_pluginruntime_dispatch(&runtime, .PlayerChat, &context, &chat);
            _ = private_pluginruntime_dispatch(&runtime, .ItemUse, &context, &item_use);
            _ = private_pluginruntime_dispatch(&runtime, .PlayerMove, &context, &move);
            _ = private_pluginruntime_dispatch(&runtime, .Damage, &context, &damage);
            _ = private_pluginruntime_dispatch(&runtime, .BlockPlace, &context, &place);
            _ = private_pluginruntime_dispatch(&runtime, .BlockBreak, &context, &block_break);
            _ = private_pluginruntime_dispatch(&runtime, .InventoryOpen, &context, &open);
            _ = private_pluginruntime_dispatch(&runtime, .InventoryClick, &context, &click);
            _ = private_pluginruntime_dispatch(&runtime, .InventoryClose, &context, &close);
            _ = private_pluginruntime_dispatch(&runtime, .TransactionPrepare, &context, &transaction);
            _ = private_pluginruntime_dispatch(&runtime, .TransactionCommit, &context, &transaction);
            _ = private_pluginruntime_dispatch(&runtime, .TransactionAbort, &context, &transaction);
            _ = private_pluginruntime_dispatch(&runtime, .EntityCombust, &context, &combust);
            _ = private_pluginruntime_dispatch(&runtime, .EnchantmentApply, &context, &apply);
            _ = private_pluginruntime_dispatch(&runtime, .EnchantmentRemove, &context, &remove);
            _ = private_pluginruntime_dispatch(&runtime, .EntitySpawn, &context, &spawn);
            _ = private_pluginruntime_dispatch(&runtime, .EntityDespawn, &context, &despawn);
            _ = private_pluginruntime_dispatch(&runtime, .EntityDamage, &context, &entity_damage);
            _ = private_pluginruntime_dispatch(&runtime, .EntityDeath, &context, &death);
            _ = private_pluginruntime_dispatch(&runtime, .EntityInteract, &context, &interact);

            for (0..25) |id| {
                try std.testing.expect(capture.seen[id]);
                try std.testing.expectEqual((@as(u32, @intCast(id)) << 8) | @as(u32, if (id < 2) 0 else 1), capture.schemas[id]);
            }
            try std.testing.expectEqual(@as(usize, 8), capture.sizes[2]);
            try std.testing.expectEqual(@as(usize, 40), capture.sizes[7]);
            try std.testing.expectEqual(@as(usize, 16), capture.sizes[20]);
            try std.testing.expectEqual(@as(usize, 24), capture.sizes[24]);
            try std.testing.expectEqual(@as(u64, 11), @as(*const abi.ServerTickEvent, @ptrCast(&capture.payload[2])).tick);
            const join_payload: *const abi.PlayerJoinEvent = @ptrCast(&capture.payload[3]);
            try std.testing.expect(join_payload.handle != 0);
            try std.testing.expectEqual(@as(i64, 7), join_payload.runtime_id);
            const disconnect_payload: *const abi.PlayerRefEvent = @ptrCast(&capture.payload[4]);
            try std.testing.expectEqual(@as(i64, 7), disconnect_payload.runtime_id);
            const chat_payload: *const abi.PlayerChatEvent = @ptrCast(&capture.payload[5]);
            try std.testing.expectEqualStrings("hi", chat_payload.message.slice());
            const use_payload: *const abi.ItemUseEvent = @ptrCast(&capture.payload[6]);
            try std.testing.expectEqualStrings("minecraft:stone", use_payload.identifier.slice());
            const move_payload: *const abi.PlayerMoveEvent = @ptrCast(&capture.payload[7]);
            try std.testing.expectEqual(@as(f32, 1), move_payload.from_x);
            try std.testing.expectEqual(@as(f32, 6), move_payload.to_z);
            try std.testing.expectEqual(@as(u32, 1), move_payload.on_ground);
            const damage_payload: *const abi.DamageEvent = @ptrCast(&capture.payload[8]);
            try std.testing.expectEqual(@as(i64, 9), damage_payload.victim_runtime);
            try std.testing.expectEqual(@as(f32, 3.5), damage_payload.amount);
            const place_payload: *const abi.BlockPlaceEvent = @ptrCast(&capture.payload[9]);
            try std.testing.expectEqual(@as(i32, 42), place_payload.network_id);
            const break_payload: *const abi.BlockBreakEvent = @ptrCast(&capture.payload[10]);
            try std.testing.expectEqual(@as(i32, 6), break_payload.z);
            const open_payload: *const abi.InventoryEvent = @ptrCast(&capture.payload[11]);
            try std.testing.expectEqual(@as(u32, 4), open_payload.container_id);
            const click_payload: *const abi.InventoryClickEvent = @ptrCast(&capture.payload[12]);
            try std.testing.expectEqual(@as(u16, 5), click_payload.slot);
            try std.testing.expectEqual(@as(u8, 2), click_payload.button);
            const transaction_payload: *const abi.TransactionEvent = @ptrCast(&capture.payload[14]);
            try std.testing.expectEqual(@as(u32, 1), transaction_payload.committed);
            const combust_payload: *const abi.EntityCombustEvent = @ptrCast(&capture.payload[17]);
            try std.testing.expectEqual(@as(i32, 100), combust_payload.duration);
            try std.testing.expectEqual(@as(i64, 10), combust_payload.instigator_runtime);
            const apply_payload: *const abi.EnchantEvent = @ptrCast(&capture.payload[18]);
            try std.testing.expect(apply_payload.item_handle != 0);
            try std.testing.expectEqual(@as(u32, 77), apply_payload.enchantment_id);
            try std.testing.expectEqual(@as(u8, 2), apply_payload.level);
            const remove_payload: *const abi.EnchantEvent = @ptrCast(&capture.payload[19]);
            try std.testing.expectEqual(@as(u32, 88), remove_payload.enchantment_id);
            try std.testing.expectEqual(@as(u8, 0), remove_payload.level);
            const spawn_payload: *const abi.EntitySpawnEvent = @ptrCast(&capture.payload[20]);
            try std.testing.expectEqual(@as(i64, 12), spawn_payload.runtime_id);
            const despawn_payload: *const abi.EntityDespawnEvent = @ptrCast(&capture.payload[21]);
            try std.testing.expectEqual(@as(u32, 1), despawn_payload.cause);
            const entity_damage_payload: *const abi.EntityDamageEvent = @ptrCast(&capture.payload[22]);
            try std.testing.expectEqual(@as(i64, 9), entity_damage_payload.target_runtime);
            const death_payload: *const abi.EntityDeathEvent = @ptrCast(&capture.payload[23]);
            try std.testing.expectEqual(@as(i64, 10), death_payload.killer_runtime);
            const interact_payload: *const abi.EntityInteractEvent = @ptrCast(&capture.payload[24]);
            try std.testing.expectEqual(@as(i64, 7), interact_payload.player_runtime);
        }

        pub fn case_018() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 17, .name = "custom-limits", .host = undefined, .state = .running };
            const name = "phase04.custom.limits";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Capture = struct {
                calls: u32 = 0,
                size: usize = 0,
                order_ok: bool = true,
                expected: u16 = 1,

                fn callback(userdata: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const self: *@This() = @ptrCast(@alignCast(userdata.?));
                    self.calls += 1;
                    self.size = view.data_size;
                    if (view.data_size != @sizeOf(u16)) return;
                    const value: *const u16 = @ptrCast(@alignCast(view.data.?));
                    if (value.* != self.expected) self.order_ok = false;
                    self.expected = value.* + 1;
                }
            };
            var capture = Capture{};
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Capture.callback, &capture, &subscription));

            var payload: [57]u8 = @splat(0xAB);
            try std.testing.expectEqual(abi.result_invalid_argument, runtime.events_api.emit(@ptrCast(&slot), schema, &payload, payload.len, 0));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &payload, abi.custom_payload_max, 0));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit_immediate(@ptrCast(&slot), schema, &payload, payload.len, 0));
            try std.testing.expectEqual(@as(u32, 1), capture.calls);
            try std.testing.expectEqual(@as(usize, 57), capture.size);

            var index: usize = 1;
            while (index < 1024) : (index += 1) {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            }
            try std.testing.expectEqual(abi.result_busy, runtime.events_api.emit(@ptrCast(&slot), schema, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1025), capture.calls);

            capture.expected = 1;
            for (1..5) |value| {
                var ordered: u16 = @intCast(value);
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &ordered, @sizeOf(u16), 0));
            }
            runtime.endTick();
            try std.testing.expect(capture.order_ok);
            try std.testing.expectEqual(@as(u16, 5), capture.expected);
        }

        pub fn case_019() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 18, .name = "schema-version", .host = undefined, .state = .running };
            const name = "phase04.custom.versioned";
            var first: u32 = 0;
            var again: u32 = 0;
            var second: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 1, &first));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 1, &again));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 2, &second));
            try std.testing.expectEqual(first, again);
            try std.testing.expect(first != second);
            try std.testing.expectEqual(@as(u32, 1), first & 0xff);
            try std.testing.expectEqual(@as(u32, 2), second & 0xff);
        }

        pub fn case_020() !void {
            const Player = @import("../player/player.zig").Player;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 19, .name = "move-handles", .host = undefined, .state = .running };

            const Callback = struct {
                fn call(_: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {}
            };
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_move), abi.event_phase_pre, 0, Callback.call, null, &subscription));
            var player: Player = undefined;
            player.entity.runtime_id = 7;
            player.on_ground = true;
            var move = Events.types.PlayerMoveEvent{ .player = &player, .from = .{ .x = 0, .y = 0, .z = 0 }, .to = .{ .x = 1, .y = 0, .z = 0 } };
            var context = Events.EventContext{ .event = .PlayerMove, .phase = .pre };
            const before = runtime.handles.activeCount();
            _ = private_pluginruntime_dispatch(&runtime, .PlayerMove, &context, &move);
            try std.testing.expectEqual(before, runtime.handles.activeCount());
        }

        pub fn case_021() !void {
            const Player = @import("../player/player.zig").Player;
            const Entity = @import("../entity/entity.zig").Entity;
            var counted = CountingAllocator.init(std.testing.allocator);
            defer counted.deinit();
            var events = Events.Events.init(counted.allocator());
            defer events.deinit();
            var runtime = PluginRuntime.init(counted.allocator());
            defer {
                counted.deny_allocations = false;
                runtime.deinit();
            }
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 20, .name = "hot-payloads", .host = undefined, .state = .running };

            const Probe = struct {
                calls: u32 = 0,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var probe = Probe{};
            const ids = [_]u32{ @intFromEnum(abi.EventId.player_move), @intFromEnum(abi.EventId.damage), @intFromEnum(abi.EventId.entity_damage), @intFromEnum(abi.EventId.server_tick) };
            var subscriptions: [ids.len]u64 = undefined;
            for (ids, 0..) |id, index| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), id, abi.event_phase_pre, 0, Probe.callback, &probe, &subscriptions[index]));
            }

            var player: Player = undefined;
            player.entity.runtime_id = 7;
            player.on_ground = true;
            var entity: Entity = undefined;
            entity.runtime_id = 9;
            var move = Events.types.PlayerMoveEvent{ .player = &player, .from = .{ .x = 0, .y = 0, .z = 0 }, .to = .{ .x = 1, .y = 0, .z = 0 } };
            var damage = Events.types.DamageEvent{ .attacker = null, .victim = &entity, .amount = 1, .cause = .fall };
            var entity_damage = Events.types.EntityDamageEvent{ .target = undefined, .target_runtime = 9, .amount = 1, .source = null, .source_runtime = null, .cause = .fall };
            var tick = Events.types.ServerTickEvent{ .tick = 1 };
            var context = Events.EventContext{ .event = .ServerTick, .phase = .pre };

            counted.allocations = 0;
            counted.deny_allocations = true;
            var iteration: usize = 0;
            while (iteration < 1000) : (iteration += 1) {
                _ = private_pluginruntime_dispatch(&runtime, .PlayerMove, &context, &move);
                _ = private_pluginruntime_dispatch(&runtime, .Damage, &context, &damage);
                _ = private_pluginruntime_dispatch(&runtime, .EntityDamage, &context, &entity_damage);
                _ = private_pluginruntime_dispatch(&runtime, .ServerTick, &context, &tick);
            }
            counted.deny_allocations = false;
            try std.testing.expectEqual(@as(u32, 4000), probe.calls);
            try std.testing.expectEqual(@as(usize, 0), counted.allocations);
        }

        pub fn case_022() !void {
            const Player = @import("../player/player.zig").Player;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 21, .name = "mutate-chat", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const chat: *abi.PlayerChatEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    chat.message = .{ .data = "replaced".ptr, .length = "replaced".len };
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_chat), abi.event_phase_pre, 0, Probe.callback, null, &sub));

            var player: Player = undefined;
            player.entity.runtime_id = 7;
            var chat = Events.types.PlayerChatEvent{ .player = &player, .message = "original" };
            try std.testing.expect(events.emit(.PlayerChat, &chat));
            try std.testing.expectEqualStrings("replaced", chat.message);
            try std.testing.expect(chat.owned_message != null);
            std.testing.allocator.free(chat.owned_message.?);
        }

        pub fn case_023() !void {
            const Player = @import("../player/player.zig").Player;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 22, .name = "mutate-move", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const move: *abi.PlayerMoveEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    if (view.phase == abi.event_phase_pre) {
                        move.to_x = 9;
                        move.to_y = 8;
                        move.to_z = 7;
                    } else {
                        move.to_x = 99;
                        move.to_y = 99;
                        move.to_z = 99;
                    }
                }
            };
            var pre: u64 = 0;
            var commit: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_move), abi.event_phase_pre, 0, Probe.callback, null, &pre));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_move), abi.event_phase_commit, 0, Probe.callback, null, &commit));

            var player: Player = undefined;
            player.entity.runtime_id = 7;
            player.on_ground = true;
            var move = Events.types.PlayerMoveEvent{ .player = &player, .from = .{ .x = 0, .y = 0, .z = 0 }, .to = .{ .x = 1, .y = 2, .z = 3 } };
            try std.testing.expect(events.emit(.PlayerMove, &move));
            try std.testing.expectEqual(@as(f32, 9), move.to.x);
            try std.testing.expectEqual(@as(f32, 8), move.to.y);
            try std.testing.expectEqual(@as(f32, 7), move.to.z);
        }

        pub fn case_024() !void {
            const Entity = @import("../entity/entity.zig").Entity;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 23, .name = "mutate-damage", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const damage: *abi.DamageEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    damage.amount = 12.5;
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.damage), abi.event_phase_pre, 0, Probe.callback, null, &sub));

            var victim: Entity = undefined;
            victim.runtime_id = 9;
            var damage = Events.types.DamageEvent{ .attacker = null, .victim = &victim, .amount = 3, .cause = .fire };
            try std.testing.expect(events.emit(.Damage, &damage));
            try std.testing.expectEqual(@as(f32, 12.5), damage.amount);
        }

        pub fn case_025() !void {
            const Entity = @import("../entity/entity.zig").Entity;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 24, .name = "mutate-combust", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const combust: *abi.EntityCombustEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    combust.duration = 7;
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.entity_combust), abi.event_phase_pre, 0, Probe.callback, null, &sub));

            var entity: Entity = undefined;
            entity.runtime_id = 9;
            var combust = Events.types.EntityCombustEvent{ .entity = &entity, .duration = 100, .instigator = null, .source = .lava };
            try std.testing.expect(events.emit(.EntityCombust, &combust));
            try std.testing.expectEqual(@as(i32, 7), combust.duration);
        }

        pub fn case_026() !void {
            const ItemStack = @import("../items/item_stack.zig").ItemStack;
            const Enchantment = @import("../items/enchantments/enchantment.zig").Enchantment;
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 25, .name = "mutate-enchant", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const enchant: *abi.EnchantEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    enchant.level = 5;
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.enchantment_apply), abi.event_phase_pre, 0, Probe.callback, null, &sub));
            try std.testing.expectEqual(@as(u16, 0), abi.eventMeta(.enchantment_remove).flags & abi.event_flag_mutable);

            var stack: ItemStack = undefined;
            var definition: Enchantment = undefined;
            definition.id = 3;
            var apply = Events.types.EnchantmentApplyEvent{ .stack = &stack, .definition = &definition, .previous_level = 1, .level = 2, .source = .plugin, .actor = null };
            try std.testing.expect(events.emit(.EnchantmentApply, &apply));
            try std.testing.expectEqual(@as(u8, 5), apply.level);
        }

        pub fn case_027() !void {
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 26, .name = "mutate-entity-damage", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const damage: *abi.EntityDamageEvent = @ptrCast(@alignCast(@constCast(view.data.?)));
                    damage.amount = 2.25;
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.entity_damage), abi.event_phase_pre, 0, Probe.callback, null, &sub));

            var damage = Events.types.EntityDamageEvent{ .target = undefined, .target_runtime = 9, .amount = 1, .cause = .fall };
            try std.testing.expect(events.emit(.EntityDamage, &damage));
            try std.testing.expectEqual(@as(f32, 2.25), damage.amount);
        }

        pub fn case_028() !void {
            const Player = @import("../player/player.zig").Player;
            const text = @import("../network/handlers/text.zig");
            var events = Events.Events.init(std.testing.allocator);
            defer events.deinit();
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            runtime.attachEvents(&events);
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 27, .name = "chat-guard", .host = undefined, .state = .running };

            const Probe = struct {
                fn callback(_: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    view.result.* = @intFromEnum(abi.EventResult.cancel);
                }
            };
            var sub: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.player_chat), abi.event_phase_pre, 0, Probe.callback, null, &sub));

            var player: Player = undefined;
            player.entity.runtime_id = 7;
            var chat = Events.types.PlayerChatEvent{ .player = &player, .message = "hello" };
            try std.testing.expect(text.acceptedChat(&events, &chat) == null);
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.unsubscribe(@ptrCast(&slot), sub));
            try std.testing.expectEqualStrings("hello", text.acceptedChat(&events, &chat).?);
        }

        pub fn case_029() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 28, .name = "schema-bounds", .host = undefined, .state = .running };
            const name = "phase04.custom.bounds";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_invalid_argument, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0x100, &schema));
            try std.testing.expectEqual(abi.result_invalid_argument, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0x101, &schema));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0xff, &schema));
            try std.testing.expectEqual(@as(u32, 0xff), schema & 0xff);
        }

        pub fn case_030() !void {
            const allocator = std.testing.allocator;
            var runtime = PluginRuntime.init(allocator);
            defer runtime.deinit();

            const first = try allocator.create(HostSlot);
            first.* = .{ .runtime = &runtime, .plugin_id = 1, .name = "", .host = undefined, .state = .running };
            try runtime.slots.append(allocator, first);
            try runtime.plugins.append(allocator, first);
            const second = try allocator.create(HostSlot);
            second.* = .{ .runtime = &runtime, .plugin_id = 2, .name = "", .host = undefined, .state = .running };
            try runtime.slots.append(allocator, second);
            try runtime.plugins.append(allocator, second);

            const name = "phase04.custom.shared";
            var a: u32 = 0;
            var b: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(first), .{ .data = name.ptr, .length = name.len }, 3, &a));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(second), .{ .data = name.ptr, .length = name.len }, 3, &b));
            try std.testing.expectEqual(a, b);
            try std.testing.expectEqual(@as(u32, 2), runtime.custom_schemas.items[0].refs);

            runtime.unloadPlugin(1);
            try std.testing.expect(runtime.slots.items[0] == null);
            var c: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(second), .{ .data = name.ptr, .length = name.len }, 3, &c));
            try std.testing.expectEqual(a, c);
            try std.testing.expectEqual(@as(u32, 1), runtime.custom_schemas.items[0].refs);

            runtime.unloadPlugin(2);
            try std.testing.expect(runtime.custom_schemas.items[0].name == null);
        }

        pub fn case_031() !void {
            const ItemStack = @import("../items/item_stack.zig").ItemStack;
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var stack: ItemStack = undefined;
            const first = private_pluginruntime_itemHandle(&runtime, @ptrCast(&stack));
            const second = private_pluginruntime_itemHandle(&runtime, @ptrCast(&stack));
            try std.testing.expect(first != 0);
            try std.testing.expectEqual(first, second);
            try std.testing.expectEqual(@as(?usize, @intFromPtr(&stack)), runtime.handles.get(.item, first));
            try std.testing.expectEqual(@as(?u32, 0), runtime.handles.ownerOf(@intFromPtr(&stack)));
        }

        pub fn case_032() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 32, .name = "deferred-align", .host = undefined, .state = .running };

            const name = "phase04.custom.align";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Payload = extern struct { a: u64, b: i64, c: f64 };
            const Probe = struct {
                payload: Payload = .{ .a = 0, .b = 0, .c = 0 },
                aligned: bool = false,

                fn callback(userdata: ?*anyopaque, view: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.aligned = @intFromPtr(view.data.?) % @alignOf(Payload) == 0;
                    probe.payload = @as(*const Payload, @ptrCast(@alignCast(view.data.?))).*;
                }
            };
            var probe = Probe{};
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), schema >> 8, abi.event_phase_pre, 0, Probe.callback, &probe, &subscription));

            var payload = Payload{ .a = 0x1122334455667788, .b = -7, .c = 1.5 };
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(&slot), schema, &payload, @sizeOf(Payload), 0));
            runtime.endTick();

            try std.testing.expect(probe.aligned);
            try std.testing.expectEqual(payload.a, probe.payload.a);
            try std.testing.expectEqual(payload.b, probe.payload.b);
            try std.testing.expectEqual(payload.c, probe.payload.c);
        }

        pub fn case_033() !void {
            const allocator = std.testing.allocator;
            var runtime = PluginRuntime.init(allocator);
            defer runtime.deinit();

            const slot = try allocator.create(HostSlot);
            slot.* = .{ .runtime = &runtime, .plugin_id = 1, .name = "", .host = undefined, .state = .running };
            try runtime.slots.append(allocator, slot);
            try runtime.plugins.append(allocator, slot);

            const name = "phase04.custom.deferred-unload";
            var schema: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(slot), .{ .data = name.ptr, .length = name.len }, 0, &schema));

            const Probe = struct {
                calls: u32 = 0,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var probe = Probe{};
            var subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(slot), schema >> 8, abi.event_phase_pre, 0, Probe.callback, &probe, &subscription));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(slot), schema, null, 0, 0));
            try std.testing.expectEqual(@as(usize, 1), runtime.deferredLen());

            runtime.unloadPlugin(1);

            const custom_index = std.meta.fields(Events.Event).len + @as(usize, schema >> 8) - @as(usize, abi.event_custom_base);
            try std.testing.expectEqual(@as(usize, 0), runtime.buckets[custom_index][abi.event_phase_pre].items.len);
            try std.testing.expectEqual(@as(u32, 0), runtime.active[custom_index][abi.event_phase_pre]);

            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 0), probe.calls);
            try std.testing.expectEqual(@as(usize, 0), runtime.deferredLen());
        }

        pub fn case_034() !void {
            const allocator = std.testing.allocator;
            var runtime = PluginRuntime.init(allocator);
            defer runtime.deinit();

            const first = try allocator.create(HostSlot);
            first.* = .{ .runtime = &runtime, .plugin_id = 1, .name = "", .host = undefined, .state = .running };
            try runtime.slots.append(allocator, first);
            try runtime.plugins.append(allocator, first);

            const second = try allocator.create(HostSlot);
            second.* = .{ .runtime = &runtime, .plugin_id = 2, .name = "", .host = undefined, .state = .running };
            try runtime.slots.append(allocator, second);
            try runtime.plugins.append(allocator, second);

            const name = "phase04.custom.tombstone";
            var old: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(first), .{ .data = name.ptr, .length = name.len }, 4, &old));

            const Probe = struct {
                calls: u32 = 0,

                fn callback(userdata: ?*anyopaque, _: *const abi.EventView) callconv(.c) void {
                    const probe: *@This() = @ptrCast(@alignCast(userdata.?));
                    probe.calls += 1;
                }
            };
            var old_probe = Probe{};
            var old_subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(first), old >> 8, abi.event_phase_pre, 0, Probe.callback, &old_probe, &old_subscription));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(first), old, null, 0, 0));
            runtime.endTick();
            try std.testing.expectEqual(@as(u32, 1), old_probe.calls);

            runtime.unloadPlugin(1);

            try std.testing.expectEqual(abi.result_not_found, runtime.events_api.emit(@ptrCast(second), old, null, 0, 0));
            try std.testing.expectEqual(abi.result_not_found, runtime.events_api.subscribe(@ptrCast(second), old >> 8, abi.event_phase_pre, 0, Probe.callback, &old_probe, &old_subscription));

            var fresh: u32 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(second), .{ .data = name.ptr, .length = name.len }, 4, &fresh));
            try std.testing.expect(fresh != old);
            try std.testing.expectEqual(old & 0xff, fresh & 0xff);
            try std.testing.expect((fresh >> 8) != (old >> 8));
            try std.testing.expectEqual(abi.result_not_found, runtime.events_api.emit(@ptrCast(second), old, null, 0, 0));

            const fresh_index = std.meta.fields(Events.Event).len + @as(usize, fresh >> 8) - @as(usize, abi.event_custom_base);
            var fresh_probe = Probe{};
            var fresh_subscription: u64 = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(second), fresh >> 8, abi.event_phase_pre, 0, Probe.callback, &fresh_probe, &fresh_subscription));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.emit(@ptrCast(second), fresh, null, 0, 0));
            runtime.endTick();

            try std.testing.expectEqual(@as(u32, 1), fresh_probe.calls);
            try std.testing.expectEqual(@as(u32, 1), old_probe.calls);
            try std.testing.expectEqual(@as(usize, 1), runtime.buckets[fresh_index][abi.event_phase_pre].items.len);
        }

        pub fn case_035() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();

            const name = "phase04.custom.owners";
            var slots: [9]HostSlot = undefined;
            var schemas: [9]u32 = undefined;
            for (&slots, 0..) |*slot, index| {
                slot.* = .{ .runtime = &runtime, .plugin_id = @intCast(index + 1), .name = "", .host = undefined, .state = .running };
            }
            for (slots[0..8], 0..) |*slot, index| {
                try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(slot), .{ .data = name.ptr, .length = name.len }, 7, &schemas[index]));
                try std.testing.expectEqual(schemas[0], schemas[index]);
            }
            try std.testing.expectEqual(abi.result_limit, runtime.events_api.schema_of(@ptrCast(&slots[8]), .{ .data = name.ptr, .length = name.len }, 7, &schemas[8]));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.schema_of(@ptrCast(&slots[0]), .{ .data = name.ptr, .length = name.len }, 7, &schemas[0]));
            try std.testing.expectEqual(@as(u32, 8), runtime.custom_schemas.items[0].refs);
            try std.testing.expectEqual(@as(u8, 8), runtime.custom_schemas.items[0].owner_len);
        }

        pub fn case_001() !void {
            var runtime = PluginRuntime.init(std.testing.allocator);
            defer runtime.deinit();
            var slot = HostSlot{ .runtime = &runtime, .plugin_id = 0, .name = "test", .host = undefined };

            const payload = "packet";
            const view = abi.StringView{ .data = payload.ptr, .length = payload.len };

            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkSend(@ptrCast(&slot), 1, view, 7));
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkSend(@ptrCast(&slot), 1, .{}, abi.packet_priority_normal));
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkBroadcast(@ptrCast(&slot), .{}, abi.packet_priority_immediate));

            const oversized = try std.testing.allocator.alloc(u8, MAX_PLUGIN_PACKET_BYTES + 1);
            defer std.testing.allocator.free(oversized);
            const big = abi.StringView{ .data = oversized.ptr, .length = oversized.len };
            try std.testing.expectEqual(abi.result_invalid_argument, private_pluginruntime_networkBroadcast(@ptrCast(&slot), big, abi.packet_priority_normal));

            try std.testing.expectEqual(abi.result_not_found, private_pluginruntime_networkSend(@ptrCast(&slot), 1, view, abi.packet_priority_immediate));
            try std.testing.expectEqual(abi.result_not_found, private_pluginruntime_networkBroadcast(@ptrCast(&slot), view, abi.packet_priority_normal));

            try std.testing.expectEqual(SendPriority.normal, private_pluginruntime_sendPriority(abi.packet_priority_normal).?);
            try std.testing.expectEqual(SendPriority.immediate, private_pluginruntime_sendPriority(abi.packet_priority_immediate).?);
            try std.testing.expect(private_pluginruntime_sendPriority(7) == null);
        }
    };
}
