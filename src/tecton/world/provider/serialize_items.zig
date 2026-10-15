const std = @import("std");

const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ListTag = NBT.ListTag;
const Tag = NBT.Tag;
const StringTag = NBT.StringTag;
const ByteTag = NBT.ByteTag;
const ShortTag = NBT.ShortTag;
const codec = @import("nbt_codec.zig");

pub fn ItemCodec(comptime Hooks: type) type {
    return struct {
        pub fn serializeItemStack(allocator: std.mem.Allocator, item: *Hooks.Item) !CompoundTag {
            Hooks.syncEnchantments(item) catch {
                return error.EnchantmentSyncFailed;
            };

            var tag = CompoundTag.init(allocator, null);
            try tag.set("Name", .{ .String = StringTag.init(try allocator.dupe(u8, item.item_type.identifier), null) });
            try tag.set("Count", .{ .Byte = ByteTag.init(@intCast(@min(item.stack_size, 127)), null) });
            try tag.set("Damage", .{ .Short = ShortTag.init(@intCast(item.metadata), null) });
            if (item.nbt) |nbt| {
                if (nbt.get("tag")) |tag_entry| {
                    switch (tag_entry) {
                        .Compound => |c| {
                            var nbt_copy = try codec.copyCompound(allocator, &c);
                            if (nbt_copy.name) |old_name| allocator.free(old_name);
                            nbt_copy.name = try allocator.dupe(u8, "tag");
                            try tag.add(.{ .Compound = nbt_copy });
                        },
                        else => {},
                    }
                }
            }
            return tag;
        }

        pub fn deserializeItemStack(allocator: std.mem.Allocator, tag: *const CompoundTag) ?Hooks.Item {
            const name_tag = tag.get("Name") orelse return null;
            const name = switch (name_tag) {
                .String => |s| s.value,
                else => return null,
            };
            if (std.mem.eql(u8, name, "minecraft:air") or std.mem.eql(u8, name, "")) return null;

            const count: u16 = blk: {
                const count_tag = tag.get("Count") orelse break :blk 1;
                break :blk switch (count_tag) {
                    .Byte => |b| @intCast(@as(u8, @bitCast(b.value))),
                    else => 1,
                };
            };

            const metadata: u32 = blk: {
                const dmg_tag = tag.get("Damage") orelse break :blk 0;
                break :blk switch (dmg_tag) {
                    .Short => |s| @intCast(@as(u16, @bitCast(s.value))),
                    else => 0,
                };
            };

            const nbt_data: ?CompoundTag = blk: {
                const extra = tag.get("tag") orelse break :blk null;
                switch (extra) {
                    .Compound => |c| {
                        var tag_copy = codec.copyCompound(allocator, &c) catch break :blk null;
                        if (tag_copy.name) |old_name| allocator.free(old_name);
                        tag_copy.name = allocator.dupe(u8, "tag") catch {
                            tag_copy.deinit(allocator);
                            break :blk null;
                        };
                        var root = CompoundTag.init(allocator, null);
                        root.add(.{ .Compound = tag_copy }) catch {
                            tag_copy.deinit(allocator);
                            root.deinit(allocator);
                            break :blk null;
                        };
                        break :blk root;
                    },
                    else => break :blk null,
                }
            };

            const item = Hooks.load(allocator, name, count, metadata, nbt_data) orelse {
                if (nbt_data) |data| {
                    var owned = data;
                    owned.deinit(allocator);
                }
                return null;
            };
            return item;
        }

        pub fn serializeContainer(allocator: std.mem.Allocator, container: *Hooks.Container) !ListTag {
            var items = std.ArrayList(Tag){ .items = &.{}, .capacity = 0 };
            for (container.storage, 0..) |*slot, i| {
                const item = if (slot.*) |*held| held else continue;
                var item_tag = try serializeItemStack(allocator, item);
                try item_tag.set("Slot", .{ .Byte = ByteTag.init(@intCast(i), null) });
                try items.append(allocator, .{ .Compound = item_tag });
            }
            return ListTag.init(try items.toOwnedSlice(allocator), null);
        }

        pub fn deserializeContainer(allocator: std.mem.Allocator, container: *Hooks.Container, list: *const ListTag) void {
            for (list.value) |*entry| {
                switch (entry.*) {
                    .Compound => |*compound| {
                        const slot_tag = compound.get("Slot") orelse continue;
                        const slot: u32 = switch (slot_tag) {
                            .Byte => |b| @intCast(@as(u8, @bitCast(b.value))),
                            else => continue,
                        };
                        if (slot >= container.getSize()) continue;
                        if (deserializeItemStack(allocator, compound)) |item| {
                            if (container.storage[slot]) |*old| old.deinit();
                            container.storage[slot] = item;
                        }
                    },
                    else => {},
                }
            }
        }
    };
}
