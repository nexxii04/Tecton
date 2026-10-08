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

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var stack = try testStack(allocator, "minecraft:test_api_sword", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            const sharpness = registry.resolve("sharpness").?;
            const smite = registry.resolve("smite").?;
            const efficiency = registry.resolve("efficiency").?;
            const mending = registry.resolve("mending").?;

            switch (enchant(&stack, sharpness.id, 3, .{})) {
                .applied => |applied| {
                    try std.testing.expectEqual(@as(u8, 3), applied.instance.level);
                    try std.testing.expect(!applied.clamped);
                },
                else => return error.ExpectedApplied,
            }
            try std.testing.expectEqual(@as(u8, 3), levelOf(&stack, sharpness.id).?);
            try std.testing.expect(enchantedKey(&stack));

            try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .applied);
            try std.testing.expectEqual(@as(u8, 1), count(&stack));
            try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .unchanged);
            try std.testing.expect(enchant(&stack, sharpness.id, 9, .{}) == .unchanged);

            try std.testing.expect(remove(&stack, sharpness.id, .{}) == .removed);
            switch (enchant(&stack, sharpness.id, 9, .{})) {
                .applied => |applied| {
                    try std.testing.expectEqual(@as(u8, 5), applied.instance.level);
                    try std.testing.expect(applied.clamped);
                },
                else => return error.ExpectedApplied,
            }
            try expectReject(enchant(&stack, sharpness.id, 9, .{ .clamp_level = false }), error.invalid_level);
            try std.testing.expect(enchant(&stack, sharpness.id, 0, .{}) == .removed);
            try std.testing.expectEqual(@as(u8, 0), count(&stack));
            try std.testing.expect(!enchantedKey(&stack));
            try std.testing.expect(enchant(&stack, sharpness.id, 5, .{}) == .applied);
            try expectReject(enchant(&stack, 999, 1, .{}), error.unknown_enchantment);
            try expectReject(enchant(&stack, efficiency.id, 1, .{}), error.not_applicable);
            try expectReject(enchant(&stack, smite.id, 1, .{}), error.conflicts);

            try std.testing.expectEqual(@as(u8, 1), count(&stack));

            switch (enchant(&stack, smite.id, 1, .{ .allow_conflicts = true })) {
                .applied => |applied| try std.testing.expectEqual(@as(u8, 1), applied.instance.level),
                else => return error.ExpectedApplied,
            }
            try std.testing.expectEqual(@as(u8, 2), count(&stack));

            try std.testing.expect(hasName(&stack, "smite"));
            try std.testing.expect(has(&stack, mending.id) == false);
            try std.testing.expectEqual(@as(u32, 6), totalLevels(&stack));
            try std.testing.expectEqual(sharpness.id, highestOfGroup(&stack, 2).?.id);
            try std.testing.expectEqual(@as(?EnchantmentInstance, null), highestOfGroup(&stack, 0));
            try std.testing.expectEqual(sharpness.id, highestOfCategory(&stack, sharpness.category).?.id);
            try std.testing.expect(matches(&stack, &EnchantmentSet.fromIds(&.{smite.id})));
            try std.testing.expect(!matches(&stack, &EnchantmentSet.fromIds(&.{mending.id})));
            try std.testing.expect(isEnchanted(&stack));
            try std.testing.expect(canEnchant(stack.item_type, sharpness.id));
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var stack = try testStack(allocator, "minecraft:test_api_add_levels", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            const sharpness = registry.resolve("sharpness").?;

            try std.testing.expect(enchantName(&stack, "sharpness", 2, .{}) == .applied);
            switch (addLevels(&stack, sharpness.id, 2, .{})) {
                .applied => |applied| try std.testing.expectEqual(@as(u8, 4), applied.instance.level),
                else => return error.ExpectedApplied,
            }
            switch (addLevels(&stack, sharpness.id, 4, .{})) {
                .applied => |applied| try std.testing.expectEqual(sharpness.max_level, applied.instance.level),
                else => return error.ExpectedApplied,
            }
            try expectReject(addLevels(&stack, 999, 1, .{}), error.unknown_enchantment);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var stack = try testStack(allocator, "minecraft:test_api_remove", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            try std.testing.expect(remove(&stack, 9, .{}) == .unchanged);
            try std.testing.expect(enchantName(&stack, "sharpness", 3, .{}) == .applied);
            try std.testing.expect(enchantedKey(&stack));

            try std.testing.expect(remove(&stack, 9, .{}) == .removed);
            try std.testing.expect(!enchantedKey(&stack));
            try std.testing.expectEqual(@as(u8, 0), count(&stack));

            try std.testing.expect(enchantName(&stack, "unbreaking", 2, .{}) == .applied);
            try std.testing.expectEqual(@as(u8, 1), try clear(&stack));
            try std.testing.expectEqual(@as(u8, 0), try clear(&stack));
            try std.testing.expect(!enchantedKey(&stack));
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var stack = try testStack(allocator, "minecraft:test_api_wire_removal", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            try std.testing.expect(enchantName(&stack, "sharpness", 5, .{}) == .applied);

            const before = stack.toNetworkStack().extras.?.nbt.?;
            try std.testing.expect(before.get(nbt.KEY) != null);
            try std.testing.expect(before.get("tag") == null);

            try std.testing.expect(remove(&stack, 9, .{}) == .removed);
            try std.testing.expect(!isEnchanted(&stack));

            const after = stack.toNetworkStack();
            if (after.extras) |extras| {
                try std.testing.expect(extras.nbt.?.get(nbt.KEY) == null);
                try std.testing.expect(extras.nbt.?.get("tag") == null);
            }
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            var stack = try testStack(allocator, "minecraft:test_api_set_many", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            _ = stack.enchantments.set(26, 1);

            const conflicting = [_]EnchantmentInstance{
                .{ .id = 9, .level = 5 },
                .{ .id = 10, .level = 1 },
            };
            const report = setMany(&stack, &conflicting, .replace, .{});
            try std.testing.expectEqual(Reject.conflicts, report.rejected.?);
            try std.testing.expectEqual(@as(u16, 10), report.rejected_id.?);
            try std.testing.expectEqual(@as(u8, 1), count(&stack));
            try std.testing.expectEqual(@as(u8, 1), levelOf(&stack, 26).?);

            const valid = [_]EnchantmentInstance{
                .{ .id = 17, .level = 3 },
                .{ .id = 9, .level = 5 },
            };
            const applied = setMany(&stack, &valid, .replace, .{});
            try std.testing.expectEqual(@as(?Reject, null), applied.rejected);
            try std.testing.expectEqual(@as(u8, 2), applied.applied);
            try std.testing.expectEqual(@as(u8, 2), count(&stack));
            try std.testing.expectEqual(@as(?u8, null), levelOf(&stack, 26));
            try std.testing.expectEqual(@as(u8, 5), levelOf(&stack, 9).?);

            const merged = [_]EnchantmentInstance{.{ .id = 9, .level = 2 }};
            const merge_report = setMany(&stack, &merged, .merge, .{});
            try std.testing.expectEqual(@as(u8, 1), merge_report.applied);
            try std.testing.expectEqual(@as(u8, 5), levelOf(&stack, 9).?);
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();

            const item_type = try native_testing.itemType(allocator, "minecraft:enchanted_book", &.{}, true);
            defer item_type.deinit();
            var stack = ItemStack.init(allocator, item_type, .{});
            defer stack.deinit();

            var entries: [storage.MAX_ENCHANTMENTS + 1]EnchantmentInstance = undefined;
            for (&entries, 0..) |*entry, index| entry.* = .{ .id = @intCast(index), .level = 1 };

            const opts: Options = .{ .allow_books = true, .allow_conflicts = true };
            const report = setMany(&stack, &entries, .replace, opts);

            try std.testing.expectEqual(Reject.too_many, report.rejected.?);
            try std.testing.expectEqual(@as(?u16, storage.MAX_ENCHANTMENTS), report.rejected_id);
            try std.testing.expectEqual(@as(u8, 0), report.applied);
            try std.testing.expectEqual(@as(u8, 0), count(&stack));
            try std.testing.expect(!enchantedKey(&stack));
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var stack = try testStack(allocator, "minecraft:test_ops_rollback", true);
            defer stack.deinit();
            defer stack.item_type.deinit();

            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
            stack.allocator = failing.allocator();
            defer stack.allocator = allocator;

            const sharpness = registry.resolve("sharpness").?;
            try expectReject(enchant(&stack, sharpness.id, 3, .{}), error.storage_failure);
            try std.testing.expectEqual(@as(u8, 0), count(&stack));
            try std.testing.expect(!isEnchanted(&stack));
            try std.testing.expect(stack.enchantments.dirty);

            if (stack.nbt) |*leftover| leftover.deinit(allocator);
            stack.nbt = null;
            stack.allocator = allocator;

            try std.testing.expect(enchant(&stack, sharpness.id, 3, .{}) == .applied);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&stack, sharpness.id).?);
        }

        pub fn case_007() !void {
            const allocator = std.testing.allocator;
            _ = try registry_mod.load();
            const registry = registry_mod.global().?;

            var source = try testStack(allocator, "minecraft:test_ops_source", true);
            defer source.deinit();
            defer source.item_type.deinit();
            var target = try testStack(allocator, "minecraft:test_ops_target", true);
            defer target.deinit();
            defer target.item_type.deinit();

            const sharpness = registry.resolve("sharpness").?;
            const smite = registry.resolve("smite").?;

            _ = source.enchantments.set(sharpness.id, 3);
            _ = source.enchantments.set(smite.id, 2);
            _ = target.enchantments.set(sharpness.id, 5);

            const report = try transferTo(&source, &target, .{ .overwrite_existing = false, .respect_conflicts = false });
            try std.testing.expectEqual(@as(u8, 1), report.skipped);
            try std.testing.expectEqual(@as(u8, 1), report.moved);
            try std.testing.expectEqual(@as(u8, 3), levelOf(&source, sharpness.id).?);
            try std.testing.expectEqual(@as(u8, 5), levelOf(&target, sharpness.id).?);
            try std.testing.expectEqual(@as(u8, 2), levelOf(&target, smite.id).?);
            try std.testing.expectEqual(@as(u8, 0), levelOf(&source, smite.id) orelse 0);
        }

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
