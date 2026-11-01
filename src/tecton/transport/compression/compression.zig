const std = @import("std");
const CompressionMethod = @import("protocol").CompressionMethod;
const CompressionOptions = @import("./options.zig").CompressionOptions;

pub const Framing = enum { initial, negotiated };

pub const max_uncompressed_bytes: usize = 8 * 1024 * 1024;

const c = @cImport({
    @cInclude("zlib.h");
});

threadlocal var tl_stream: ?*c.z_stream = null;
threadlocal var tl_inflate_stream: ?*c.z_stream = null;
threadlocal var tl_framed: []u8 = &.{};

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
    pub fn deinitThreadLocal() void {
        if (tl_stream) |stream| {
            _ = c.deflateEnd(stream);
            std.heap.c_allocator.destroy(stream);
            tl_stream = null;
        }
        if (tl_inflate_stream) |stream| {
            _ = c.inflateEnd(stream);
            std.heap.c_allocator.destroy(stream);
            tl_inflate_stream = null;
        }
        if (tl_framed.len > 0) {
            std.heap.c_allocator.free(tl_framed);
            tl_framed = &.{};
        }
    }

    pub fn compress(
        packets: []const []const u8,
        options: CompressionOptions,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const capacity = frameCapacity(packets, options);
        const buffer = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buffer);

        const framed = try compressInto(packets, options, buffer);
        if (framed.len == capacity) return buffer;
        return allocator.realloc(buffer, framed.len);
    }

    pub fn frameCapacity(packets: []const []const u8, options: CompressionOptions) usize {
        const framed_size = framedLength(packets);
        if (compresses(options, framed_size)) {
            return 1 + @as(usize, @intCast(c.compressBound(@intCast(framed_size))));
        }
        return headerLength(options) + framed_size;
    }

    pub fn compressInto(packets: []const []const u8, options: CompressionOptions, dest: []u8) ![]const u8 {
        const framed_size = framedLength(packets);

        if (compresses(options, framed_size)) {
            const max_compressed: usize = @intCast(c.compressBound(@intCast(framed_size)));
            if (dest.len < 1 + max_compressed) return error.CompressionBufferTooSmall;

            const framed = try framedScratch(framed_size);
            framePackets(packets, framed);

            dest[0] = @intFromEnum(options.compression_method);

            const stream = try acquireThreadLocal();
            stream.next_in = framed.ptr;
            stream.avail_in = @as(c_uint, @intCast(framed_size));
            stream.next_out = dest.ptr + 1;
            stream.avail_out = @as(c_uint, @intCast(max_compressed));

            if (c.deflate(stream, c.Z_FINISH) != c.Z_STREAM_END) return error.ZlibDeflateFailed;
            return dest[0 .. 1 + (max_compressed - stream.avail_out)];
        }

        const header_size = headerLength(options);
        if (dest.len < header_size + framed_size) return error.CompressionBufferTooSmall;

        if (header_size == 1) dest[0] = 0xFF;
        framePackets(packets, dest[header_size..][0..framed_size]);
        return dest[0 .. header_size + framed_size];
    }

    fn framedLength(packets: []const []const u8) usize {
        var framed_size: usize = 0;
        for (packets) |packet| framed_size += varintSize(packet.len) + packet.len;
        return framed_size;
    }

    fn headerLength(options: CompressionOptions) usize {
        return if (options.compression_method == .NotPresent) 0 else 1;
    }

    fn compresses(options: CompressionOptions, framed_size: usize) bool {
        return options.compression_method == .Zlib and framed_size >= options.compression_threshold;
    }

    const WireMethod = enum { zlib, snappy, none };

    fn wireMethod(byte: u8) ?WireMethod {
        return switch (byte) {
            @as(u8, @intFromEnum(CompressionMethod.Zlib)) => .zlib,
            @as(u8, @intFromEnum(CompressionMethod.Snappy)) => .snappy,
            @as(u8, @intFromEnum(CompressionMethod.None)) => .none,
            else => null,
        };
    }

    fn framePackets(packets: []const []const u8, dest: []u8) void {
        var write_pos: usize = 0;
        for (packets) |packet| {
            write_pos += writeVarInt(dest[write_pos..], packet.len);
            @memcpy(dest[write_pos..][0..packet.len], packet);
            write_pos += packet.len;
        }
    }

    fn framedScratch(needed: usize) ![]u8 {
        if (tl_framed.len >= needed) return tl_framed[0..needed];
        const grown = try std.heap.c_allocator.alloc(u8, needed);
        if (tl_framed.len > 0) std.heap.c_allocator.free(tl_framed);
        tl_framed = grown;
        return tl_framed[0..needed];
    }

    pub fn decompressInto(
        data: []const u8,
        options: CompressionOptions,
        framing: Framing,
        arena_allocator: std.mem.Allocator,
    ) !ArenaDecompressResult {
        _ = options;
        if (framing == .initial) {
            const packets = try unframe(data, arena_allocator);
            return .{ .packets = packets };
        }

        if (data.len == 0) return error.TruncatedFrame;
        const method = wireMethod(data[0]) orelse return error.InvalidCompressionMethod;
        switch (method) {
            .zlib => {
                const decompressed = try zlibInflateInto(data[1..], arena_allocator);
                const packets = try unframe(decompressed, arena_allocator);
                return .{ .packets = packets };
            },
            .snappy => return error.UnsupportedCompression,
            .none => {
                const packets = try unframe(data[1..], arena_allocator);
                return .{ .packets = packets };
            },
        }
    }

    pub fn decompress(
        data: []const u8,
        options: CompressionOptions,
        framing: Framing,
        allocator: std.mem.Allocator,
    ) !DecompressResult {
        _ = options;
        if (framing == .initial) return decompressOwned(data, allocator);

        if (data.len == 0) return error.TruncatedFrame;
        const method = wireMethod(data[0]) orelse return error.InvalidCompressionMethod;
        switch (method) {
            .zlib => {
                const decompressed = try zlibInflate(data[1..], allocator);
                errdefer allocator.free(decompressed);
                const packets = try unframe(decompressed, allocator);
                return .{ .packets = packets, .buffer = decompressed, .allocator = allocator };
            },
            .snappy => return error.UnsupportedCompression,
            .none => return decompressOwned(data[1..], allocator),
        }
    }

    fn decompressOwned(payload: []const u8, allocator: std.mem.Allocator) !DecompressResult {
        const owned = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned);
        const packets = try unframe(owned, allocator);
        return .{ .packets = packets, .buffer = owned, .allocator = allocator };
    }

    const zlibInflateInto = @import("inflate.zig").Methods(codec_scope).zlibInflateInto;
    const zlibInflate = @import("inflate.zig").Methods(codec_scope).zlibInflate;

    const unframe = @import("framing.zig").unframe;
    const varintSize = @import("framing.zig").varintSize;
    const writeVarInt = @import("framing.zig").writeVarInt;
    const readVarInt = @import("framing.zig").readVarInt;
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

test "compressInto writes the same wire bytes as compress and rejects short buffers" {
    try @import("compression_test.zig").Suite(test_scope).case_011();
}

test "the first NetherNet batch decodes without a compression header" {
    try @import("compression_test.zig").Suite(test_scope).case_012();
}

test "a negotiated frame carries a compression method and no RakNet id" {
    try @import("compression_test.zig").Suite(test_scope).case_013();
}

test "a compressed negotiated frame starts with the zlib method" {
    try @import("compression_test.zig").Suite(test_scope).case_014();
}

const codec_owner = @This();
const codec_scope = struct {
    pub const std = codec_owner.std;
    pub const c = codec_owner.c;
    pub const acquireInflateStream = codec_owner.acquireInflateStream;
    pub const max_uncompressed_bytes = codec_owner.max_uncompressed_bytes;
};
