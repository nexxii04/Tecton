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

            var chat = Events.types.PlayerChatEvent{ .player = undefined, .message = "hello" };
            try std.testing.expect(events.emit(.PlayerChat, &chat));
            try std.testing.expectEqual(@as(usize, 2), probe.len);
            try std.testing.expectEqual(@as(u8, 1), probe.calls[0]);
            try std.testing.expectEqual(@as(u8, 2), probe.calls[1]);

            probe.len = 0;
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.cancel, &probe, &first));
            try std.testing.expectEqual(abi.result_ok, runtime.events_api.subscribe(@ptrCast(&slot), @intFromEnum(abi.EventId.server_tick), abi.event_phase_pre, 0, Probe.observe, &probe, &second));

            var tick = Events.types.ServerTickEvent{ .tick = 1 };
            try std.testing.expect(!events.emit(.ServerTick, &tick));
            try std.testing.expectEqual(@as(usize, 1), probe.len);
            try std.testing.expectEqual(@as(u8, 1), probe.calls[0]);
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
