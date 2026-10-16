const std = @import("std");
const NBT = @import("nbt");
pub const BlockState = @import("state.zig").BlockState;
pub const BlockStateValue = @import("state.zig").BlockStateValue;

pub const BlockPermutation = struct {
    network_id: i32,
    identifier: []const u8,
    state: BlockState,
    allocator: std.mem.Allocator,

    var permutations: std.AutoHashMap(i32, *BlockPermutation) = undefined;
    var permutations_initialized = false;
    var nbt_hash_to_network_id: std.AutoHashMap(i32, i32) = undefined;
    var nbt_hash_lookup_initialized = false;

    const HASH_OFFSET: i32 = @bitCast(@as(u32, 0x811c9dc5));

    pub fn initRegistry(allocator: std.mem.Allocator) !void {
        if (!permutations_initialized) {
            permutations = std.AutoHashMap(i32, *BlockPermutation).init(allocator);
            permutations_initialized = true;
        }
    }

    pub fn deinitRegistry() void {
        if (nbt_hash_lookup_initialized) {
            nbt_hash_to_network_id.deinit();
            nbt_hash_lookup_initialized = false;
        }
        if (permutations_initialized) {
            var iter = permutations.valueIterator();
            while (iter.next()) |perm| {
                perm.*.deinit();
            }
            permutations.deinit();
            permutations_initialized = false;
        }
    }

    pub fn init(allocator: std.mem.Allocator, network_id: i32, identifier: []const u8, state: BlockState) !*BlockPermutation {
        const perm = try allocator.create(BlockPermutation);
        perm.* = BlockPermutation{
            .network_id = network_id,
            .identifier = try allocator.dupe(u8, identifier),
            .state = state,
            .allocator = allocator,
        };
        return perm;
    }

    pub fn deinit(self: *BlockPermutation) void {
        self.allocator.free(self.identifier);
        var iter = self.state.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.* == .string) {
                self.allocator.free(entry.value_ptr.string);
            }
        }
        self.state.deinit();
        self.allocator.destroy(self);
    }

    pub fn resolve(_: std.mem.Allocator, identifier: []const u8, state: ?BlockState) !*BlockPermutation {
        const block_type = BlockType.get(identifier);
        if (block_type == null) {
            const air_type = BlockType.get("minecraft:air");
            if (air_type) |air| {
                if (air.getDefaultPermutation()) |air_perm| {
                    return air_perm;
                }
            }
            return error.BlockTypeNotFound;
        }

        if (state) |s| {
            return block_type.?.getPermutation(s);
        }

        if (block_type.?.getDefaultPermutation()) |perm| {
            return perm;
        }

        return error.NoPermutationsFound;
    }

    pub fn register(self: *BlockPermutation) !void {
        try permutations.put(self.network_id, self);
    }

    pub fn initNbtHashLookup(allocator: std.mem.Allocator) !void {
        if (nbt_hash_lookup_initialized) return;
        nbt_hash_to_network_id = std.AutoHashMap(i32, i32).init(allocator);
        nbt_hash_lookup_initialized = true;

        var iter = permutations.iterator();
        while (iter.next()) |entry| {
            const perm = entry.value_ptr.*;
            const hash = try calculateHash(allocator, perm.identifier, perm.state);
            try nbt_hash_to_network_id.put(hash, perm.network_id);
        }
    }

    pub fn lookupByNbtHash(hash: i32) ?i32 {
        if (!nbt_hash_lookup_initialized) return null;
        return nbt_hash_to_network_id.get(hash);
    }

    pub fn getByNetworkId(network_id: i32) ?*BlockPermutation {
        return permutations.get(network_id);
    }

    pub fn valueIterator() @TypeOf(permutations.valueIterator()) {
        return permutations.valueIterator();
    }

    pub fn matches(self: *const BlockPermutation, state: BlockState) bool {
        var iter = state.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            if (self.state.get(key)) |self_value| {
                if (!value.eql(self_value)) {
                    return false;
                }
            } else {
                return false;
            }
        }
        return true;
    }

    pub fn toNBT(self: *const BlockPermutation, allocator: std.mem.Allocator) !NBT.CompoundTag {
        var root = NBT.CompoundTag.init(allocator, null);
        try root.set("name", .{ .String = NBT.StringTag.init(try allocator.dupe(u8, self.identifier), null) });

        var states = NBT.CompoundTag.init(allocator, null);
        var iter = self.state.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            switch (entry.value_ptr.*) {
                .boolean => |b| try states.set(key, .{ .Byte = NBT.ByteTag.init(if (b) 1 else 0, null) }),
                .integer => |i| try states.set(key, .{ .Int = NBT.IntTag.init(i, null) }),
                .string => |s| try states.set(key, .{ .String = NBT.StringTag.init(try allocator.dupe(u8, s), null) }),
            }
        }
        try root.set("states", .{ .Compound = states });

        return root;
    }

    pub const calculateHash = @import("hash.zig").calculateHash;
};

pub const BlockType = struct {
    identifier: []const u8,
    permutations: std.ArrayList(*BlockPermutation),
    perm_by_hash: std.AutoHashMap(i32, *BlockPermutation),
    states: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    var types: std.StringHashMap(*BlockType) = undefined;
    var types_initialized = false;

    pub fn initRegistry(allocator: std.mem.Allocator) !void {
        if (!types_initialized) {
            types = std.StringHashMap(*BlockType).init(allocator);
            types_initialized = true;
        }
    }

    pub fn deinitRegistry() void {
        if (types_initialized) {
            var iter = types.valueIterator();
            while (iter.next()) |block_type| {
                block_type.*.deinit();
            }
            types.deinit();
            types_initialized = false;
        }
    }

    pub fn init(allocator: std.mem.Allocator, identifier: []const u8) !*BlockType {
        const block_type = try allocator.create(BlockType);
        block_type.* = BlockType{
            .identifier = try allocator.dupe(u8, identifier),
            .permutations = .empty,
            .perm_by_hash = std.AutoHashMap(i32, *BlockPermutation).init(allocator),
            .states = .empty,
            .allocator = allocator,
        };
        return block_type;
    }

    pub fn deinit(self: *BlockType) void {
        self.allocator.free(self.identifier);
        self.permutations.deinit(self.allocator);
        self.perm_by_hash.deinit();

        for (self.states.items) |state| {
            self.allocator.free(state);
        }
        self.states.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn get(identifier: []const u8) ?*BlockType {
        return types.get(identifier);
    }

    pub fn register(self: *BlockType) !void {
        try types.put(self.identifier, self);
    }

    pub fn addPermutation(self: *BlockType, permutation: *BlockPermutation) !void {
        try self.permutations.append(self.allocator, permutation);
        try self.perm_by_hash.put(permutation.network_id, permutation);
    }

    pub fn getPermutation(self: *BlockType, state: ?BlockState) *BlockPermutation {
        if (state) |s| {
            const hash = BlockPermutation.calculateHash(self.allocator, self.identifier, s) catch {
                return self.getPermutationLinear(s);
            };
            if (self.perm_by_hash.get(hash)) |perm| return perm;
            return self.getPermutationLinear(s);
        }

        if (self.permutations.items.len > 0) {
            return self.permutations.items[0];
        }

        unreachable;
    }

    fn getPermutationLinear(self: *BlockType, state: BlockState) *BlockPermutation {
        for (self.permutations.items) |perm| {
            if (perm.matches(state)) return perm;
        }
        if (self.permutations.items.len > 0) return self.permutations.items[0];
        unreachable;
    }

    pub fn getDefaultPermutation(self: *BlockType) ?*BlockPermutation {
        if (self.permutations.items.len > 0) {
            return self.permutations.items[0];
        }
        return null;
    }
};
