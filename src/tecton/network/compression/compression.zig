const std = @import("std");
const CompressionMethod = @import("protocol").CompressionMethod;
const CompressionOptions = @import("./options.zig").CompressionOptions;

const c = @cImport({
    @cInclude("zlib.h");
});

threadlocal var tl_stream: ?*c.z_stream = null;

fn acquireThreadLocal() !*c.z_stream {
    if (tl_stream) |s| {
        if (c.deflateReset(s) == c.Z_OK) return s;
        _ = c.deflateEnd(s);
        std.heap.c_allocator.destroy(s);
        tl_stream = null;
    }
    const s = try std.heap.c_allocator.create(c.z_stream);
    s.zalloc = null;
    s.zfree = null;
    s.@"opaque" = null;
    if (c.deflateInit2(s, c.Z_BEST_SPEED, c.Z_DEFLATED, -15, 8, c.Z_DEFAULT_STRATEGY) != c.Z_OK) {
        std.heap.c_allocator.destroy(s);
        return error.ZlibInitFailed;
    }
    tl_stream = s;
    return s;
}

pub const DecompressResult = struct {
    packets: [][]const u8,
    buffer: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DecompressResult) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.packets);
    }
};

pub const Compression = struct {
    pub fn compress(
        packets: []const []const u8,
        options: CompressionOptions,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const method = options.compression_method;
        const threshold = options.compression_threshold;

        var framed_size: usize = 0;
        for (packets) |packet| {
            framed_size += varintSize(packet.len) + packet.len;
        }

        const should_compress = framed_size >= threshold and method == .Zlib;

        if (should_compress) {
            const max_compressed = c.compressBound(@intCast(framed_size));
            const buffer = try allocator.alloc(u8, @intCast(2 + max_compressed));
            errdefer allocator.free(buffer);

            buffer[0] = 254;
            buffer[1] = @intFromEnum(method);

            const framed_buffer = try allocator.alloc(u8, framed_size);
            defer allocator.free(framed_buffer);

            var write_pos: usize = 0;
            for (packets) |packet| {
                write_pos += writeVarInt(framed_buffer[write_pos..], packet.len);
                @memcpy(framed_buffer[write_pos..][0..packet.len], packet);
                write_pos += packet.len;
            }

            var stream = try acquireThreadLocal();

            stream.next_in = @constCast(framed_buffer.ptr);
            stream.avail_in = @as(c_uint, @intCast(framed_size));
            stream.next_out = buffer.ptr + 2;
            stream.avail_out = @as(c_uint, @intCast(max_compressed));

            const ret = c.deflate(stream, c.Z_FINISH);
            if (ret != c.Z_STREAM_END) {
                return error.ZlibDeflateFailed;
            }

            const actual_size = 2 + (max_compressed - stream.avail_out);
            return allocator.realloc(buffer, actual_size);
        } else {
            const header_size: usize = if (method == .NotPresent) 1 else 2;
            const buffer = try allocator.alloc(u8, header_size + framed_size);
            errdefer allocator.free(buffer);

            buffer[0] = 254;
            if (method != .NotPresent) {
                buffer[1] = 0xFF;
            }

            var write_pos = header_size;
            for (packets) |packet| {
                write_pos += writeVarInt(buffer[write_pos..], packet.len);
                @memcpy(buffer[write_pos..][0..packet.len], packet);
                write_pos += packet.len;
            }

            return buffer;
        }
    }

    pub fn decompress(
        data: []const u8,
        options: CompressionOptions,
        allocator: std.mem.Allocator,
    ) !DecompressResult {
        _ = options;
        if (data.len == 0 or data[0] != 254) {
            const owned = try allocator.dupe(u8, data);
            errdefer allocator.free(owned);
            const packets = try allocator.alloc([]const u8, 1);
            packets[0] = owned;
            return .{ .packets = packets, .buffer = owned, .allocator = allocator };
        }

        const method: CompressionMethod = if (data.len > 1) switch (data[1]) {
            @as(u8, @intFromEnum(CompressionMethod.Zlib)) => .Zlib,
            @as(u8, @intFromEnum(CompressionMethod.NotPresent)) => .NotPresent,
            @as(u8, @intFromEnum(CompressionMethod.Snappy)) => .Snappy,
            @as(u8, @intFromEnum(CompressionMethod.None)) => .None,
            else => .NotPresent,
        } else .NotPresent;

        var payload = data;
        if (method != .NotPresent and data.len > 1) {
            payload = payload[2..];
        } else {
            payload = payload[1..];
        }

        if (method == .Zlib) {
            const decompressed = try zlibInflate(payload, allocator);
            errdefer allocator.free(decompressed);
            const packets = try unframe(decompressed, allocator);
            return .{ .packets = packets, .buffer = decompressed, .allocator = allocator };
        }

        if (method == .Snappy) {
            const empty = try allocator.alloc(u8, 0);
            const packets = try allocator.alloc([]const u8, 0);
            return .{ .packets = packets, .buffer = empty, .allocator = allocator };
        }

        const owned = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned);
        const packets = try unframe(owned, allocator);
        return .{ .packets = packets, .buffer = owned, .allocator = allocator };
    }

    fn zlibInflate(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var stream: c.z_stream = undefined;
        stream.zalloc = null;
        stream.zfree = null;
        stream.@"opaque" = null;
        stream.next_in = @constCast(input.ptr);
        stream.avail_in = @as(c_uint, @intCast(input.len));

        if (c.inflateInit2(&stream, -15) != c.Z_OK) {
            return error.ZlibInitFailed;
        }
        defer _ = c.inflateEnd(&stream);

        var out = try std.ArrayList(u8).initCapacity(allocator, input.len * 4);
        defer out.deinit(allocator);

        const chunk_size = 1024 * 256;
        var chunk: [chunk_size]u8 = undefined;

        while (true) {
            stream.next_out = &chunk;
            stream.avail_out = chunk_size;

            const ret = c.inflate(&stream, c.Z_NO_FLUSH);
            const have = chunk_size - stream.avail_out;
            try out.appendSlice(allocator, chunk[0..have]);

            if (ret == c.Z_STREAM_END) break;
            if (ret != c.Z_OK) return error.ZlibInflateFailed;
        }

        return out.toOwnedSlice(allocator);
    }

    fn unframe(payload: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        var count: usize = 0;
        var offset: usize = 0;
        while (offset < payload.len) {
            const v = readVarInt(payload[offset..]) orelse return error.MalformedPacketFraming;
            offset += v.size + v.value;
            if (offset > payload.len) return error.MalformedPacketFraming;
            count += 1;
        }

        const packets = try allocator.alloc([]const u8, count);
        errdefer allocator.free(packets);
        offset = 0;
        var idx: usize = 0;
        while (offset < payload.len) : (idx += 1) {
            const v = readVarInt(payload[offset..]) orelse return error.MalformedPacketFraming;
            offset += v.size;
            if (offset + v.value > payload.len) return error.MalformedPacketFraming;
            packets[idx] = payload[offset..][0..v.value];
            offset += v.value;
        }

        return packets;
    }

    inline fn varintSize(value: usize) usize {
        if (value < 0x80) return 1;
        if (value < 0x4000) return 2;
        if (value < 0x200000) return 3;
        if (value < 0x10000000) return 4;
        return 5;
    }

    inline fn writeVarInt(buffer: []u8, value: usize) usize {
        var val = value;
        var pos: usize = 0;
        while (val >= 0x80) {
            buffer[pos] = @intCast((val & 0x7F) | 0x80);
            val >>= 7;
            pos += 1;
        }
        buffer[pos] = @intCast(val & 0x7F);
        return pos + 1;
    }

    const VarIntResult = struct { value: u32, size: usize };

    // Null on malformed input (bad varints, >5 bytes, overflow); callers drop the frame.
    fn readVarInt(buffer: []const u8) ?VarIntResult {
        var result: u32 = 0;
        var pos: usize = 0;
        while (pos < buffer.len and pos < 5) : (pos += 1) {
            const byte = buffer[pos];
            const chunk: u32 = byte & 0x7F;
            if (pos == 4) {
                if ((byte & 0x80) != 0) return null;
                if (chunk > 0x0F) return null;
            }
            result |= chunk << @intCast(7 * pos);
            if ((byte & 0x80) == 0) return .{ .value = result, .size = pos + 1 };
        }
        return null;
    }
};

test "compression round-trip with pooled streams" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = rng.random();

    const options = CompressionOptions{
        .compression_method = .Zlib,
        .compression_threshold = 1,
    };

    for (0..100) |_| {
        const len = random.intRangeAtMost(usize, 16, 512);
        const data = try allocator.alloc(u8, len);
        defer allocator.free(data);
        random.bytes(data);

        const pkts = [_][]const u8{data};
        const compressed = try Compression.compress(&pkts, options, allocator);
        defer allocator.free(compressed);

        const result = try Compression.decompress(compressed, options, allocator);
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 1), result.packets.len);
        try std.testing.expectEqualSlices(u8, data, result.packets[0]);
    }
}

test "batch compression round-trip preserves order and content" {
    const allocator = std.testing.allocator;
    var rng = std.Random.DefaultPrng.init(0xcafe9876);
    const random = rng.random();

    const options = CompressionOptions{
        .compression_method = .Zlib,
        .compression_threshold = 1,
    };

    for (0..100) |_| {
        const pkt_count = random.intRangeAtMost(usize, 1, 8);
        var pkts: [8][]u8 = undefined;
        var pkt_slices: [8][]const u8 = undefined;

        for (0..pkt_count) |i| {
            const len = random.intRangeAtMost(usize, 16, 256);
            pkts[i] = try allocator.alloc(u8, len);
            random.bytes(pkts[i]);
            pkt_slices[i] = pkts[i];
        }
        defer for (0..pkt_count) |i| allocator.free(pkts[i]);

        const compressed = try Compression.compress(pkt_slices[0..pkt_count], options, allocator);
        defer allocator.free(compressed);

        const result = try Compression.decompress(compressed, options, allocator);
        defer result.deinit();

        try std.testing.expectEqual(pkt_count, result.packets.len);
        for (0..pkt_count) |i| {
            try std.testing.expectEqualSlices(u8, pkts[i], result.packets[i]);
        }
    }
}

test "readVarInt round-trips values written by writeVarInt" {
    const cases = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 0xFFFFFFFF };
    for (cases) |value| {
        var buf: [5]u8 = undefined;
        const size = Compression.writeVarInt(&buf, value);
        const decoded = Compression.readVarInt(buf[0..size]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(value, decoded.value);
        try std.testing.expectEqual(size, decoded.size);
    }
}

test "readVarInt rejects malformed varints" {
    try std.testing.expect(Compression.readVarInt(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }) == null);
    try std.testing.expect(Compression.readVarInt(&.{0x80}) == null);
    try std.testing.expect(Compression.readVarInt(&.{}) == null);
    try std.testing.expect(Compression.readVarInt(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x70 }) == null);
}

test "unframe rejects packet lengths beyond the payload" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0xFF, 0xFF, 0x01, 0xAA, 0xBB };
    try std.testing.expectError(error.MalformedPacketFraming, Compression.unframe(&payload, allocator));
}

test "unframe rejects unterminated varint framing" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{0x80};
    try std.testing.expectError(error.MalformedPacketFraming, Compression.unframe(&payload, allocator));
}

test "unframe rejects truncated packet data" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0x05, 0xAA, 0xBB };
    try std.testing.expectError(error.MalformedPacketFraming, Compression.unframe(&payload, allocator));
}

test "unframe accepts valid framing" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 0x02, 0xAA, 0xBB, 0x00, 0x03, 0xCC, 0xDD, 0xEE };
    const packets = try Compression.unframe(&payload, allocator);
    defer allocator.free(packets);
    try std.testing.expectEqual(@as(usize, 3), packets.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, packets[0]);
    try std.testing.expectEqual(@as(usize, 0), packets[1].len);
    try std.testing.expectEqualSlices(u8, &.{ 0xCC, 0xDD, 0xEE }, packets[2]);
}
