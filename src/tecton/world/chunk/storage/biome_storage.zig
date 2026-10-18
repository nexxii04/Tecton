const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;

pub const BiomeStorage = struct {
    const MAX_X = 16;
    const MAX_Y = 16;
    const MAX_Z = 16;
    const MAX_SIZE = 16 * 16 * 16;

    allocator: std.mem.Allocator,
    palette: std.ArrayList(u32),
    data: ?[]u32,

    pub fn init(allocator: std.mem.Allocator) BiomeStorage {
        return BiomeStorage{
            .allocator = allocator,
            .palette = .empty,
            .data = null,
        };
    }

    pub fn deinit(self: *BiomeStorage) void {
        self.palette.deinit(self.allocator);
        if (self.data) |data| self.allocator.free(data);
        self.data = null;
    }

    pub fn isEmpty(self: *const BiomeStorage) bool {
        return self.data == null and self.uniformBiome() == 0;
    }

    pub fn uniformBiome(self: *const BiomeStorage) u32 {
        return if (self.palette.items.len == 0) 0 else self.palette.items[0];
    }

    pub fn getBiome(self: *const BiomeStorage, bx: u8, by: u8, bz: u8) u32 {
        const data = self.data orelse return self.uniformBiome();
        return self.palette.items[data[cellIndex(bx, by, bz)]];
    }

    pub fn setBiome(self: *BiomeStorage, bx: u8, by: u8, bz: u8, biome: u32) !void {
        if (self.data == null and self.uniformBiome() == biome) return;

        if (self.data == null) {
            if (self.palette.items.len == 0) try self.palette.append(self.allocator, 0);
            const data = try self.allocator.alloc(u32, MAX_SIZE);
            @memset(data, 0);
            self.data = data;
        }

        self.data.?[cellIndex(bx, by, bz)] = try self.paletteIndex(biome);
    }

    pub fn heapBytes(self: *const BiomeStorage) usize {
        const data_bytes = if (self.data) |data| data.len * @sizeOf(u32) else 0;
        return data_bytes + self.palette.capacity * @sizeOf(u32);
    }

    fn paletteIndex(self: *BiomeStorage, biome: u32) !u32 {
        for (self.palette.items, 0..) |pal_biome, i| {
            if (pal_biome == biome) return @intCast(i);
        }
        try self.palette.append(self.allocator, biome);
        return @intCast(self.palette.items.len - 1);
    }

    fn cellIndex(bx: u8, by: u8, bz: u8) usize {
        const dx = (@as(usize, bx) & (MAX_X - 1)) << 8;
        const dy = @as(usize, by) & (MAX_Y - 1);
        const dz = (@as(usize, bz) & (MAX_Z - 1)) << 4;
        return dx | dy | dz;
    }

    pub fn serialize(self: *const BiomeStorage, stream: *BinaryStream) !void {
        var bits_per_biome: u8 = if (self.palette.items.len > 1)
            @as(u8, @intCast(std.math.log2_int_ceil(usize, self.palette.items.len)))
        else
            0;

        bits_per_biome = switch (bits_per_biome) {
            0, 1, 2, 3, 4, 5, 6 => bits_per_biome,
            7, 8 => 8,
            else => 16,
        };

        try stream.writeUint8(bits_per_biome << 1);

        if (bits_per_biome == 0) {
            try stream.writeInt32(@intCast(self.uniformBiome()), .Little);
            return;
        }

        const biomes_per_word: usize = 32 / bits_per_biome;
        const word_count: usize = (MAX_SIZE + biomes_per_word - 1) / biomes_per_word;

        var w: usize = 0;
        while (w < word_count) : (w += 1) {
            var word: u32 = 0;
            var biome: usize = 0;
            while (biome < biomes_per_word) : (biome += 1) {
                const index = w * biomes_per_word + biome;
                if (index >= MAX_SIZE) break;

                const state = if (self.data) |data| data[index] else 0;
                const offset: u5 = @intCast(biome * bits_per_biome);
                word |= state << offset;
            }
            try stream.writeInt32(@bitCast(word), .Little);
        }

        try stream.writeZigZag(@intCast(self.palette.items.len));
        for (self.palette.items) |biome_id| {
            try stream.writeZigZag(@intCast(biome_id));
        }
    }

    pub fn deserialize(stream: *BinaryStream, allocator: std.mem.Allocator) !BiomeStorage {
        const palette_and_flag = try stream.readUint8();
        const bits_per_biome = palette_and_flag >> 1;

        if (bits_per_biome == 0x7f) {
            return BiomeStorage.init(allocator);
        }

        if (bits_per_biome == 0) {
            const biome_id: u32 = @intCast(try stream.readInt32(.Little));
            var storage = BiomeStorage.init(allocator);
            errdefer storage.deinit();
            try storage.palette.append(allocator, biome_id);
            return storage;
        }

        const biomes_per_word: usize = 32 / bits_per_biome;
        const word_count: usize = (MAX_SIZE + biomes_per_word - 1) / biomes_per_word;

        const words = try allocator.alloc(u32, word_count);
        defer allocator.free(words);

        for (0..word_count) |i| {
            words[i] = @bitCast(try stream.readInt32(.Little));
        }

        const palette_size: usize = @intCast(try stream.readZigZag());

        var storage = BiomeStorage.init(allocator);
        errdefer storage.deinit();

        for (0..palette_size) |_| {
            const biome_id: u32 = @intCast(try stream.readZigZag());
            try storage.palette.append(allocator, biome_id);
        }

        const data = try allocator.alloc(u32, MAX_SIZE);
        @memset(data, 0);
        storage.data = data;

        var position: usize = 0;
        for (words) |word| {
            var biome: usize = 0;
            while (biome < biomes_per_word and position < MAX_SIZE) : ({
                biome += 1;
                position += 1;
            }) {
                const mask: u32 = (@as(u32, 1) << @intCast(bits_per_biome)) - 1;
                const shift: u5 = @intCast(biome * bits_per_biome);
                data[position] = (word >> shift) & mask;
            }
        }

        return storage;
    }
};
