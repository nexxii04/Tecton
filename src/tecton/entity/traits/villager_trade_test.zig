pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const BinaryStream = scope.BinaryStream;
        const NBT = scope.NBT;
        const Container = scope.Container;
        const ItemType = scope.ItemType;
        const ItemStack = scope.ItemStack;
        const TRADE_RECIPE_BASE = scope.TRADE_RECIPE_BASE;
        const State = scope.State;
        const unlimited_nbt_max_uses = scope.unlimited_nbt_max_uses;
        const clearOffers = scope.clearOffers;
        const appendRecipes = scope.appendRecipes;
        const buildOffersNbt = scope.buildOffersNbt;
        const findSatisfiedOffer = scope.findSatisfiedOffer;
        const executeTrade = scope.executeTrade;
        const registerTestItem = scope.registerTestItem;
        const initTestState = scope.initTestState;
        const deinitTestState = scope.deinitTestState;

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_trade_wheat", 9001);
            try registerTestItem(allocator, "minecraft:test_trade_emerald", 9002);
            const wheat = ItemType.get("minecraft:test_trade_wheat") orelse return error.TestUnexpectedResult;
            const emerald = ItemType.get("minecraft:test_trade_emerald") orelse return error.TestUnexpectedResult;

            var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
            defer deinitTestState(allocator, &state);

            var input = try Container.init(allocator, .Trading, 2);
            defer input.deinit();
            var output = try Container.init(allocator, .Trading, 1);
            defer output.deinit();

            input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 25 }));

            try std.testing.expect(executeTrade(allocator, &state, &input, &output, TRADE_RECIPE_BASE + 7, 1));

            const remaining = input.getItem(0) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 5), remaining.stack_size);

            const created = output.getItem(0) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(emerald, created.item_type);
            try std.testing.expectEqual(@as(u16, 1), created.stack_size);

            try std.testing.expectEqual(@as(i32, 1), state.offers.items[0].uses);
            try std.testing.expectEqual(@as(i32, 2), state.trade_exp);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_trade_wheat", 9003);
            try registerTestItem(allocator, "minecraft:test_trade_emerald", 9004);

            var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
            defer deinitTestState(allocator, &state);

            var input = try Container.init(allocator, .Trading, 2);
            defer input.deinit();
            var output = try Container.init(allocator, .Trading, 1);
            defer output.deinit();

            const emerald = ItemType.get("minecraft:test_trade_emerald") orelse return error.TestUnexpectedResult;
            input.setItem(0, ItemStack.init(allocator, emerald, .{ .stack_size = 25 }));

            try std.testing.expect(!executeTrade(allocator, &state, &input, &output, TRADE_RECIPE_BASE + 7, 1));
            try std.testing.expect(output.getItem(0) == null);
            try std.testing.expectEqual(@as(i32, 0), state.offers.items[0].uses);

            const untouched = input.getItem(0) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(u16, 25), untouched.stack_size);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_trade_wheat", 9007);
            try registerTestItem(allocator, "minecraft:test_trade_emerald", 9008);

            var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
            defer deinitTestState(allocator, &state);

            var input = try Container.init(allocator, .Trading, 2);
            defer input.deinit();

            try std.testing.expect(findSatisfiedOffer(&state, &input) == null);

            const wheat = ItemType.get("minecraft:test_trade_wheat") orelse return error.TestUnexpectedResult;
            input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 10 }));
            try std.testing.expect(findSatisfiedOffer(&state, &input) == null);

            input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 20 }));
            try std.testing.expect(findSatisfiedOffer(&state, &input) != null);

            state.offers.items[0].uses = 16;
            try std.testing.expect(findSatisfiedOffer(&state, &input) == null);
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_set_wheat", 9101);
            try registerTestItem(allocator, "minecraft:test_set_emerald", 9102);

            var state = State{ .initialized = true };
            defer {
                clearOffers(&state, allocator);
                state.offers.deinit(allocator);
            }

            try appendRecipes(&state, allocator, &.{
                .{
                    .buy_a = .{ .identifier = "minecraft:test_set_wheat", .count = 20 },
                    .sell = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
                },
                .{
                    .buy_a = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
                    .sell = .{ .identifier = "minecraft:test_set_wheat", .count = 2 },
                    .max_uses = 4,
                },
            });
            try std.testing.expectEqual(@as(usize, 2), state.offers.items.len);

            try std.testing.expectError(error.UnknownTradeItem, appendRecipes(&state, allocator, &.{
                .{
                    .buy_a = .{ .identifier = "minecraft:definitely_missing", .count = 1 },
                    .sell = .{ .identifier = "minecraft:test_set_emerald", .count = 1 },
                },
            }));
            try std.testing.expectEqual(@as(usize, 2), state.offers.items.len);

            clearOffers(&state, allocator);
            try std.testing.expectEqual(@as(usize, 0), state.offers.items.len);
        }

        pub fn case_004() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_unlim_wheat", 9103);
            try registerTestItem(allocator, "minecraft:test_unlim_emerald", 9104);

            var state = State{ .initialized = true };
            defer {
                clearOffers(&state, allocator);
                state.offers.deinit(allocator);
            }

            try appendRecipes(&state, allocator, &.{
                .{
                    .buy_a = .{ .identifier = "minecraft:test_unlim_wheat", .count = 1 },
                    .sell = .{ .identifier = "minecraft:test_unlim_emerald", .count = 1 },
                    .unlimited = true,
                },
            });

            var input = try Container.init(allocator, .Trading, 2);
            defer input.deinit();
            var output = try Container.init(allocator, .Trading, 1);
            defer output.deinit();

            const wheat = ItemType.get("minecraft:test_unlim_wheat") orelse return error.TestUnexpectedResult;
            const offer = &state.offers.items[0];
            offer.uses = 10000;

            input.setItem(0, ItemStack.init(allocator, wheat, .{ .stack_size = 1 }));
            try std.testing.expect(findSatisfiedOffer(&state, &input) != null);
            try std.testing.expect(executeTrade(allocator, &state, &input, &output, offer.net_id, 1));

            var nbt = try buildOffersNbt(allocator, &state);
            defer nbt.deinit(allocator);
            const root = switch (nbt) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };
            const recipes = switch (root.get("Recipes") orelse return error.TestUnexpectedResult) {
                .List => |list| list,
                else => return error.TestUnexpectedResult,
            };
            const recipe = switch (recipes.value[0]) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };
            const max_uses = switch (recipe.get("maxUses") orelse return error.TestUnexpectedResult) {
                .Int => |int| int.value,
                else => return error.TestUnexpectedResult,
            };
            const uses = switch (recipe.get("uses") orelse return error.TestUnexpectedResult) {
                .Int => |int| int.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(unlimited_nbt_max_uses, max_uses);
            try std.testing.expectEqual(@as(i32, 0), uses);
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;
            try ItemType.initRegistry(allocator);
            defer ItemType.deinitRegistry();

            try registerTestItem(allocator, "minecraft:test_trade_wheat", 9005);
            try registerTestItem(allocator, "minecraft:test_trade_emerald", 9006);

            var state = try initTestState(allocator, "minecraft:test_trade_wheat", "minecraft:test_trade_emerald");
            defer deinitTestState(allocator, &state);
            state.tier = 2;
            state.trade_exp = 70;
            state.offers.items[0].tier = 2;

            var offers = try buildOffersNbt(allocator, &state);
            defer offers.deinit(allocator);

            var stream = BinaryStream.init(allocator, null, null);
            defer stream.deinit();
            try offers.write(&stream, .network);

            var read_stream = BinaryStream.init(allocator, stream.getBuffer(), null);
            defer read_stream.deinit();
            var parsed = try NBT.Tag.read(&read_stream, allocator, .network);
            defer parsed.deinit(allocator);

            const root = switch (parsed) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };

            const recipes = switch (root.get("Recipes") orelse return error.TestUnexpectedResult) {
                .List => |list| list,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 1), recipes.value.len);

            const recipe = switch (recipes.value[0]) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };
            const buy_a = switch (recipe.get("buyA") orelse return error.TestUnexpectedResult) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };
            const buy_a_name = switch (buy_a.get("Name") orelse return error.TestUnexpectedResult) {
                .String => |string| string.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("minecraft:test_trade_wheat", buy_a_name);

            const sell = switch (recipe.get("sell") orelse return error.TestUnexpectedResult) {
                .Compound => |*compound| compound,
                else => return error.TestUnexpectedResult,
            };
            const sell_name = switch (sell.get("Name") orelse return error.TestUnexpectedResult) {
                .String => |string| string.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqualStrings("minecraft:test_trade_emerald", sell_name);
            const sell_count = switch (sell.get("Count") orelse return error.TestUnexpectedResult) {
                .Byte => |byte| byte.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(i8, 1), sell_count);

            const net_id = switch (recipe.get("netId") orelse return error.TestUnexpectedResult) {
                .Int => |int| int.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(i32, @intCast(TRADE_RECIPE_BASE + 7)), net_id);
            const tier = switch (recipe.get("tier") orelse return error.TestUnexpectedResult) {
                .Int => |int| int.value,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(i32, 2), tier);

            const tier_requirements = switch (root.get("TierExpRequirements") orelse return error.TestUnexpectedResult) {
                .List => |list| list,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 5), tier_requirements.value.len);
        }
    };
}
