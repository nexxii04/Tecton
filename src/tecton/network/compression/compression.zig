const std = @import("std");
const CompressionMethod = @import("protocol").CompressionMethod;
const CompressionOptions = @import("./options.zig").CompressionOptions;

const c = @cImport({
    @cInclude("zlib.h");
});

threadlocal var tl_stream: ?*c.z_stream = null;
threadlocal var tl_inflate_stream: ?*c.z_stream = null;

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

fn acquireInflateStream() !*c.z_stream {
    if (tl_inflate_stream) |s| {
        if (c.inflateReset(s) == c.Z_OK) return s;
        _ = c.inflateEnd(s);
        std.heap.c_allocator.destroy(s);
        tl_inflate_stream = null;
    }
    const s = try std.heap.c_allocator.create(c.z_stream);
    s.zalloc = null;
    s.zfree = null;
    s.@"opaque" = null;
    if (c.inflateInit2(s, -15) != c.Z_OK) {
        std.heap.c_allocator.destroy(s);
        return error.ZlibInitFailed;
    }
    tl_inflate_stream = s;
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

pub const ArenaDecompressResult = struct {
    packets: [][]const u8,
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

    pub fn decompressInto(
        data: []const u8,
        options: CompressionOptions,
        arena_allocator: std.mem.Allocator,
    ) !ArenaDecompressResult {
        _ = options;
        if (data.len == 0 or data[0] != 254) {
            const packets = try arena_allocator.alloc([]const u8, 1);
            packets[0] = data;
            return .{ .packets = packets };
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
            const decompressed = try zlibInflateInto(payload, arena_allocator);
            const packets = try unframe(decompressed, arena_allocator);
            return .{ .packets = packets };
        }

        if (method == .Snappy) {
            const packets = try arena_allocator.alloc([]const u8, 0);
            return .{ .packets = packets };
        }

        const packets = try unframe(payload, arena_allocator);
        return .{ .packets = packets };
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

    fn zlibInflateInto(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const stream = try acquireInflateStream();
        stream.next_in = @constCast(input.ptr);
        stream.avail_in = @as(c_uint, @intCast(input.len));

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.ensureTotalCapacityPrecise(allocator, @max(input.len * 4, 256));
        const grow_step: usize = 64 * 1024;

        while (true) {
            var destination = out.unusedCapacitySlice();
            if (destination.len == 0) {
                try out.ensureUnusedCapacity(allocator, grow_step);
                destination = out.unusedCapacitySlice();
            }

            stream.next_out = destination.ptr;
            stream.avail_out = @intCast(@min(destination.len, std.math.maxInt(c_uint)));
            const before = stream.avail_out;

            const ret = c.inflate(stream, c.Z_NO_FLUSH);
            out.items.len += before - stream.avail_out;

            if (ret == c.Z_STREAM_END) break;
            if (ret == c.Z_OK) continue;
            if (ret == c.Z_BUF_ERROR and stream.avail_out == 0) {
                try out.ensureUnusedCapacity(allocator, grow_step);
                continue;
            }
            return error.ZlibInflateFailed;
        }

        return out.items;
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

const test_owner = @This();
const test_scope = struct {
    pub const private_compression_writeVarInt = test_owner.Compression.writeVarInt;
    pub const std = test_owner.std;
    pub const CompressionOptions = test_owner.CompressionOptions;
    pub const Compression = test_owner.Compression;
    pub const private_compression_readVarInt = test_owner.Compression.readVarInt;
    pub const private_compression_unframe = test_owner.Compression.unframe;
};

test "compression round-trip with pooled streams" {
    try @import("compression_test.zig").Suite(test_scope).case_000();
}

test "batch compression round-trip preserves order and content" {
    try @import("compression_test.zig").Suite(test_scope).case_001();
}

test "readVarInt round-trips values written by writeVarInt" {
    try @import("compression_test.zig").Suite(test_scope).case_002();
}

test "readVarInt rejects malformed varints" {
    try @import("compression_test.zig").Suite(test_scope).case_003();
}

test "unframe rejects packet lengths beyond the payload" {
    try @import("compression_test.zig").Suite(test_scope).case_004();
}

test "unframe rejects unterminated varint framing" {
    try @import("compression_test.zig").Suite(test_scope).case_005();
}

test "unframe rejects truncated packet data" {
    try @import("compression_test.zig").Suite(test_scope).case_006();
}

test "unframe accepts valid framing" {
    try @import("compression_test.zig").Suite(test_scope).case_007();
}

test "decompressInto round-trips without owning the input" {
    try @import("compression_test.zig").Suite(test_scope).case_008();
}

test "decompressInto borrows the input for uncompressed framing" {
    try @import("compression_test.zig").Suite(test_scope).case_009();
}

test "decompressInto survives many back-to-back uses of the pooled inflate stream" {
    try @import("compression_test.zig").Suite(test_scope).case_010();
}
