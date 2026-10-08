const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Block = @import("../block.zig").Block;
const BlockPermutation = @import("../block_permutation.zig").BlockPermutation;
const Player = @import("../../../player/player.zig").Player;
const trait_mod = @import("./trait.zig");
const broadcast = @import("../../dimension/broadcast.zig");

pub const State = struct {};

fn onBreak(_: *State, block: *Block, _: ?*Player) bool {
    const perm = block.getPermutation(0) catch return true;
    const val = perm.state.get("upper_block_bit") orelse return true;
    if (val != .boolean) return true;

    const other_pos = if (val.boolean)
        Protocol.BlockPosition{ .x = block.position.x, .y = block.position.y - 1, .z = block.position.z }
    else
        Protocol.BlockPosition{ .x = block.position.x, .y = block.position.y + 1, .z = block.position.z };

    const air = BlockPermutation.resolve(block.allocator, "minecraft:air", null) catch return true;
    block.dimension.setPermutation(other_pos, air, 0) catch {};

    const network_id: u32 = @bitCast(air.network_id);
    var s = BinaryStream.init(block.allocator, null, null);
    defer s.deinit();
    const update = Protocol.UpdateBlockPacket{
        .position = other_pos,
        .network_block_id = network_id,
    };
    const serialized = update.serialize(&s) catch return true;
    broadcast.broadcastBlockUpdateToViewers(block.dimension, other_pos, serialized);

    return true;
}

pub const UpperBlockTrait = trait_mod.BlockTrait(State, .{
    .identifier = "upper_block",
    .on_break = &onBreak,
});
