const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;

pub const BiomeStorage = struct {
    const cell_count = 4096;

    allocator: std.mem.Allocator,
    palette: std.ArrayList(u32) = .empty,
    data: ?[]u32 = null,
    bits: u5 = 1,

    pub fn init(allocator: std.mem.Allocator) BiomeStorage {
        return .{ .allocator = allocator };
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
        if (self.data == null) return self.uniformBiome();
        return self.palette.items[self.indexAt(cellIndex(bx, by, bz))];
    }

    pub fn setBiome(self: *BiomeStorage, bx: u8, by: u8, bz: u8, biome: u32) !void {
        if (self.data == null and self.uniformBiome() == biome) return;
        const added_zero = self.palette.items.len == 0;
        if (added_zero) try self.palette.append(self.allocator, 0);
        errdefer if (added_zero) {
            self.palette.items.len = 0;
        };
        var index: usize = 0;
        while (index < self.palette.items.len and self.palette.items[index] != biome) : (index += 1) {}
        const appended = index == self.palette.items.len;
        if (appended) {
            if (index >= cell_count) return error.PaletteOverflow;
            try self.palette.append(self.allocator, biome);
        }
        errdefer if (appended) {
            self.palette.items.len -= 1;
        };
        const needed = bitsFor(self.palette.items.len);
        if (self.data == null or needed > self.bits) {
            const words = try self.allocator.alloc(u32, wordsFor(needed));
            @memset(words, 0);
            if (self.data) |old| {
                for (0..cell_count) |pos| writeIndex(words, needed, pos, self.indexAt(pos));
                self.allocator.free(old);
            }
            self.data = words;
            self.bits = needed;
        }
        writeIndex(self.data.?, self.bits, cellIndex(bx, by, bz), @intCast(index));
    }

    pub fn heapBytes(self: *const BiomeStorage) usize {
        const data_bytes = if (self.data) |data| data.len * @sizeOf(u32) else 0;
        return data_bytes + self.palette.capacity * @sizeOf(u32);
    }

    fn bitsFor(len: usize) u5 {
        const needed = std.math.log2_int_ceil(usize, @max(len, 2));
        return @intCast(switch (needed) {
            1...6 => needed,
            7, 8 => 8,
            else => 16,
        });
    }

    fn wordsFor(bits: u5) usize {
        const per_word = 32 / @as(usize, bits);
        return (cell_count + per_word - 1) / per_word;
    }

    fn indexAt(self: *const BiomeStorage, pos: usize) u32 {
        const data = self.data orelse return 0;
        const per_word = 32 / @as(usize, self.bits);
        const shift: u5 = @intCast((pos % per_word) * self.bits);
        return (data[pos / per_word] >> shift) & ((@as(u32, 1) << self.bits) - 1);
    }

    fn writeIndex(data: []u32, bits: u5, pos: usize, value: u32) void {
        const per_word = 32 / @as(usize, bits);
        const shift: u5 = @intCast((pos % per_word) * bits);
        const mask = ((@as(u32, 1) << bits) - 1) << shift;
        const word = &data[pos / per_word];
        word.* = (word.* & ~mask) | (value << shift);
    }

    fn cellIndex(bx: u8, by: u8, bz: u8) usize {
        return ((@as(usize, bx) & 15) << 8) | (@as(usize, by) & 15) | ((@as(usize, bz) & 15) << 4);
    }

    pub fn serialize(self: *const BiomeStorage, stream: *BinaryStream) !void {
        if (self.data == null) {
            try stream.writeUint8(0);
            try stream.writeInt32(@bitCast(self.uniformBiome()), .Little);
            return;
        }
        try stream.writeUint8(@as(u8, self.bits) << 1);
        for (self.data.?) |word| try stream.writeInt32(@bitCast(word), .Little);
        try stream.writeZigZag(@intCast(self.palette.items.len));
        for (self.palette.items) |biome| try stream.writeZigZag(@intCast(biome));
    }

    pub fn deserialize(stream: *BinaryStream, allocator: std.mem.Allocator) !BiomeStorage {
        const wire_bits = (try stream.readUint8()) >> 1;
        var storage = BiomeStorage.init(allocator);
        errdefer storage.deinit();
        switch (wire_bits) {
            0x7f => return storage,
            0 => {
                const biome = try stream.readInt32(.Little);
                if (biome < 0) return error.InvalidBiome;
                try storage.palette.append(allocator, @intCast(biome));
                return storage;
            },
            1...6, 8, 16 => {},
            else => return error.InvalidBitsPerBiome,
        }
        storage.bits = @intCast(wire_bits);
        storage.data = try allocator.alloc(u32, wordsFor(storage.bits));
        for (storage.data.?) |*word| word.* = @bitCast(try stream.readInt32(.Little));
        const palette_size = try stream.readZigZag();
        if (palette_size <= 0 or palette_size > cell_count) return error.InvalidPaletteSize;
        try storage.palette.ensureTotalCapacityPrecise(allocator, @intCast(palette_size));
        for (0..@intCast(palette_size)) |_| {
            const biome = try stream.readZigZag();
            if (biome < 0) return error.InvalidBiome;
            storage.palette.appendAssumeCapacity(@intCast(biome));
        }
        for (0..cell_count) |pos| {
            if (storage.indexAt(pos) >= storage.palette.items.len) return error.InvalidPaletteIndex;
        }
        return storage;
    }
};

fn exerciseBiomeGrowth(allocator: std.mem.Allocator) !void {
    var storage = BiomeStorage.init(allocator);
    defer storage.deinit();
    for (0..130) |pos| try storage.setBiome(@intCast(pos >> 8), @intCast(pos & 15), @intCast((pos >> 4) & 15), @intCast(pos + 1));
    for (0..130) |pos| try std.testing.expectEqual(@as(u32, @intCast(pos + 1)), storage.getBiome(@intCast(pos >> 8), @intCast(pos & 15), @intCast((pos >> 4) & 15)));
}

test "packed biomes grow safely through every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBiomeGrowth, .{});
}

test "two biome values use a one bit slab and serialize without allocation" {
    var storage = BiomeStorage.init(std.testing.allocator);
    defer storage.deinit();
    try storage.setBiome(1, 2, 3, 7);
    try std.testing.expect(storage.heapBytes() < 1024);
    try std.testing.expectEqual(@as(u32, 0), storage.getBiome(2, 2, 3));
    var bytes: [1024]u8 = undefined;
    var stream = BinaryStream.init(std.testing.failing_allocator, &bytes, null);
    stream.reset();
    try storage.serialize(&stream);
    var reader = BinaryStream.init(std.testing.failing_allocator, stream.getBuffer(), null);
    var decoded = try BiomeStorage.deserialize(&reader, std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 7), decoded.getBiome(1, 2, 3));
    try std.testing.expectEqual(@as(u32, 0), decoded.getBiome(2, 2, 3));
}

test "packed biomes round trip every supported width without serialization allocations" {
    const allocator = std.testing.allocator;
    var bytes: [32768]u8 = undefined;
    for ([_]usize{ 2, 3, 5, 9, 17, 33, 65, 257 }) |colors| {
        var storage = BiomeStorage.init(allocator);
        defer storage.deinit();
        for (0..BiomeStorage.cell_count) |pos| {
            try storage.setBiome(@intCast(pos >> 8), @intCast(pos & 15), @intCast((pos >> 4) & 15), @intCast(pos % colors));
        }
        var stream = BinaryStream.init(std.testing.failing_allocator, &bytes, null);
        stream.reset();
        try storage.serialize(&stream);
        try std.testing.expectEqual(@as(u8, BiomeStorage.bitsFor(colors)) << 1, bytes[0]);
        var reader = BinaryStream.init(std.testing.failing_allocator, stream.getBuffer(), null);
        var decoded = try BiomeStorage.deserialize(&reader, allocator);
        defer decoded.deinit();
        for (0..BiomeStorage.cell_count) |pos| {
            try std.testing.expectEqual(@as(u32, @intCast(pos % colors)), decoded.getBiome(@intCast(pos >> 8), @intCast(pos & 15), @intCast((pos >> 4) & 15)));
        }
        try std.testing.expect(reader.isEof());
    }
}

test "biome decoding rejects invalid widths palettes and indices" {
    var bytes = [_]u8{14};
    var reader = BinaryStream.init(std.testing.failing_allocator, &bytes, null);
    try std.testing.expectError(error.InvalidBitsPerBiome, BiomeStorage.deserialize(&reader, std.testing.allocator));
    var encoded = [_]u8{0} ** 515;
    encoded[0] = 2;
    encoded[1] = 1;
    encoded[513] = 2;
    reader = BinaryStream.init(std.testing.failing_allocator, &encoded, null);
    try std.testing.expectError(error.InvalidPaletteIndex, BiomeStorage.deserialize(&reader, std.testing.allocator));
}
