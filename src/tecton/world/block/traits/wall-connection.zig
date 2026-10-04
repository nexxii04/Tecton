const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const CompoundTag = @import("nbt").CompoundTag;
const Protocol = @import("protocol");

const Player = @import("../../../player/player.zig").Player;
const BlockState = @import("../block-permutation.zig").BlockState;
const Permutation = @import("../block-permutation.zig").BlockPermutation;
const BlockType = @import("../block-type.zig").BlockType;
const Block = @import("../block.zig").Block;
const trait_mod = @import("./trait.zig");
const broadcast = @import("../../dimension/broadcast.zig");
const applyTraitsForBlock = trait_mod.applyTraitsForBlock;

pub const WallConnection = enum {
    none,
    short,
    tall,
};

pub const State = struct {
    east: WallConnection = .none,
    north: WallConnection = .none,
    south: WallConnection = .none,
    west: WallConnection = .none,
    post_bit: bool = true,

    const connection_keys = [_][]const u8{
        "wall_connection_type_north",
        "wall_connection_type_east",
        "wall_connection_type_south",
        "wall_connection_type_west",
    };

    pub fn writeBlockState(self: *State, state: *BlockState) !void {
        try state.put("wall_connection_type_north", .{ .string = @tagName(self.north) });
        try state.put("wall_connection_type_east", .{ .string = @tagName(self.east) });
        try state.put("wall_connection_type_south", .{ .string = @tagName(self.south) });
        try state.put("wall_connection_type_west", .{ .string = @tagName(self.west) });
        try state.put("wall_post_bit", .{ .boolean = self.post_bit });
    }

    pub fn calculatePostBit(self: *State, block: *Block) void {
        const n = self.north != .none;
        const s = self.south != .none;
        const e = self.east != .none;
        const w = self.west != .none;

        const block_above = block.dimension.getBlockPtr(block.position.relative(.Up));
        const solid_above = if (block_above) |up| !up.isAir() else false;

        const horizontal_straight = (e and w and !n and !s);
        const vertical_straight = (n and s and !e and !w);

        self.post_bit = solid_above or !(horizontal_straight or vertical_straight);
    }
};

fn onSerialize(state: *State, tag: *CompoundTag) void {
    const values = [_]WallConnection{ state.north, state.east, state.south, state.west };
    for (State.connection_keys, values) |key, val| {
        const name = @tagName(val);
        const dupe = tag.allocator.dupe(u8, name) catch continue;
        tag.set(key, .{ .String = .init(dupe, null) }) catch {};
    }

    tag.set("wall_post_bit", .{ .Byte = .init(@intFromBool(state.post_bit), null) }) catch {};
}

fn onDeserialize(state: *State, tag: *const CompoundTag) void {
    const fields = [_]*WallConnection{ &state.north, &state.east, &state.south, &state.west };
    for (State.connection_keys, fields) |key, field| {
        if (tag.get(key)) |val| if (val == .String) {
            field.* = std.meta.stringToEnum(WallConnection, val.String.value) orelse .none;
        };
    }

    if (tag.get("wall_post_bit")) |val| if (val == .Byte) {
        state.post_bit = val.Byte.value != 0;
    };
}

fn onAttach(state: *State, block: *Block) void {
    for (Protocol.Face.horizontal) |face| {
        const pos = block.position.relative(face);
        const adj_block = block.dimension.getBlockPtr(pos) orelse continue;

        if (!adj_block.hasTrait("wall_connection")) {
            applyTraitsForBlock(block.allocator, block.dimension, pos) catch {};
        }

        const adj_state = adj_block.getTraitState(WallConnectionTrait) orelse continue;

        switch (face) {
            .North => {
                state.north = .short;
                adj_state.south = .short;
            },
            .South => {
                state.south = .short;
                adj_state.north = .short;
            },
            .East => {
                state.east = .short;
                adj_state.west = .short;
            },
            .West => {
                state.west = .short;
                adj_state.east = .short;
            },
            else => unreachable,
        }

        adj_state.calculatePostBit(adj_block);
        updateWallBlock(adj_block, true);
    }
    state.calculatePostBit(block);
    updateWallBlock(block, true);
}

fn onDetach(_: *State, block: *Block) void {
    for (Protocol.Face.horizontal) |face| {
        const pos = block.position.relative(face);
        const adj_block = block.dimension.getBlockPtr(pos) orelse continue;
        const adj_state = adj_block.getTraitState(WallConnectionTrait) orelse continue;

        switch (face) {
            .North => adj_state.south = .none,
            .South => adj_state.north = .none,
            .East => adj_state.west = .none,
            .West => adj_state.east = .none,
            else => unreachable,
        }

        adj_state.calculatePostBit(adj_block);
        updateWallBlock(adj_block, true);
    }
}

fn updateWallBlock(block: *Block, send_blocks: bool) void {
    const state = block.getTraitState(WallConnectionTrait) orelse return;
    const perm = block.getPermutation(0) catch return;

    var block_state = BlockState.init(block.allocator);
    defer block_state.deinit();

    var iter = perm.state.iterator();
    while (iter.next()) |entry| {
        block_state.put(entry.key_ptr.*, entry.value_ptr.*) catch return;
    }

    state.writeBlockState(&block_state) catch return;

    const block_type = BlockType.get(perm.identifier) orelse return;
    const new_perm = block_type.getPermutation(block_state);

    block.setPermutation(new_perm, 0) catch return;

    if (send_blocks) sendBlockUpdate(block, new_perm);
}

fn sendBlockUpdate(block: *Block, perm: *Permutation) void {
    const network_id: u32 = @bitCast(perm.network_id);

    var s = BinaryStream.init(block.allocator, null, null);
    defer s.deinit();

    const packet = Protocol.UpdateBlockPacket{
        .position = block.position,
        .network_block_id = network_id,
    };
    const serialized = packet.serialize(&s) catch return;

    broadcast.broadcastBlockUpdateToViewers(block.dimension, block.position, serialized);
}

pub const WallConnectionTrait = trait_mod.BlockTrait(State, .{
    .identifier = "wall_connection",
    .on_serialize = &onSerialize,
    .on_deserialize = &onDeserialize,
    .on_attach = &onAttach,
    .on_detach = &onDetach,
    .on_place = &struct {
        fn onPlace(_: *State, _: *Block, _: *Player) bool {
            return false;
        }
    }.onPlace,
    .blocks = &.{
        "minecraft:cobblestone_wall",
        "minecraft:mossy_cobblestone_wall",
        "minecraft:granite_wall",
        "minecraft:diorite_wall",
        "minecraft:andesite_wall",
        "minecraft:sandstone_wall",
        "minecraft:red_sandstone_wall",
        "minecraft:brick_wall",
        "minecraft:stone_brick_wall",
        "minecraft:mossy_stone_brick_wall",
        "minecraft:nether_brick_wall",
        "minecraft:red_nether_brick_wall",
        "minecraft:end_stone_brick_wall",
        "minecraft:prismarine_wall",
        "minecraft:deepslate_brick_wall",
        "minecraft:deepslate_tile_wall",
        "minecraft:polished_deepslate_wall",
        "minecraft:cobbled_deepslate_wall",
        "minecraft:blackstone_wall",
        "minecraft:polished_blackstone_wall",
        "minecraft:polished_blackstone_brick_wall",
    },
});
