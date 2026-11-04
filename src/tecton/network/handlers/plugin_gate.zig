const Protocol = @import("protocol");

const Events = @import("../../events/types.zig");
const Tecton = @import("../../tecton.zig").Tecton;
const Player = @import("../../player/player.zig").Player;
const BlockPermutation = @import("../../world/block/block_permutation.zig").BlockPermutation;

pub fn itemUseDenied(tecton: *Tecton, player: *Player, identifier: []const u8) bool {
    var event = Events.ItemUseEvent{ .player = player, .identifier = identifier };
    return !tecton.events.emit(.ItemUse, &event);
}

pub fn blockPlaceDenied(tecton: *Tecton, player: *Player, position: Protocol.BlockPosition, permutation: *BlockPermutation) bool {
    var event = Events.BlockPlaceEvent{ .player = player, .position = position, .permutation = permutation };
    return !tecton.events.emit(.BlockPlace, &event);
}
