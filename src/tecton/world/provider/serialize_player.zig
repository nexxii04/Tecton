const std = @import("std");

const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const IntTag = NBT.IntTag;

pub fn PlayerCodec(comptime Hooks: type) type {
    return struct {
        pub fn serializePlayer(allocator: std.mem.Allocator, player: anytype) !CompoundTag {
            var tag = try Hooks.serializeEntity(allocator, &player.entity);

            if (Hooks.inventoryState(&player.entity)) |inv_state| {
                const inv_list = try Hooks.serializeContainer(allocator, &inv_state.container.base);
                try tag.set("Inventory", .{ .List = inv_list });
                try tag.set("SelectedInventorySlot", .{ .Int = IntTag.init(@intCast(inv_state.selected_slot), null) });
            }

            const dimension_id: i32 = if (player.entity.dimension) |dimension|
                @intCast(@intFromEnum(dimension.dimension_type))
            else
                0;
            try tag.set("DimensionId", .{ .Int = IntTag.init(dimension_id, null) });

            return tag;
        }

        pub fn deserializePlayer(allocator: std.mem.Allocator, player: anytype, tag: *const CompoundTag) void {
            Hooks.deserializeEntity(allocator, &player.entity, tag);

            if (Hooks.inventoryState(&player.entity)) |inv_state| {
                if (tag.get("Inventory")) |inv| {
                    switch (inv) {
                        .List => |list| {
                            Hooks.deserializeContainer(allocator, &inv_state.container.base, &list);
                        },
                        else => {},
                    }
                }
                if (tag.get("SelectedInventorySlot")) |slot| {
                    switch (slot) {
                        .Int => |i| inv_state.selected_slot = @intCast(@as(u32, @bitCast(i.value)) % 36),
                        else => {},
                    }
                }
            }

            if (Hooks.healthState(&player.entity)) |health_state| {
                if (tag.get("MaxHealth")) |h| {
                    switch (h) {
                        .Float => |f| if (f.value > 0) {
                            health_state.max = f.value;
                        },
                        else => {},
                    }
                }
                if (tag.get("Health")) |h| {
                    switch (h) {
                        .Float => |f| health_state.current = Hooks.clampLoadedHealth(f.value, health_state.max),
                        else => {},
                    }
                }
                health_state.dead = false;
                Hooks.syncAttributes(health_state, &player.entity);
            }
        }
    };
}
