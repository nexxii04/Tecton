const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const LevelDB = @import("leveldb");
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ReadWriteOptions = NBT.ReadWriteOptions;
const Protocol = @import("protocol");

const BlockPermutation = @import("../block/block-permutation.zig").BlockPermutation;
const Block = @import("../block/block.zig").Block;
const ChestTrait = @import("../block/traits/chest.zig");
const trait_mod = @import("../block/traits/trait.zig");
const Chunk = @import("../chunk/chunk.zig").Chunk;
const chunk_mod = @import("../chunk/chunk.zig");
const Dimension = @import("../dimension/dimension.zig").Dimension;
const key_mod = @import("./leveldb-keys.zig");
const persistence = @import("./persistence.zig");
const LevelDBProvider = @import("./leveldb-provider.zig").LevelDBProvider;

pub fn writeBlockEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    const dim_index = key_mod.dimensionIndex(dimension);
    const key = key_mod.blockEntityKey(chunk.x, chunk.z, dim_index);

    const chunk_blocks = dimension.getBlocksInChunk(chunk.x, chunk.z);

    var tags = std.ArrayList(NBT.Tag){ .items = &.{}, .capacity = 0 };
    defer {
        for (tags.items) |*t| {
            switch (t.*) {
                .Compound => |*c| c.deinit(provider.allocator),
                else => {},
            }
        }
        tags.deinit(provider.allocator);
    }

    for (chunk_blocks) |block| {
        if (block.traits.items.len == 0) continue;

        var has_serialize = false;
        for (block.traits.items) |inst| {
            if (inst.vtable.on_serialize != null) {
                has_serialize = true;
                break;
            }
        }
        if (!has_serialize) continue;

        var tag = CompoundTag.init(provider.allocator, null);
        tag.set("x", .{ .Int = NBT.IntTag.init(block.position.x, null) }) catch {
            tag.deinit(provider.allocator);
            continue;
        };
        tag.set("y", .{ .Int = NBT.IntTag.init(block.position.y, null) }) catch {
            tag.deinit(provider.allocator);
            continue;
        };
        tag.set("z", .{ .Int = NBT.IntTag.init(block.position.z, null) }) catch {
            tag.deinit(provider.allocator);
            continue;
        };
        const id_str = provider.allocator.dupe(u8, block.getIdentifier()) catch {
            tag.deinit(provider.allocator);
            continue;
        };
        tag.set("id", .{ .String = NBT.StringTag.init(id_str, null) }) catch {
            tag.deinit(provider.allocator);
            continue;
        };

        var trait_tags = std.ArrayList(NBT.Tag){ .items = &.{}, .capacity = 0 };
        defer trait_tags.deinit(provider.allocator);
        for (block.traits.items) |instance| {
            const duped = provider.allocator.dupe(u8, instance.identifier) catch continue;
            trait_tags.append(provider.allocator, .{ .String = NBT.StringTag.init(duped, null) }) catch continue;
        }
        const trait_slice = trait_tags.toOwnedSlice(provider.allocator) catch provider.allocator.alloc(NBT.Tag, 0) catch &.{};
        tag.set("traits", .{ .List = NBT.ListTag.init(@constCast(trait_slice), null) }) catch {};

        block.fireEvent(.Serialize, .{&tag});

        tags.append(provider.allocator, .{ .Compound = tag }) catch {
            tag.deinit(provider.allocator);
            continue;
        };
    }

    var record = persistence.Record{};
    errdefer record.deinit(provider.allocator);

    if (tags.items.len == 0) {
        try record.addDelete(provider.allocator, key.slice());
        provider.dispatch(.block_entities, dim_index, chunk.x, chunk.z, record);
        return;
    }

    var stream = BinaryStream.init(provider.allocator, null, null);
    defer stream.deinit();
    for (tags.items) |*t| {
        switch (t.*) {
            .Compound => |*c| {
                CompoundTag.write(&stream, c, ReadWriteOptions.default) catch |err| {
                    std.log.err("Failed to write block entity NBT: {}", .{err});
                    continue;
                };
            },
            else => {},
        }
    }
    try record.addPut(provider.allocator, key.slice(), stream.getBuffer());
    provider.dispatch(.block_entities, dim_index, chunk.x, chunk.z, record);
}

pub fn readBlockEntities(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) !void {
    provider.awaitChunkRecords(chunk.x, chunk.z, dimension.dimension_type, &.{.block_entities});
    const dim_index = key_mod.dimensionIndex(dimension);
    const key = key_mod.blockEntityKey(chunk.x, chunk.z, dim_index);
    const data = provider.db.get(key.slice()) orelse {
        scanChunkForTraitBlocks(provider, chunk, dimension);
        return;
    };
    defer LevelDB.DB.freeValue(data);

    const PendingEntity = struct {
        pos: Protocol.BlockPosition,
        tag_data: []const u8,
    };
    var pending = std.ArrayList(PendingEntity){ .items = &.{}, .capacity = 0 };
    defer {
        for (pending.items) |p| provider.allocator.free(p.tag_data);
        pending.deinit(provider.allocator);
    }

    var stream = BinaryStream.init(provider.allocator, data, null);
    while (stream.offset < data.len) {
        var tag = CompoundTag.read(&stream, provider.allocator, ReadWriteOptions.default) catch break;

        const x = switch (tag.get("x") orelse {
            tag.deinit(provider.allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(provider.allocator);
                continue;
            },
        };
        const y = switch (tag.get("y") orelse {
            tag.deinit(provider.allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(provider.allocator);
                continue;
            },
        };
        const z = switch (tag.get("z") orelse {
            tag.deinit(provider.allocator);
            continue;
        }) {
            .Int => |t| t.value,
            else => {
                tag.deinit(provider.allocator);
                continue;
            },
        };

        const pos = Protocol.BlockPosition{ .x = x, .y = y, .z = z };
        if (dimension.getBlockPtr(pos) != null) {
            tag.deinit(provider.allocator);
            continue;
        }

        const block = provider.allocator.create(Block) catch {
            tag.deinit(provider.allocator);
            continue;
        };
        block.* = Block.init(provider.allocator, dimension, pos);

        const traits_tag = tag.get("traits") orelse tag.get("Traits");
        var added_traits = false;
        if (traits_tag) |tt| {
            switch (tt) {
                .List => |list| {
                    for (list.value) |item| {
                        switch (item) {
                            .String => |s| {
                                if (trait_mod.getTraitFactory(s.value)) |f| {
                                    const instance = f(provider.allocator) catch continue;
                                    block.addTrait(instance) catch continue;
                                    added_traits = true;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        if (!added_traits) {
            const id_tag = tag.get("id");
            if (id_tag) |idt| {
                switch (idt) {
                    .String => |s| {
                        const inferred: ?[]const u8 = if (std.mem.eql(u8, s.value, "Chest")) "chest" else if (std.mem.eql(u8, s.value, "TrappedChest")) "chest" else if (std.mem.eql(u8, s.value, "Barrel")) "barrel" else null;
                        if (inferred) |trait_id| {
                            if (trait_mod.getTraitFactory(trait_id)) |f| {
                                if (f(provider.allocator)) |instance| {
                                    block.addTrait(instance) catch {};
                                } else |_| {}
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        if (block.traits.items.len == 0) {
            block.deinit();
            provider.allocator.destroy(block);
            tag.deinit(provider.allocator);
            continue;
        }

        var nbt_stream = BinaryStream.init(provider.allocator, null, null);
        CompoundTag.write(&nbt_stream, &tag, ReadWriteOptions.default) catch {
            nbt_stream.deinit();
            block.deinit();
            provider.allocator.destroy(block);
            tag.deinit(provider.allocator);
            continue;
        };
        const tag_data = provider.allocator.dupe(u8, nbt_stream.getBuffer()) catch {
            nbt_stream.deinit();
            block.deinit();
            provider.allocator.destroy(block);
            tag.deinit(provider.allocator);
            continue;
        };
        nbt_stream.deinit();
        tag.deinit(provider.allocator);

        dimension.storeBlock(block) catch {
            block.deinit();
            provider.allocator.destroy(block);
            provider.allocator.free(tag_data);
            continue;
        };

        pending.append(provider.allocator, .{ .pos = pos, .tag_data = tag_data }) catch {
            provider.allocator.free(tag_data);
            continue;
        };
    }

    for (pending.items) |p| {
        const block = dimension.getBlockPtr(p.pos) orelse continue;
        if (block.hasTrait(ChestTrait.ChestTrait.identifier)) {
            ChestTrait.restoreAdjacentPairing(block);
        }
    }

    for (pending.items) |p| {
        const block = dimension.getBlockPtr(p.pos) orelse continue;
        var deser_stream = BinaryStream.init(provider.allocator, p.tag_data, null);
        var deser_tag = CompoundTag.read(&deser_stream, provider.allocator, ReadWriteOptions.default) catch continue;
        defer deser_tag.deinit(provider.allocator);
        block.fireEvent(.Deserialize, .{&deser_tag});
    }

    scanChunkForTraitBlocks(provider, chunk, dimension);
}

fn scanChunkForTraitBlocks(provider: *LevelDBProvider, chunk: *Chunk, dimension: *Dimension) void {
    if (!trait_mod.hasAnyStaticTraits()) return;

    const offset = chunk_mod.yOffset(dimension.dimension_type);
    for (0..chunk_mod.MAX_SUBCHUNKS) |i| {
        const sc = chunk.subchunks[i] orelse continue;
        if (sc.layers.items.len == 0) continue;
        const layer = &sc.layers.items[0];

        var trait_palette = std.AutoHashMap(u32, bool).init(provider.allocator);
        defer trait_palette.deinit();

        for (layer.paletteSlice(), 0..) |network_id, pi| {
            const perm = BlockPermutation.getByNetworkId(network_id) orelse continue;
            if (std.mem.eql(u8, perm.identifier, "minecraft:air")) continue;
            if (trait_mod.hasRegisteredTraits(perm.identifier)) {
                trait_palette.put(@intCast(pi), true) catch continue;
            }
        }

        if (trait_palette.count() == 0) continue;

        const sc_y: i32 = @as(i32, @intCast(i)) - @as(i32, @intCast(offset));
        for (0..4096) |pos_idx| {
            const palette_idx = layer.blocks[pos_idx];
            if (!trait_palette.contains(palette_idx)) continue;

            const bx: i32 = @intCast((pos_idx >> 8) & 0xf);
            const by: i32 = @intCast(pos_idx & 0xf);
            const bz: i32 = @intCast((pos_idx >> 4) & 0xf);

            const world_x = chunk.x * 16 + bx;
            const world_y = sc_y * 16 + by;
            const world_z = chunk.z * 16 + bz;

            const pos = Protocol.BlockPosition{ .x = world_x, .y = world_y, .z = world_z };
            if (dimension.getBlockPtr(pos) != null) continue;

            trait_mod.applyTraitsForBlock(provider.allocator, dimension, pos) catch continue;
        }
    }
}
