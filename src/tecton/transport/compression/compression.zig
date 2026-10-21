const std = @import("std");
const CompressionMethod = @import("protocol").CompressionMethod;
const CompressionOptions = @import("./options.zig").CompressionOptions;

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
            return 2 + @as(usize, @intCast(c.compressBound(@intCast(framed_size))));
        }
        return headerLength(options) + framed_size;
    }

    pub fn compressInto(packets: []const []const u8, options: CompressionOptions, dest: []u8) ![]const u8 {
        const framed_size = framedLength(packets);

        if (compresses(options, framed_size)) {
            const max_compressed: usize = @intCast(c.compressBound(@intCast(framed_size)));
            if (dest.len < 2 + max_compressed) return error.CompressionBufferTooSmall;

            const framed = try framedScratch(framed_size);
            framePackets(packets, framed);

            dest[0] = 254;
            dest[1] = @intFromEnum(options.compression_method);

            const stream = try acquireThreadLocal();
            stream.next_in = framed.ptr;
            stream.avail_in = @as(c_uint, @intCast(framed_size));
            stream.next_out = dest.ptr + 2;
            stream.avail_out = @as(c_uint, @intCast(max_compressed));

            if (c.deflate(stream, c.Z_FINISH) != c.Z_STREAM_END) return error.ZlibDeflateFailed;
            return dest[0 .. 2 + (max_compressed - stream.avail_out)];
        }

        const header_size = headerLength(options);
        if (dest.len < header_size + framed_size) return error.CompressionBufferTooSmall;

        dest[0] = 254;
        if (options.compression_method != .NotPresent) dest[1] = 0xFF;
        framePackets(packets, dest[header_size..][0..framed_size]);
        return dest[0 .. header_size + framed_size];
    }

    fn framedLength(packets: []const []const u8) usize {
        var framed_size: usize = 0;
        for (packets) |packet| framed_size += varintSize(packet.len) + packet.len;
        return framed_size;
    }

    fn headerLength(options: CompressionOptions) usize {
        return if (options.compression_method == .NotPresent) 1 else 2;
    }

    fn compresses(options: CompressionOptions, framed_size: usize) bool {
        return options.compression_method == .Zlib and framed_size >= options.compression_threshold;
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
            errdefer allocator.free(empty);
            const packets = try allocator.alloc([]const u8, 0);
            return .{ .packets = packets, .buffer = empty, .allocator = allocator };
        }

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

const codec_owner = @This();
const codec_scope = struct {
    pub const std = codec_owner.std;
    pub const c = codec_owner.c;
    pub const acquireInflateStream = codec_owner.acquireInflateStream;
};
