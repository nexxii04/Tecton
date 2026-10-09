pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const enchantment = scope.enchantment;
        const EnchantmentInstance = scope.EnchantmentInstance;
        const ItemStack = scope.ItemStack;
        const storage = scope.storage;
        const registry_mod = scope.registry_mod;
        const nbt = scope.nbt;
        const EnchantmentSet = scope.EnchantmentSet;
        const events = scope.events;
        const Options = scope.Options;
        const Reject = scope.Reject;
        const rejected = scope.rejected;
        const isEnchanted = scope.isEnchanted;
        const count = scope.count;
        const level = scope.level;
        const has = scope.has;
        const hasName = scope.hasName;
        const totalLevels = scope.totalLevels;
        const matches = scope.matches;
        const highestOfGroup = scope.highestOfGroup;
        const highestOfCategory = scope.highestOfCategory;
        const canEnchant = scope.canEnchant;
        const enchant = scope.enchant;
        const enchantName = scope.enchantName;
        const addLevels = scope.addLevels;
        const remove = scope.remove;
        const clear = scope.clear;
        const setMany = scope.setMany;
        const absorb = scope.absorb;
        const transferTo = scope.transferTo;
        const copyTo = scope.copyTo;
        const syncNbt = scope.syncNbt;
        const native_testing = scope.native_testing;
        const testStack = scope.testStack;
        const expectReject = scope.expectReject;
        const enchantedKey = scope.enchantedKey;
        const levelOf = scope.levelOf;

        pub fn case_008() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var source = try testStack(allocator, "minecraft:test_ops_drain_source", false);
            defer source.deinit();
            defer source.item_type.deinit();
            var target = try testStack(allocator, "minecraft:test_ops_drain_target", false);
            defer target.deinit();
            defer target.item_type.deinit();

            _ = source.enchantments.set(17, 2);
            _ = source.enchantments.set(18, 3);

            const report = try transferTo(&source, &target, .{});
            try std.testing.expectEqual(@as(u8, 2), report.moved);
            try std.testing.expectEqual(@as(u8, 0), count(&source));
            try std.testing.expect(!isEnchanted(&source));
            try std.testing.expectEqual(@as(u8, 2), levelOf(&target, 17).?);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 18).?);
        }

        pub fn case_009() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var source = try testStack(allocator, "minecraft:test_ops_idle_source", true);
            defer source.deinit();
            defer source.item_type.deinit();
            var target = try testStack(allocator, "minecraft:test_ops_idle_target", true);
            defer target.deinit();
            defer target.item_type.deinit();

            const sharpness = registry.resolve("sharpness").?;
            _ = source.enchantments.set(sharpness.id, 3);
            _ = target.enchantments.set(sharpness.id, 5);
            try syncNbt(&source);

            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
            source.allocator = failing.allocator();
            defer source.allocator = allocator;

            const report = try transferTo(&source, &target, .{ .overwrite_existing = false });
            try std.testing.expectEqual(@as(u8, 0), report.moved);
            try std.testing.expectEqual(@as(u8, 1), report.skipped);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&source, sharpness.id).?);
            try std.testing.expect(!source.enchantments.dirty);
            try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        }

        pub fn case_010() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var stack = try testStack(allocator, "minecraft:test_api_veto", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            var bus = events.Events.init(allocator);
            defer bus.deinit();

            const listeners = struct {
                fn veto(_: *events.EventContext, event: *events.types.EnchantmentApplyEvent) events.EventResult {
                    if (event.stack.enchantments.count() > 0) return .cancel;
                    return .continue_;
                }
            };
            _ = try bus.subscribe(.EnchantmentApply, .pre, 10, 1, listeners.veto);

            try std.testing.expect(enchantName(&stack, "sharpness", 3, .{ .events = &bus }) == .applied);
            try expectReject(enchantName(&stack, "unbreaking", 1, .{ .events = &bus }), error.rule_vetoed);
            try std.testing.expectEqual(@as(u8, 1), count(&stack));
            try std.testing.expect(remove(&stack, 9, .{}) == .removed);
        }

        pub fn case_011() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var stack = try testStack(allocator, "minecraft:test_api_rewrite", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            var bus = events.Events.init(allocator);
            defer bus.deinit();

            const listeners = struct {
                fn downgrade(_: *events.EventContext, event: *events.types.EnchantmentApplyEvent) events.EventResult {
                    event.level = 1;
                    return .continue_;
                }
            };
            _ = try bus.subscribe(.EnchantmentApply, .pre, 10, 1, listeners.downgrade);

            switch (enchantName(&stack, "sharpness", 5, .{ .events = &bus, .source = .plugin })) {
                .applied => |applied| {
                    try std.testing.expectEqual(@as(u8, 1), applied.instance.level);
                    try std.testing.expect(applied.clamped);
                },
                else => return error.ExpectedApplied,
            }
        }

        pub fn case_012() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var target = try testStack(allocator, "minecraft:test_api_target", false);
            defer target.deinit();
            defer target.item_type.deinit();
            var source = try testStack(allocator, "minecraft:test_api_source", false);
            defer source.deinit();
            defer source.item_type.deinit();

            _ = target.enchantments.set(registry.resolve("silk_touch").?.id, 1);
            _ = target.enchantments.set(17, 1);
            _ = source.enchantments.set(registry.resolve("fortune").?.id, 3);
            _ = source.enchantments.set(17, 2);
            _ = source.enchantments.set(26, 1);

            const report = try transferTo(&source, &target, .{});
            try std.testing.expectEqual(@as(u8, 1), report.moved);
            try std.testing.expectEqual(@as(u8, 1), report.merged);
            try std.testing.expectEqual(@as(u8, 1), report.skipped);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 17).?);
            try std.testing.expectEqual(@as(u8, 1), levelOf(&target, 26).?);
            try std.testing.expectEqual(@as(u8, 1), count(&source));
            try std.testing.expect(levelOf(&source, 18) != null);

            const copy_report = try copyTo(&source, &target, .{ .respect_conflicts = false });
            try std.testing.expectEqual(@as(u8, 1), copy_report.moved);
            try std.testing.expectEqual(@as(u8, 0), copy_report.skipped);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&target, 18).?);
            try std.testing.expectEqual(@as(u8, 1), count(&source));

            var clone = try source.cloneWithCount(allocator, 2);
            defer clone.deinit();
            try std.testing.expect(clone.enchantments.eql(&source.enchantments));
            try std.testing.expectEqual(@as(u16, 2), clone.stack_size);

            var other = try testStack(allocator, "minecraft:test_api_other", false);
            defer other.deinit();
            defer other.item_type.deinit();
            try std.testing.expect(source.isStackCompatible(&clone));
            try std.testing.expect(!source.isStackCompatible(&other));
            _ = other.enchantments.set(9, 1);
            try std.testing.expect(!clone.isStackCompatible(&other));

            try std.testing.expectEqual(@as(u8, 1), try clear(&clone));
            try std.testing.expect(clone.enchantments.isEmpty());
            try std.testing.expect(!source.enchantments.isEmpty());
            syncNbt(&clone) catch return error.UnexpectedSyncFailure;
        }
    };
}
