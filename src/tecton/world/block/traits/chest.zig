const std = @import("std");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;
const Block = @import("../block.zig").Block;
const Chunk = @import("../../chunk/chunk.zig").Chunk;
const Dimension = @import("../../dimension/dimension.zig").Dimension;
const broadcast = @import("../../dimension/broadcast.zig");
const ChunkEntityIndex = @import("../../dimension/entity_index.zig").ChunkEntityIndex;
const CachedPacket = @import("../../dimension/dimension.zig").CachedPacket;
const chunkHash = @import("../../dimension/dimension.zig").chunkHash;
const BlockPermutation = @import("../block_permutation.zig").BlockPermutation;
const BlockState = @import("../block_permutation.zig").BlockState;
const BlockType = @import("../block_type.zig").BlockType;
const Player = @import("../../../player/player.zig").Player;
const Entity = @import("../../../entity/entity.zig").Entity;
const BlockContainer = @import("../../../container/block_container.zig").BlockContainer;
const CompoundTag = @import("nbt").CompoundTag;
const NBT = @import("nbt");
const trait_mod = @import("./trait.zig");
const serialization = @import("../../provider/serialization.zig");
const ItemStack = @import("../../../items/item_stack.zig").ItemStack;
const ItemType = @import("../../../items/item_type.zig").ItemType;
const Logger = @import("Raknet").Logger;

pub const State = struct {
    container: ?BlockContainer = null,
    pair_position: ?Protocol.BlockPosition = null,
    is_parent: bool = false,
};

fn resolvedPairPosition(state: *State, block: *Block) ?Protocol.BlockPosition {
    const pair = state.pair_position orelse return null;
    return .{
        .x = pair.x,
        .y = block.position.y,
        .z = pair.z,
    };
}

pub fn getResolvedPairPosition(block: *Block) ?Protocol.BlockPosition {
    const state = block.getTraitState(ChestTrait) orelse return null;
    return resolvedPairPosition(state, block);
}

pub fn restoreAdjacentPairing(block: *Block) void {
    const state = block.getTraitState(ChestTrait) orelse return;
    const perm = block.getPermutation(0) catch return;
    const direction = perm.state.get("minecraft:cardinal_direction") orelse return;

    const offsets: [2][2]i32 = switch (direction) {
        .string => |dir| blk: {
            if (std.mem.eql(u8, dir, "north") or std.mem.eql(u8, dir, "south")) {
                break :blk .{ .{ -1, 0 }, .{ 1, 0 } };
            } else {
                break :blk .{ .{ 0, -1 }, .{ 0, 1 } };
            }
        },
        else => return,
    };

    for (offsets) |off| {
        const adj_pos = Protocol.BlockPosition{
            .x = block.position.x + off[0],
            .y = block.position.y,
            .z = block.position.z + off[1],
        };
        const adj_block = block.dimension.getBlockPtr(adj_pos) orelse continue;
        if (!std.mem.eql(u8, adj_block.getIdentifier(), block.getIdentifier())) continue;
        const adj_state = adj_block.getTraitState(ChestTrait) orelse continue;
        const adj_pair = resolvedPairPosition(adj_state, adj_block) orelse continue;

        if (adj_pair.x == block.position.x and adj_pair.y == block.position.y and adj_pair.z == block.position.z) {
            state.pair_position = adj_block.position;
            state.is_parent = !adj_state.is_parent;

            if (adj_state.is_parent) {
                if (adj_state.container) |*container| {
                    if (container.base.getSize() != 54) {
                        container.base.setSize(54) catch return;
                    }
                }
            } else if (state.container) |*container| {
                if (container.base.getSize() != 54) {
                    container.base.setSize(54) catch return;
                }
            }
            return;
        }
    }

    state.pair_position = null;
    state.is_parent = false;
    if (state.container) |*container| {
        if (container.base.getSize() != 27) {
            container.base.setSize(27) catch return;
        }
    }
    tryPairAdjacent(state, block);
}

fn onAttach(state: *State, block: *Block) void {
    if (state.container == null) {
        state.container = BlockContainer.init(block.allocator, .Container, 27) catch return;
    }
    tryPairAdjacent(state, block);
}

fn onDetach(state: *State, _: *Block) void {
    if (state.container) |*c| c.deinit();
    state.container = null;
}

fn onSerialize(state: *State, tag: *CompoundTag) void {
    const container = &(state.container orelse return);
    const list = serialization.serializeContainer(tag.allocator, &container.base) catch return;
    tag.set("Items", .{ .List = list }) catch {};
    if (state.pair_position) |pair| {
        tag.set("pairx", .{ .Int = @import("nbt").IntTag.init(pair.x, null) }) catch {};
        tag.set("pairz", .{ .Int = @import("nbt").IntTag.init(pair.z, null) }) catch {};
        tag.set("pairlead", .{ .Int = @import("nbt").IntTag.init(if (state.is_parent) 1 else 0, null) }) catch {};
    }
}

fn onDeserialize(state: *State, tag: *const CompoundTag) void {
    const container = &(state.container orelse return);
    if (tag.get("pairx")) |pair_x_tag| {
        if (tag.get("pairz")) |pair_z_tag| {
            const pair_x = switch (pair_x_tag) {
                .Int => |t| t.value,
                else => null,
            };
            const pair_z = switch (pair_z_tag) {
                .Int => |t| t.value,
                else => null,
            };
            if (pair_x != null and pair_z != null) {
                state.pair_position = .{
                    .x = pair_x.?,
                    .y = 0,
                    .z = pair_z.?,
                };
            }
        }
    }
    if (tag.get("pairlead")) |pair_lead_tag| {
        const is_parent = switch (pair_lead_tag) {
            .Int => |t| t.value != 0,
            .Byte => |t| t.value != 0,
            else => null,
        };
        if (is_parent != null) {
            state.is_parent = is_parent.?;
            const expected_size: u32 = if (state.is_parent) 54 else 27;
            if (container.base.getSize() != expected_size) {
                container.base.setSize(expected_size) catch return;
            }
        }
    }
    if (tag.get("Items")) |items_tag| {
        switch (items_tag) {
            .List => |list| {
                serialization.deserializeContainer(container.base.allocator, &container.base, &list);
            },
            else => {},
        }
    }
}

fn ensurePairLink(state: *State, block: *Block) void {
    const pair_pos = resolvedPairPosition(state, block) orelse {
        tryPairAdjacent(state, block);
        return;
    };

    const paired_block = block.dimension.getBlockPtr(pair_pos) orelse return;
    const paired_state = paired_block.getTraitState(ChestTrait) orelse return;

    if (state.is_parent) {
        if (state.container) |*parent_container| {
            if (parent_container.base.getSize() != 54) {
                parent_container.base.setSize(54) catch return;
            }
            if (paired_state.container) |*child_container| {
                var slot: u32 = 0;
                while (slot < 27) : (slot += 1) {
                    if (child_container.base.storage[slot]) |item| {
                        parent_container.base.storage[slot + 27] = item;
                        child_container.base.storage[slot] = null;
                    }
                }
            }
        }
        paired_state.pair_position = block.position;
        paired_state.is_parent = false;
    } else {
        if (paired_state.container) |*parent_container| {
            if (parent_container.base.getSize() != 54) {
                parent_container.base.setSize(54) catch return;
            }
            if (state.container) |*child_container| {
                var slot: u32 = 0;
                while (slot < 27) : (slot += 1) {
                    if (child_container.base.storage[slot]) |item| {
                        parent_container.base.storage[slot + 27] = item;
                        child_container.base.storage[slot] = null;
                    }
                }
            }
        }
        paired_state.pair_position = block.position;
        paired_state.is_parent = true;
    }
}

fn sendActorData(block: *Block, player: *Player) void {
    const id = if (std.mem.eql(u8, block.getIdentifier(), "minecraft:trapped_chest")) "TrappedChest" else "Chest";
    var tag = @import("nbt").CompoundTag.init(block.allocator, null);
    defer tag.deinit(block.allocator);
    const id_str = block.allocator.dupe(u8, id) catch return;
    tag.set("id", .{ .String = NBT.StringTag.init(id_str, null) }) catch return;
    tag.set("x", .{ .Int = NBT.IntTag.init(block.position.x, null) }) catch return;
    tag.set("y", .{ .Int = NBT.IntTag.init(block.position.y, null) }) catch return;
    tag.set("z", .{ .Int = NBT.IntTag.init(block.position.z, null) }) catch return;
    block.fireEvent(.Serialize, .{&tag});
    var s = BinaryStream.init(block.allocator, null, null);
    defer s.deinit();
    const pkt = Protocol.BlockActorDataPacket{ .position = block.position, .nbt = tag };
    const serialized = pkt.serialize(&s, block.allocator) catch return;
    player.network.sendPacket(player.connection, serialized) catch {};

    sendClientRefresh(block, player);
}

fn tileFixNetworkIds(block: *Block, position: Protocol.BlockPosition) ?[2]u32 {
    const target_block = block.dimension.getBlockPtr(position) orelse return null;
    const perm = target_block.getPermutation(0) catch return null;
    return .{ 0, @bitCast(perm.network_id) };
}

fn sendClientRefreshAt(block: *Block, position: Protocol.BlockPosition, player: *Player) void {
    const block_ids = tileFixNetworkIds(block, position) orelse return;

    {
        var s2 = BinaryStream.init(block.allocator, null, null);
        defer s2.deinit();
        const fix_air = Protocol.UpdateBlockPacket{ .position = position, .network_block_id = block_ids[0] };
        const air_ser = fix_air.serialize(&s2) catch return;
        player.network.sendPacket(player.connection, air_ser) catch {};
    }
    {
        var s3 = BinaryStream.init(block.allocator, null, null);
        defer s3.deinit();
        const fix_real = Protocol.UpdateBlockPacket{ .position = position, .network_block_id = block_ids[1] };
        const real_ser = fix_real.serialize(&s3) catch return;
        player.network.sendPacket(player.connection, real_ser) catch {};
    }
}

pub fn sendClientRefresh(block: *Block, player: *Player) void {
    sendClientRefreshAt(block, block.position, player);
}

fn onInteract(state: *State, block: *Block, player: *Player) bool {
    ensurePairLink(state, block);

    if (state.pair_position != null and !state.is_parent) {
        const parent_pos = resolvedPairPosition(state, block) orelse return true;
        const parent_block = block.dimension.getBlockPtr(parent_pos) orelse return true;
        const parent_state = parent_block.getTraitState(ChestTrait) orelse return true;
        return onInteract(parent_state, parent_block, player);
    }

    const container = &(state.container orelse return true);
    sendActorData(block, player);
    _ = container.show(player, block.position);
    sendBlockEvent(block, 1);
    sendSound(block, .chest_open);
    if (resolvedPairPosition(state, block)) |pair_pos| {
        sendBlockEventAt(block, pair_pos, 1);
    }
    return false;
}

fn onBreak(state: *State, block: *Block, _: ?*Player) bool {
    if (resolvedPairPosition(state, block)) |pair_pos| {
        if (state.is_parent) {
            if (state.container) |*container| {
                var iter = container.base.occupants.iterator();
                while (iter.next()) |entry| {
                    container.base.close(entry.key_ptr.*, true);
                }
            }
            if (block.dimension.getBlockPtr(pair_pos)) |paired_block| {
                if (paired_block.getTraitState(ChestTrait)) |paired_state| {
                    if (state.container) |*parent_container| {
                        if (paired_state.container) |*child_container| {
                            var slot: u32 = 27;
                            while (slot < parent_container.base.getSize()) : (slot += 1) {
                                if (parent_container.base.storage[slot]) |item| {
                                    const target = slot - 27;
                                    child_container.base.storage[target] = item;
                                    parent_container.base.storage[slot] = null;
                                }
                            }
                        }
                        parent_container.base.setSize(27) catch {};
                    }
                    paired_state.pair_position = null;
                    paired_state.is_parent = false;
                }
            }
        } else {
            if (block.dimension.getBlockPtr(pair_pos)) |paired_block| {
                if (paired_block.getTraitState(ChestTrait)) |paired_state| {
                    if (paired_state.container) |*parent_container| {
                        var iter = parent_container.base.occupants.iterator();
                        while (iter.next()) |entry| {
                            parent_container.base.close(entry.key_ptr.*, true);
                        }
                        if (state.container) |*child_container| {
                            var slot: u32 = 27;
                            while (slot < parent_container.base.getSize()) : (slot += 1) {
                                if (parent_container.base.storage[slot]) |item| {
                                    const target = slot - 27;
                                    child_container.base.storage[target] = item;
                                    parent_container.base.storage[slot] = null;
                                }
                            }
                        }
                        parent_container.base.setSize(27) catch {};
                    }
                    paired_state.pair_position = null;
                    paired_state.is_parent = false;
                }
            }
        }
    } else {
        if (state.container) |*container| {
            var iter = container.base.occupants.iterator();
            while (iter.next()) |entry| {
                container.base.close(entry.key_ptr.*, true);
            }
        }
    }
    sendBlockEvent(block, 0);
    sendSound(block, .chest_closed);
    return true;
}

fn tryPairAdjacent(state: *State, block: *Block) void {
    const perm = block.getPermutation(0) catch return;
    const direction = perm.state.get("minecraft:cardinal_direction") orelse return;

    const offsets: [2][2]i32 = switch (direction) {
        .string => |dir| blk: {
            if (std.mem.eql(u8, dir, "north") or std.mem.eql(u8, dir, "south")) {
                break :blk .{ .{ -1, 0 }, .{ 1, 0 } };
            } else {
                break :blk .{ .{ 0, -1 }, .{ 0, 1 } };
            }
        },
        else => {
            Logger.ERROR(
                "ChestTrait expected minecraft:cardinal_direction to be string, got '{s}' at ({d},{d},{d}) for {s}",
                .{ @tagName(direction), block.position.x, block.position.y, block.position.z, block.getIdentifier() },
            );
            return;
        },
    };

    for (offsets) |off| {
        const adj_pos = Protocol.BlockPosition{
            .x = block.position.x + off[0],
            .y = block.position.y,
            .z = block.position.z + off[1],
        };
        const adj_block = block.dimension.getBlockPtr(adj_pos) orelse continue;
        const adj_state = adj_block.getTraitState(ChestTrait) orelse continue;
        if (adj_state.pair_position != null) continue;

        if (!std.mem.eql(u8, adj_block.getIdentifier(), block.getIdentifier())) continue;

        const adj_perm = adj_block.getPermutation(0) catch continue;
        const adj_dir = adj_perm.state.get("minecraft:cardinal_direction") orelse continue;
        if (adj_dir != .string) {
            Logger.ERROR(
                "ChestTrait adjacent minecraft:cardinal_direction was '{s}' at ({d},{d},{d}) for {s}",
                .{ @tagName(adj_dir), adj_pos.x, adj_pos.y, adj_pos.z, adj_block.getIdentifier() },
            );
            continue;
        }
        if (!direction.eql(adj_dir)) break;

        state.pair_position = adj_pos;
        state.is_parent = true;
        adj_state.pair_position = block.position;
        adj_state.is_parent = false;

        if (state.container) |*container| {
            container.base.setSize(54) catch return;
            if (adj_state.container) |*adj_container| {
                var slot: u32 = 0;
                while (slot < 27) : (slot += 1) {
                    if (adj_container.base.storage[slot]) |item| {
                        container.base.storage[slot + 27] = item;
                        adj_container.base.storage[slot] = null;
                    }
                }
            }
        }
        return;
    }
}

fn sendBlockEvent(block: *Block, data: i32) void {
    sendBlockEventAt(block, block.position, data);
}

fn sendBlockEventAt(block: *Block, position: Protocol.BlockPosition, data: i32) void {
    var stream = BinaryStream.init(block.allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.BlockEventPacket{
        .position = position,
        .event_type = .ChangeState,
        .data = data,
    };
    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastBlockUpdateToViewers(block.dimension, position, serialized);
}

fn sendSound(block: *Block, event: Protocol.SoundEvent) void {
    const perm = block.getPermutation(0) catch return;
    const network_id: i32 = perm.network_id;
    const position = Protocol.Vector3f.init(
        @floatFromInt(block.position.x),
        @floatFromInt(block.position.y),
        @floatFromInt(block.position.z),
    );

    var stream = BinaryStream.init(block.allocator, null, null);
    defer stream.deinit();
    const packet = Protocol.LevelSoundEventPacket{
        .event = event,
        .position = position,
        .data = network_id,
        .actor_identifier = "",
        .is_baby_mob = false,
        .is_global = false,
    };
    const serialized = packet.serialize(&stream) catch return;
    broadcast.broadcastToNearby(block.dimension, position, broadcast.SOUND_BROADCAST_RADIUS, serialized);
}

pub const ChestTrait = trait_mod.BlockTrait(State, .{
    .identifier = "chest",
    .blocks = &.{
        "minecraft:chest",
        "minecraft:trapped_chest",
    },
    .on_attach = &onAttach,
    .on_detach = &onDetach,
    .on_interact = &onInteract,
    .on_break = &onBreak,
    .on_serialize = &onSerialize,
    .on_deserialize = &onDeserialize,
});

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const Block = test_owner.Block;
    pub const Chunk = test_owner.Chunk;
    pub const Dimension = test_owner.Dimension;
    pub const ChunkEntityIndex = test_owner.ChunkEntityIndex;
    pub const CachedPacket = test_owner.CachedPacket;
    pub const chunkHash = test_owner.chunkHash;
    pub const BlockPermutation = test_owner.BlockPermutation;
    pub const BlockState = test_owner.BlockState;
    pub const BlockType = test_owner.BlockType;
    pub const Entity = test_owner.Entity;
    pub const CompoundTag = test_owner.CompoundTag;
    pub const NBT = test_owner.NBT;
    pub const trait_mod = test_owner.trait_mod;
    pub const serialization = test_owner.serialization;
    pub const ItemStack = test_owner.ItemStack;
    pub const ItemType = test_owner.ItemType;
    pub const restoreAdjacentPairing = test_owner.restoreAdjacentPairing;
    pub const tileFixNetworkIds = test_owner.tileFixNetworkIds;
    pub const ChestTrait = test_owner.ChestTrait;
};

test "double chest preserves upper-half items when halves load in reverse order" {
    try @import("chest_test.zig").Suite(test_scope).case_000();
}

test "tile fix uses air then real block" {
    try @import("chest_test.zig").Suite(test_scope).case_001();
}

test "double chest serialization writes pairlead as int tag" {
    try @import("chest_test.zig").Suite(test_scope).case_002();
}

test "double chest preserves upper-half items across repeated unload cycles" {
    try @import("chest_test.zig").Suite(test_scope).case_003();
}
