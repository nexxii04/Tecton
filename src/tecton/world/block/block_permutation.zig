const model = @import("model/model.zig");
pub const BlockPermutation = model.BlockPermutation;
pub const BlockState = model.BlockState;
pub const BlockStateValue = model.BlockStateValue;

test "resolution preserves shared registries, defaults, partial states and air fallback" {
    try @import("model/resolve_test.zig").Suite(model).resolution();
}

test "permutation hashing sorts states and matches serialized NBT bytes" {
    try @import("model/resolve_test.zig").Suite(model).hashAndNbt();
}

test "block compatibility aliases have a single model and registry identity" {
    const std = @import("std");
    try std.testing.expect(BlockPermutation == model.BlockPermutation);
    try std.testing.expect(@import("block_type.zig").BlockType == model.BlockType);
    try std.testing.expect(BlockState == @import("model/state.zig").BlockState);
    try std.testing.expect(BlockStateValue == @import("model/state.zig").BlockStateValue);
}

test "hash lookup returns correct network_id for all permutations" {
    try @import("model/model_test.zig").Suite(model).hashLookup();
}
