const std = @import("std");

const Protocol = @import("protocol");

const bot = @import("bot.zig");
const framing = @import("framing.zig");
const identity = @import("identity.zig");
const main = @import("main.zig");

test {
    _ = bot;
    _ = framing;
    _ = identity;
    _ = main;
}

test "the forged login chain is accepted by the decoder the server uses" {
    const allocator = std.testing.allocator;

    var credentials = try identity.forge(allocator, "LoadBot0001", 1, .{
        .server_address = "127.0.0.1:19132",
        .game_version = Protocol.MINECRAFT_VERSION,
    });
    defer credentials.deinit();

    var data = try Protocol.Login.Decoder.decodeLoginChain(
        allocator,
        credentials.identity,
        credentials.client,
    );
    defer data.deinit();

    try std.testing.expectEqualStrings("LoadBot0001", data.identity_data.display_name);
    try std.testing.expectEqualStrings("25350000000001", data.identity_data.xuid);
    try std.testing.expectEqual(@as(usize, 36), data.identity_data.identity.len);
    try std.testing.expectEqualStrings("Standard_Custom", data.client_data.skin_id);
    try std.testing.expectEqual(@as(i64, 7), data.client_data.device_os);
    try std.testing.expectEqual(@as(i64, -1), data.client_data.gui_scale);
    try std.testing.expectEqualStrings("127.0.0.1:19132", data.client_data.server_address);
    try std.testing.expect(data.client_data.trusted_skin);
}

test "every bot gets its own identity" {
    const allocator = std.testing.allocator;

    var first = try identity.forge(allocator, "LoadBot0001", 1, .{
        .server_address = "127.0.0.1:19132",
        .game_version = Protocol.MINECRAFT_VERSION,
    });
    defer first.deinit();

    var second = try identity.forge(allocator, "LoadBot0002", 2, .{
        .server_address = "127.0.0.1:19132",
        .game_version = Protocol.MINECRAFT_VERSION,
    });
    defer second.deinit();

    var first_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, first.identity, first.client);
    defer first_data.deinit();

    var second_data = try Protocol.Login.Decoder.decodeLoginChain(allocator, second.identity, second.client);
    defer second_data.deinit();

    try std.testing.expect(!std.mem.eql(
        u8,
        first_data.identity_data.identity,
        second_data.identity_data.identity,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        first_data.identity_data.xuid,
        second_data.identity_data.xuid,
    ));
}
