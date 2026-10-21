const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;
const BlockPermutation = @import("../../block/block_permutation.zig").BlockPermutation;
const BlockState = @import("../../block/block_permutation.zig").BlockState;
const NBT = @import("nbt");

const computePermutationHashFast = @import("permutation_hash.zig").computePermutationHashFast;

pub const BlockStorage = struct {
    const MAX_X = 16;
    const MAX_Y = 16;
    const MAX_Z = 16;
    const MAX_SIZE = 16 * 16 * 16;
    const MAX_PALETTE = 256;

    allocator: std.mem.Allocator,
    size: [3]usize,
    palette: std.ArrayList(i32),
    words: []u32,
    bits: u5,
    air: i32,

    pub fn paletteSlice(self: *const BlockStorage) []const i32 {
        return self.palette.items;
    }

    pub fn init(allocator: std.mem.Allocator) !BlockStorage {
        const air_perm = try BlockPermutation.resolve(allocator, "minecraft:air", null);
        const air_id = air_perm.network_id;

        var palette: std.ArrayList(i32) = .empty;
        errdefer palette.deinit(allocator);
        try palette.append(allocator, air_id);

        return BlockStorage{
            .allocator = allocator,
            .size = [3]usize{ MAX_X, MAX_Y, MAX_Z },
            .palette = palette,
            .words = &.{},
            .bits = 1,
            .air = air_id,
        };
    }

    pub fn deinit(self: *BlockStorage) void {
        self.palette.deinit(self.allocator);
        if (self.words.len > 0) self.allocator.free(self.words);
    }

    pub fn isEmpty(self: *const BlockStorage) bool {
        return self.palette.items.len == 1 and self.palette.items[0] == self.air;
    }

    pub fn getState(self: *const BlockStorage, bx: u8, by: u8, bz: u8) i32 {
        if (self.palette.items.len == 0) return self.air;
        const index = readIndex(self.words, self.bits, self.getIndex(bx, by, bz));
        return self.palette.items[index];
    }

    pub fn paletteIndexAt(self: *const BlockStorage, pos: usize) u32 {
        return readIndex(self.words, self.bits, pos);
    }

    pub fn setState(self: *BlockStorage, bx: u8, by: u8, bz: u8, state: i32) !void {
        var palette_index: u32 = 0;
        var found = false;
        for (self.palette.items, 0..) |pal_state, i| {
            if (pal_state == state) {
                palette_index = @intCast(i);
                found = true;
                break;
            }
        }

        if (!found) {
            if (self.palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
            palette_index = @intCast(self.palette.items.len);
            try self.palette.append(self.allocator, state);
            errdefer self.palette.items.len -= 1;
            try self.widen();
        }

        if (palette_index == 0 and self.words.len == 0) return;

        try self.ensureWords();
        writeIndex(self.words, self.bits, self.getIndex(bx, by, bz), palette_index);
    }

    pub fn heapBytes(self: *const BlockStorage) usize {
        return self.words.len * @sizeOf(u32) + self.palette.capacity * @sizeOf(i32);
    }

    fn getIndex(self: *const BlockStorage, bx: u8, by: u8, bz: u8) usize {
        const dx = (@as(usize, bx) & (self.size[0] - 1)) << 8;
        const dy = @as(usize, by) & (self.size[1] - 1);
        const dz = (@as(usize, bz) & (self.size[2] - 1)) << 4;
        return dx | dy | dz;
    }

    fn bitsFor(palette_len: usize) u5 {
        const needed = std.math.log2_int_ceil(usize, @max(palette_len, 2));
        return @intCast(switch (needed) {
            1...6 => needed,
            7, 8 => 8,
            else => 16,
        });
    }

    fn wordsFor(bits: u5) usize {
        const blocks_per_word: usize = 32 / @as(usize, bits);
        return (MAX_SIZE + blocks_per_word - 1) / blocks_per_word;
    }

    fn readIndex(words: []const u32, bits: u5, pos: usize) u32 {
        if (words.len == 0) return 0;
        const blocks_per_word: usize = 32 / @as(usize, bits);
        const shift: u5 = @intCast((pos % blocks_per_word) * @as(usize, bits));
        const mask: u32 = (@as(u32, 1) << bits) - 1;
        return (words[pos / blocks_per_word] >> shift) & mask;
    }

    fn writeIndex(words: []u32, bits: u5, pos: usize, value: u32) void {
        const blocks_per_word: usize = 32 / @as(usize, bits);
        const shift: u5 = @intCast((pos % blocks_per_word) * @as(usize, bits));
        const mask: u32 = (@as(u32, 1) << bits) - 1;
        const word = &words[pos / blocks_per_word];
        word.* = (word.* & ~(mask << shift)) | ((value & mask) << shift);
    }

    fn ensureWords(self: *BlockStorage) !void {
        if (self.words.len > 0) return;
        const words = try self.allocator.alloc(u32, wordsFor(self.bits));
        @memset(words, 0);
        self.words = words;
    }

    fn widen(self: *BlockStorage) !void {
        const needed = bitsFor(self.palette.items.len);
        if (needed <= self.bits) return;

        const words = try self.allocator.alloc(u32, wordsFor(needed));
        @memset(words, 0);
        for (0..MAX_SIZE) |pos| {
            writeIndex(words, needed, pos, readIndex(self.words, self.bits, pos));
        }

        if (self.words.len > 0) self.allocator.free(self.words);
        self.words = words;
        self.bits = needed;
    }

    fn wireBits(self: *const BlockStorage) u8 {
        const needed: u8 = if (self.palette.items.len > 1)
            @intCast(std.math.log2_int_ceil(usize, self.palette.items.len))
        else
            1;

        return switch (needed) {
            1, 2, 3, 4, 5, 6 => needed,
            7, 8 => 8,
            else => 16,
        };
    }

    fn encodeZigZag32(value: i32) u32 {
        const shifted: i32 = value << 1;
        const sign: i32 = value >> 31;
        const result: i32 = shifted ^ sign;
        return @bitCast(result);
    }

    fn decodeZigZag32(value: u32) i32 {
        const shifted: u32 = value >> 1;
        const sign: u32 = 0 -% (value & 1);
        return @bitCast(shifted ^ sign);
    }

    fn writePacked(self: *const BlockStorage, stream: *BinaryStream, bits_per_block: u8) !void {
        const blocks_per_word: usize = 32 / @as(usize, bits_per_block);
        const word_count: usize = (MAX_SIZE + blocks_per_word - 1) / blocks_per_word;

        var w: usize = 0;
        while (w < word_count) : (w += 1) {
            var word: u32 = 0;
            var block: usize = 0;
            while (block < blocks_per_word) : (block += 1) {
                const index = w * blocks_per_word + block;
                if (index >= MAX_SIZE) break;

                const state = readIndex(self.words, self.bits, index);
                const offset: u5 = @intCast(block * bits_per_block);
                word |= state << offset;
            }
            try stream.writeInt32(@bitCast(word), .Little);
        }
    }

    pub fn serialize(self: *const BlockStorage, stream: *BinaryStream) !void {
        const bits_per_block = self.wireBits();
        try stream.writeUint8((bits_per_block << 1) | 1);
        try self.writePacked(stream, bits_per_block);

        const palette_len_encoded = encodeZigZag32(@intCast(self.palette.items.len));
        try stream.writeVarInt(palette_len_encoded);

        for (self.palette.items) |state| {
            const encoded = encodeZigZag32(state);
            try stream.writeVarInt(encoded);
        }
    }

    pub fn serializePersistence(self: *const BlockStorage, stream: *BinaryStream, allocator: std.mem.Allocator) !void {
        const bits_per_block = self.wireBits();
        try stream.writeUint8(bits_per_block << 1);
        try self.writePacked(stream, bits_per_block);

        try stream.writeInt32(@intCast(self.palette.items.len), .Little);

        const nbt_opts = NBT.ReadWriteOptions{ .name = true, .tag_type = true, .varint = false, .endian = .Little };
        for (self.palette.items) |state| {
            const perm = BlockPermutation.getByNetworkId(state) orelse continue;
            var compound = perm.toNBT(allocator) catch continue;
            defer compound.deinit(allocator);
            try NBT.CompoundTag.write(stream, &compound, nbt_opts);
        }
    }

    pub fn deserialize(stream: *BinaryStream, allocator: std.mem.Allocator) !BlockStorage {
        const palette_and_flag = try stream.readUint8();
        const bits_per_block: u8 = palette_and_flag >> 1;
        const is_runtime = (palette_and_flag & 1) != 0;

        switch (bits_per_block) {
            0, 1...6, 8, 16 => {},
            else => return error.InvalidBitsPerBlock,
        }

        var wire_words: ?[]u32 = null;
        defer if (wire_words) |w| allocator.free(w);

        if (bits_per_block > 0) {
            const blocks_per_word: usize = 32 / @as(usize, bits_per_block);
            const word_count: usize = (MAX_SIZE + blocks_per_word - 1) / blocks_per_word;
            wire_words = try allocator.alloc(u32, word_count);
            for (0..word_count) |i| {
                wire_words.?[i] = @bitCast(try stream.readInt32(.Little));
            }
        }

        var palette: std.ArrayList(i32) = .empty;
        errdefer palette.deinit(allocator);

        if (is_runtime) {
            const palette_size_encoded = try stream.readVarInt();
            const palette_size_signed = decodeZigZag32(palette_size_encoded);
            if (palette_size_signed < 0 or palette_size_signed > MAX_PALETTE) return error.InvalidPaletteSize;
            const palette_size: usize = @intCast(palette_size_signed);
            for (0..palette_size) |_| {
                const encoded = try stream.readVarInt();
                const state = decodeZigZag32(encoded);
                if (palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
                try palette.append(allocator, state);
            }
        } else {
            const palette_size_i = try stream.readInt32(.Little);
            if (palette_size_i < 0 or palette_size_i > MAX_PALETTE) return error.InvalidPaletteSize;
            const palette_size: usize = @intCast(palette_size_i);
            for (0..palette_size) |_| {
                const nbt_opts = NBT.ReadWriteOptions{ .name = true, .tag_type = true, .varint = false, .endian = .Little };
                var compound = NBT.CompoundTag.read(stream, allocator, nbt_opts) catch {
                    if (palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
                    try palette.append(allocator, 0);
                    continue;
                };
                defer compound.deinit(allocator);

                const name_tag = compound.get("name") orelse {
                    if (palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
                    try palette.append(allocator, 0);
                    continue;
                };
                const identifier = if (name_tag == .String) name_tag.String.value else {
                    if (palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
                    try palette.append(allocator, 0);
                    continue;
                };

                var state_tag: ?NBT.CompoundTag = null;
                if (compound.get("states")) |st| {
                    if (st == .Compound) state_tag = st.Compound;
                }

                const network_id = computePermutationHashFast(identifier, state_tag);
                if (palette.items.len >= MAX_PALETTE) return error.PaletteOverflow;
                if (BlockPermutation.lookupByNbtHash(network_id)) |looked_up_id| {
                    try palette.append(allocator, looked_up_id);
                } else if (BlockPermutation.getByNetworkId(network_id)) |_| {
                    try palette.append(allocator, network_id);
                } else if (BlockPermutation.resolve(allocator, identifier, null)) |perm| {
                    try palette.append(allocator, perm.network_id);
                } else |_| {
                    try palette.append(allocator, 0);
                }
            }
        }

        const air_perm = try BlockPermutation.resolve(allocator, "minecraft:air", null);
        if (palette.items.len == 0) try palette.append(allocator, air_perm.network_id);

        var storage = BlockStorage{
            .allocator = allocator,
            .size = [3]usize{ MAX_X, MAX_Y, MAX_Z },
            .palette = palette,
            .words = &.{},
            .bits = bitsFor(palette.items.len),
            .air = air_perm.network_id,
        };
        palette = .empty;
        errdefer storage.deinit();

        if (wire_words) |words| {
            try storage.ensureWords();
            const blocks_per_word: usize = 32 / @as(usize, bits_per_block);
            const mask: u32 = (@as(u32, 1) << @as(u5, @intCast(bits_per_block))) - 1;
            for (0..MAX_SIZE) |position| {
                const shift: u5 = @intCast((position % blocks_per_word) * @as(usize, bits_per_block));
                const state = (words[position / blocks_per_word] >> shift) & mask;
                if (state >= storage.palette.items.len) return error.InvalidPaletteIndex;
                writeIndex(storage.words, storage.bits, position, state);
            }
        }

        return storage;
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const BlockStorage = test_owner.BlockStorage;
    pub const BlockPermutation = test_owner.BlockPermutation;
    pub const BlockState = test_owner.BlockState;
    pub const NBT = test_owner.NBT;
    pub const computePermutationHashFast = test_owner.computePermutationHashFast;
};

test "computePermutationHashFast matches calculateHash" {
    try @import("block_storage_test.zig").Suite(test_scope).case_000();
}
