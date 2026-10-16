const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const NBT = @import("nbt");
const CompoundTag = NBT.CompoundTag;
const ReadWriteOptions = NBT.ReadWriteOptions;
const Protocol = @import("protocol");
const ItemType = @import("./item_type.zig").ItemType;
const trait_mod = @import("./trait.zig");
const EnchantmentStorage = @import("./enchantments/storage.zig").EnchantmentStorage;
const enchantment_nbt = @import("./enchantments/nbt.zig");
const ItemStackTraitInstance = trait_mod.ItemStackTraitInstance;
const ItemStackTraitEvent = trait_mod.Event;
const Player = @import("../player/player.zig").Player;
const Entity = @import("../entity/entity.zig").Entity;

var nextNetworkStackId: i32 = 0;

pub const ItemStack = struct {
    allocator: std.mem.Allocator,
    item_type: *ItemType,
    stack_size: u16,
    metadata: u32,
    nbt: ?CompoundTag,
    network_stack_id: i32,
    traits: std.ArrayList(ItemStackTraitInstance),
    enchantments: EnchantmentStorage = .{},

    pub const Options = struct {
        stack_size: u16 = 1,
        metadata: u32 = 0,
        nbt: ?CompoundTag = null,
    };

    pub fn init(allocator: std.mem.Allocator, item_type: *ItemType, opts: Options) ItemStack {
        const id = @atomicRmw(i32, &nextNetworkStackId, .Add, 1, .monotonic);
        return .{
            .allocator = allocator,
            .item_type = item_type,
            .stack_size = opts.stack_size,
            .metadata = opts.metadata,
            .nbt = opts.nbt,
            .network_stack_id = id,
            .traits = .empty,
        };
    }

    pub fn fromIdentifier(allocator: std.mem.Allocator, identifier: []const u8, opts: Options) ?ItemStack {
        const item_type = ItemType.get(identifier) orelse return null;
        return init(allocator, item_type, opts);
    }

    pub const NbtHooks = struct {
        pub fn syncEnchantments(item: *ItemStack) !void {
            return enchantment_nbt.sync(item);
        }

        pub fn load(allocator: std.mem.Allocator, name: []const u8, count: u16, metadata: u32, nbt_data: ?CompoundTag) ?ItemStack {
            const item_type = ItemType.get(name) orelse return null;
            var item = ItemStack.init(allocator, item_type, .{
                .stack_size = count,
                .metadata = metadata,
                .nbt = nbt_data,
            });
            enchantment_nbt.hydrate(&item);
            enchantment_nbt.sync(&item) catch {};
            return item;
        }
    };

    pub fn cloneWithCount(self: *const ItemStack, allocator: std.mem.Allocator, count: u16) !ItemStack {
        var clone = init(allocator, self.item_type, .{
            .stack_size = count,
            .metadata = self.metadata,
            .nbt = if (self.nbt) |*nbt| try cloneCompound(allocator, nbt) else null,
        });
        clone.enchantments.copyFrom(&self.enchantments);
        return clone;
    }

    pub fn isStackCompatible(self: *const ItemStack, other: *const ItemStack) bool {
        if (self.item_type != other.item_type) return false;
        if (self.metadata != other.metadata) return false;
        if (!self.enchantments.eql(&other.enchantments)) return false;
        return equalOptionalCompound(self.allocator, self.nbt, other.nbt);
    }

    pub fn deinit(self: *ItemStack) void {
        for (self.traits.items) |instance| {
            if (instance.vtable.on_detach) |f| f(instance.ctx, self);
            if (instance.vtable.destroy_fn) |f| f(instance.ctx, self.allocator);
        }
        self.traits.deinit(self.allocator);
        if (self.nbt) |*nbt| nbt.deinit(self.allocator);
    }

    pub fn addTrait(self: *ItemStack, instance: ItemStackTraitInstance) !void {
        try self.traits.append(self.allocator, instance);
        if (instance.vtable.on_attach) |f| f(instance.ctx, self);
    }

    pub fn removeTrait(self: *ItemStack, id: []const u8) void {
        for (self.traits.items, 0..) |instance, i| {
            if (std.mem.eql(u8, instance.identifier, id)) {
                if (instance.vtable.on_detach) |f| f(instance.ctx, self);
                if (instance.vtable.destroy_fn) |f| f(instance.ctx, self.allocator);
                _ = self.traits.swapRemove(i);
                return;
            }
        }
    }

    pub fn hasTrait(self: *const ItemStack, id: []const u8) bool {
        for (self.traits.items) |instance| {
            if (std.mem.eql(u8, instance.identifier, id)) return true;
        }
        return false;
    }

    pub fn getTrait(self: *const ItemStack, id: []const u8) ?ItemStackTraitInstance {
        for (self.traits.items) |instance| {
            if (std.mem.eql(u8, instance.identifier, id)) return instance;
        }
        return null;
    }

    pub fn getTraitState(self: *const ItemStack, comptime T: type) ?*T.TraitState {
        for (self.traits.items) |instance| {
            if (std.mem.eql(u8, instance.identifier, T.identifier)) {
                return @ptrCast(@alignCast(instance.ctx));
            }
        }
        return null;
    }

    pub fn fireEvent(self: *ItemStack, comptime event: ItemStackTraitEvent, args: anytype) ItemStackTraitEvent.ReturnType(event) {
        for (self.traits.items) |instance| {
            if (instance.vtable.get(event)) |f| {
                const result = @call(.auto, f, .{instance.ctx} ++ args);
                if (ItemStackTraitEvent.ReturnType(event) == bool) {
                    if (!result) return false;
                }
            }
        }
        if (ItemStackTraitEvent.ReturnType(event) == bool) return true;
    }

    fn userData(self: *const ItemStack) ?CompoundTag {
        const root = self.nbt orelse return null;
        const inner = root.get("tag") orelse return root;
        if (inner != .Compound) return root;
        return .{
            .value = inner.Compound.value,
            .name = null,
            .allocator = root.allocator,
        };
    }

    pub fn toNetworkStack(self: *const ItemStack) Protocol.NetworkItemStackDescriptor {
        const user_data = userData(self);
        return .{
            .network = self.item_type.network_id,
            .stack_size = self.stack_size,
            .metadata = self.metadata,
            .item_stack_id = if (self.network_stack_id != 0) self.network_stack_id else null,
            .network_block_id = 0,
            .extras = if (user_data) |data| blk: {
                if (data.count() == 0) break :blk null;
                break :blk .{
                    .nbt = data,
                    .can_place_on = &.{},
                    .can_destroy = &.{},
                    .ticking = null,
                };
            } else null,
        };
    }

    pub fn toNetworkInstance(self: *const ItemStack) Protocol.NetworkItemInstanceDescriptor {
        const user_data = userData(self);
        return .{
            .network = self.item_type.network_id,
            .stack_size = self.stack_size,
            .metadata = self.metadata,
            .network_block_id = 0,
            .extras = if (user_data) |data| blk: {
                if (data.count() == 0) break :blk null;
                break :blk .{
                    .nbt = data,
                    .can_place_on = &.{},
                    .can_destroy = &.{},
                    .ticking = null,
                };
            } else null,
        };
    }
};

fn cloneCompound(allocator: std.mem.Allocator, src: *const CompoundTag) !CompoundTag {
    var stream = BinaryStream.init(allocator, null, null);
    defer stream.deinit();
    try CompoundTag.write(&stream, src, ReadWriteOptions.default);
    var read_stream = BinaryStream.init(allocator, stream.getBuffer(), null);
    defer read_stream.deinit();
    return try CompoundTag.read(&read_stream, allocator, ReadWriteOptions.default);
}

fn equalOptionalCompound(allocator: std.mem.Allocator, a: ?CompoundTag, b: ?CompoundTag) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;

    var a_stream = BinaryStream.init(allocator, null, null);
    defer a_stream.deinit();
    CompoundTag.write(&a_stream, &a.?, ReadWriteOptions.default) catch return false;

    var b_stream = BinaryStream.init(allocator, null, null);
    defer b_stream.deinit();
    CompoundTag.write(&b_stream, &b.?, ReadWriteOptions.default) catch return false;

    return std.mem.eql(u8, a_stream.getBuffer(), b_stream.getBuffer());
}

const testing = std.testing;

fn wireTestStack(allocator: std.mem.Allocator, nbt: ?CompoundTag) !ItemStack {
    const item_type = try ItemType.init(
        allocator,
        try allocator.dupe(u8, "minecraft:test_wire_sword"),
        500,
        1,
        false,
        &.{},
        false,
        0,
        .{ .End = .{} },
    );
    return ItemStack.init(allocator, item_type, .{ .nbt = nbt });
}

fn namedCompound(allocator: std.mem.Allocator, name: []const u8) !CompoundTag {
    return CompoundTag.init(allocator, try allocator.dupe(u8, name));
}

fn wrapperedNbt(allocator: std.mem.Allocator) !CompoundTag {
    var inner = try namedCompound(allocator, "tag");
    var entry = CompoundTag.init(allocator, null);
    try entry.set("id", .{ .Short = NBT.ShortTag.init(9, null) });
    try entry.set("lvl", .{ .Short = NBT.ShortTag.init(5, null) });
    const entries = try allocator.alloc(NBT.Tag, 1);
    entries[0] = .{ .Compound = entry };
    try inner.set("ench", .{ .List = NBT.ListTag.init(entries, null) });

    var root = CompoundTag.init(allocator, null);
    try root.add(.{ .Compound = inner });
    return root;
}

test "the wire carries the user data, not the disk wrapper" {
    const allocator = testing.allocator;

    var stack = try wireTestStack(allocator, try wrapperedNbt(allocator));
    defer stack.deinit();
    defer stack.item_type.deinit();

    try testing.expect(stack.nbt.?.get("tag") != null);

    const user_data = stack.toNetworkStack().extras.?.nbt.?;
    try testing.expect(user_data.get("ench") != null);
    try testing.expect(user_data.get("tag") == null);
    try testing.expectEqual(@as(usize, 1), user_data.count());

    const instance = stack.toNetworkInstance().extras.?.nbt.?;
    try testing.expect(instance.get("ench") != null);
    try testing.expect(instance.get("tag") == null);
}

test "a stack without nbt and a stack already holding user data keep their shape" {
    const allocator = testing.allocator;

    var plain = try wireTestStack(allocator, null);
    defer plain.deinit();
    defer plain.item_type.deinit();
    try testing.expect(plain.toNetworkStack().extras == null);
    try testing.expect(plain.toNetworkInstance().extras == null);

    var display_compound = try namedCompound(allocator, "display");
    try display_compound.set("Name", .{ .String = NBT.StringTag.init(try allocator.dupe(u8, "Loose"), null) });
    var loose_root = CompoundTag.init(allocator, null);
    try loose_root.add(.{ .Compound = display_compound });

    var loose = try wireTestStack(allocator, loose_root);
    defer loose.deinit();
    defer loose.item_type.deinit();

    const user_data = loose.toNetworkStack().extras.?.nbt.?;
    try testing.expect(user_data.get("display") != null);
    try testing.expect(user_data.get("tag") == null);
}
