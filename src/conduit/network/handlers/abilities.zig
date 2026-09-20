const std = @import("std");
const Protocol = @import("protocol");

pub fn buildAbilities(
    allocator: std.mem.Allocator,
    runtime_id: i64,
    gamemode: Protocol.GameMode,
    is_operator: bool,
) !Protocol.UpdateAbilitiesPacket {
    const creative = gamemode == .Creative;
    const spectator = gamemode == .Spectator;
    const AbilitySet = Protocol.AbilitySet;
    const abilities = try allocator.alloc(AbilitySet, 19);
    abilities[0] = .{ .ability = .Build, .value = !spectator };
    abilities[1] = .{ .ability = .Mine, .value = !spectator };
    abilities[2] = .{ .ability = .DoorsAndSwitches, .value = !spectator };
    abilities[3] = .{ .ability = .OpenContainers, .value = !spectator };
    abilities[4] = .{ .ability = .AttackPlayers, .value = !spectator };
    abilities[5] = .{ .ability = .AttackMobs, .value = !spectator };
    abilities[6] = .{ .ability = .OperatorCommands, .value = is_operator };
    abilities[7] = .{ .ability = .Teleport, .value = is_operator };
    abilities[8] = .{ .ability = .Invulnerable, .value = creative };
    abilities[9] = .{ .ability = .Flying, .value = false };
    abilities[10] = .{ .ability = .MayFly, .value = creative };
    abilities[11] = .{ .ability = .InstantBuild, .value = creative };
    abilities[12] = .{ .ability = .Lightning, .value = false };
    abilities[13] = .{ .ability = .FlySpeed, .value = true };
    abilities[14] = .{ .ability = .WalkSpeed, .value = true };
    abilities[15] = .{ .ability = .Muted, .value = false };
    abilities[16] = .{ .ability = .WorldBuilder, .value = false };
    abilities[17] = .{ .ability = .NoClip, .value = false };
    abilities[18] = .{ .ability = .PrivilegedBuilder, .value = false };

    const layers = try allocator.alloc(Protocol.AbilityLayer, 1);
    layers[0] = .{
        .layer_type = @intFromEnum(Protocol.AbilityLayerType.Base),
        .abilities = abilities,
        .fly_speed = 0.05,
        .vertical_fly_speed = 1.0,
        .walk_speed = 0.1,
    };

    return Protocol.UpdateAbilitiesPacket.init(
        allocator,
        runtime_id,
        if (is_operator) @intFromEnum(Protocol.PermissionLevel.Operator) else @intFromEnum(Protocol.PermissionLevel.Member),
        if (is_operator) 1 else 0,
        layers,
    );
}
