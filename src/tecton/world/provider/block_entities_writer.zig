const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ReadWriteOptions = NBT.ReadWriteOptions;

const key_mod = @import("./leveldb_keys.zig");
const persistence = @import("./persistence.zig");

// The provider is generic so this file stays outside the provider cycle.
pub fn writeBlockEntities(provider: anytype, chunk: anytype, dimension: anytype) !void {
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
