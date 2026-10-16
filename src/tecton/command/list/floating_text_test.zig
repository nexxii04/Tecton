pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Protocol = scope.Protocol;
        const CommandRegistry = scope.CommandRegistry;
        const MAX_NAME_LENGTH = scope.MAX_NAME_LENGTH;
        const MAX_TEXT_LENGTH = scope.MAX_TEXT_LENGTH;
        const hasValidNameCharacters = scope.hasValidNameCharacters;
        const validateText = scope.validateText;
        const parseAddArgs = scope.parseAddArgs;
        const parseRemoveArgs = scope.parseRemoveArgs;
        const register = scope.register;
        const writeHologramLine = scope.writeHologramLine;

        pub fn case_000() !void {
            const parsed = try parseAddArgs("  shop  \xc2\xa77Tienda    abierta  ");
            try std.testing.expectEqualStrings("shop", parsed.name);
            try std.testing.expectEqualStrings("\xc2\xa77Tienda    abierta", parsed.text);
        }

        pub fn case_001() !void {
            try std.testing.expectError(error.MissingName, parseAddArgs(""));
            try std.testing.expectError(error.MissingName, parseAddArgs("onlyname"));
            try std.testing.expectError(error.MissingText, parseAddArgs("shop   "));
            const long_name = "x" ** (MAX_NAME_LENGTH + 1);
            try std.testing.expectError(error.NameTooLong, parseAddArgs(long_name ++ " text"));
            const long_text = "y" ** (MAX_TEXT_LENGTH + 1);
            try std.testing.expectError(error.TextTooLong, parseAddArgs("shop " ++ long_text));
        }

        pub fn case_002() !void {
            try std.testing.expectError(error.InvalidName, parseAddArgs("ba\xc2\xa7d text"));
            try std.testing.expectError(error.InvalidName, parseAddArgs("bad/name text"));
            try std.testing.expectError(error.InvalidName, parseAddArgs("\x1btext more"));
            try std.testing.expect(hasValidNameCharacters("shop_1.2-a"));
        }

        pub fn case_003() !void {
            try std.testing.expectEqualStrings("shop", try parseRemoveArgs("  shop  "));
            try std.testing.expectError(error.MissingName, parseRemoveArgs("   "));
            const long_name = "x" ** (MAX_NAME_LENGTH + 1);
            try std.testing.expectError(error.NameTooLong, parseRemoveArgs(long_name));
            try std.testing.expectError(error.InvalidName, parseRemoveArgs("bad/name"));
        }

        pub fn case_004() !void {
            try validateText("Hola\n\xc2\xa77mundo");
            try std.testing.expectError(error.EmptyText, validateText("\n   \n"));
            try std.testing.expectError(error.InvalidText, validateText("Hola\tMundo"));
            try std.testing.expectError(error.InvalidText, validateText("Hola\x1bMundo"));
            try std.testing.expectError(error.InvalidText, validateText("Hola\x7fMundo"));
        }

        pub fn case_005() !void {
            const allocator = std.testing.allocator;

            const decoded = try Protocol.FloatingText.decodeEscapes(allocator, "Linea 1\\nLinea 2");
            defer allocator.free(decoded);
            try validateText(decoded);

            const name_tag = try Protocol.FloatingText.composeNameTag(allocator, "", decoded);
            defer allocator.free(name_tag);
            try std.testing.expectEqualStrings("Linea 1\nLinea 2", name_tag);
        }

        pub fn case_006() !void {
            const allocator = std.testing.allocator;

            var registry = CommandRegistry.init(allocator);
            defer registry.deinit();

            try register(&registry);

            try std.testing.expectEqual(@as(usize, 1), registry.enums.items.len);
            try std.testing.expectEqualStrings("FloatingTextName", registry.enums.items[0].name);
            try std.testing.expect(!registry.enums.items[0].owned);

            const cmd = registry.findCommand("floatingtext") orelse return error.TestUnexpectedResult;
            const add = cmd.subcommands.get("add") orelse return error.TestUnexpectedResult;
            const edit = cmd.subcommands.get("edit") orelse return error.TestUnexpectedResult;
            const remove = cmd.subcommands.get("remove") orelse return error.TestUnexpectedResult;
            const info = cmd.subcommands.get("info") orelse return error.TestUnexpectedResult;

            try std.testing.expectEqual(@as(usize, 2), edit.params.len);
            try std.testing.expectEqualStrings("name", edit.params[0].name);
            try std.testing.expectEqual(@as(?u32, null), add.params[0].enum_index);
            try std.testing.expectEqual(@as(?u32, 0), edit.params[0].enum_index);
            try std.testing.expectEqual(@as(?u32, 0), remove.params[0].enum_index);
            try std.testing.expectEqual(@as(?u32, 0), info.params[0].enum_index);
            const list = cmd.subcommands.get("list") orelse return error.TestUnexpectedResult;
            try std.testing.expect(cmd.handler == &scope.handle);
            try std.testing.expect(add.handler == &scope.handle_add);
            try std.testing.expect(edit.handler == &scope.handle_edit);
            try std.testing.expect(remove.handler == &scope.handle_remove);
            try std.testing.expect(list.handler == &scope.handle_list);
            try std.testing.expect(info.handler == &scope.handle_info);
        }

        pub fn case_007() !void {
            var buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);

            try writeHologramLine(&writer, "shop", Protocol.Vector3f.init(10.5, 64.0, -3.5), 2);
            try std.testing.expectEqualStrings(
                "\n  §bshop§r §8- §a10.5§7,§a64.0§7,§a-3.5§r §8(§7viewers: §f2§8)",
                writer.buffered(),
            );
        }

        pub fn case_008() !void {
            const allocator = std.testing.allocator;

            const decoded = try Protocol.FloatingText.decodeEscapes(allocator, "\\n\\n");
            defer allocator.free(decoded);
            try std.testing.expectError(error.EmptyText, validateText(decoded));
        }
        pub fn case_009() !void {
            const Context = struct {
                buffer: [256]u8 = undefined,
                message: []const u8 = &.{},
                success: bool = true,

                pub fn sendOutput(self: *@This(), success: bool, message: []const u8) void {
                    @memcpy(self.buffer[0..message.len], message);
                    self.message = self.buffer[0..message.len];
                    self.success = success;
                }
            };
            var ctx = Context{};
            const argument_cases = .{
                .{ error.MissingName, "usage" },
                .{ error.InvalidName, "Name may only contain letters, numbers, '_', '-' and '.'" },
                .{ error.NameTooLong, "Name must be 32 characters or less" },
                .{ error.MissingText, "Floating text cannot be empty" },
                .{ error.TextTooLong, "Floating text is too long" },
            };
            inline for (argument_cases) |entry| {
                scope.output.send_text_args_error(&ctx, entry[0], "usage");
                try std.testing.expect(!ctx.success);
                try std.testing.expectEqualStrings(entry[1], ctx.message);
            }
            scope.output.send_text_error(&ctx, error.EmptyText);
            try std.testing.expectEqualStrings("Floating text cannot be empty", ctx.message);
            scope.output.send_text_error(&ctx, error.InvalidText);
            try std.testing.expectEqualStrings("Floating text contains invalid characters", ctx.message);
            scope.output.report_not_found(&ctx, "shop");
            try std.testing.expectEqualStrings("Floating text 'shop' not found", ctx.message);
            inline for (argument_cases, 0..) |entry, index| {
                if (comptime index < 3) {
                    scope.output.send_name_error(&ctx, entry[0], "usage");
                    try std.testing.expect(!ctx.success);
                    try std.testing.expectEqualStrings(entry[1], ctx.message);
                }
            }
        }
    };
}
