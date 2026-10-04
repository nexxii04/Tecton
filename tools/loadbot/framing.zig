const std = @import("std");

const c = @cImport({
    @cInclude("zlib.h");
});

/// `0xfe` plus compression method byte, mirroring the server's compression.
pub const GAME_PACKET: u8 = 0xfe;
const METHOD_ZLIB: u8 = 0;
const METHOD_SNAPPY: u8 = 1;
const METHOD_NOT_PRESENT: u8 = 2;
const METHOD_NONE: u8 = 0xff;

pub const Options = struct {
    /// Compressing exercises the server's inflate path but costs bot CPU.
    compress: bool = true,
    threshold: usize = 256,
};

pub const Decoded = struct {
    packets: [][]const u8,
    buffer: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Decoded) void {
        self.allocator.free(self.buffer);
        self.allocator.free(self.packets);
    }
};

pub fn encode(packets: []const []const u8, options: Options, allocator: std.mem.Allocator) ![]u8 {
    var framed_size: usize = 0;
    for (packets) |packet| framed_size += varintSize(packet.len) + packet.len;

    const compress = options.compress and framed_size >= options.threshold;

    if (compress) {
        const framed = try allocator.alloc(u8, framed_size);
        defer allocator.free(framed);
        writeFramed(framed, packets);

        const deflated = try deflateRaw(framed, allocator);
        defer allocator.free(deflated);

        const out = try allocator.alloc(u8, deflated.len + 2);
        out[0] = GAME_PACKET;
        out[1] = METHOD_ZLIB;
        @memcpy(out[2..], deflated);
        return out;
    }

    const out = try allocator.alloc(u8, framed_size + 2);
    out[0] = GAME_PACKET;
    out[1] = METHOD_NONE;
    writeFramed(out[2..], packets);
    return out;
}

/// Inverse of `encode`; the packet slices point into the returned buffer.
pub fn decode(data: []const u8, allocator: std.mem.Allocator) !Decoded {
    if (data.len == 0 or data[0] != GAME_PACKET) {
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);
        const packets = try allocator.alloc([]const u8, 1);
        packets[0] = owned;
        return .{ .packets = packets, .buffer = owned, .allocator = allocator };
    }

    // The method byte exists only for 0x00/0x01/0xFF; any other byte starts the frame.
    const method: u8 = if (data.len > 1) data[1] else METHOD_NOT_PRESENT;
    const has_method_byte = method == METHOD_ZLIB or method == METHOD_SNAPPY or method == METHOD_NONE;
    const payload = if (has_method_byte) data[2..] else data[1..];

    if (method == METHOD_ZLIB) {
        const inflated = try inflateRaw(payload, allocator, payload.len * 4 + 64);
        errdefer allocator.free(inflated);
        return unframe(inflated, allocator);
    }

    const owned = try allocator.dupe(u8, payload);
    errdefer allocator.free(owned);
    return unframe(owned, allocator);
}

fn writeFramed(buffer: []u8, packets: []const []const u8) void {
    var offset: usize = 0;
    for (packets) |packet| {
        offset += writeVarInt(buffer[offset..], @intCast(packet.len));
        @memcpy(buffer[offset..][0..packet.len], packet);
        offset += packet.len;
    }
}

fn unframe(buffer: []u8, allocator: std.mem.Allocator) !Decoded {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const header = readVarInt(buffer[offset..]) orelse return error.MalformedFraming;
        offset += header.size + header.value;
        if (offset > buffer.len) return error.MalformedFraming;
        count += 1;
    }

    const packets = try allocator.alloc([]const u8, count);
    errdefer allocator.free(packets);

    offset = 0;
    var index: usize = 0;
    while (offset < buffer.len) : (index += 1) {
        const header = readVarInt(buffer[offset..]) orelse return error.MalformedFraming;
        offset += header.size;
        packets[index] = buffer[offset..][0..@as(usize, header.value)];
        offset += header.value;
    }

    return .{ .packets = packets, .buffer = buffer, .allocator = allocator };
}

fn deflateRaw(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.deflateInit2(&stream, c.Z_BEST_SPEED, c.Z_DEFLATED, -15, 8, c.Z_DEFAULT_STRATEGY) != c.Z_OK) {
        return error.ZlibInitFailed;
    }
    defer _ = c.deflateEnd(&stream);

    const bound: usize = @intCast(c.compressBound(@intCast(input.len)));
    const buffer = try allocator.alloc(u8, bound);
    errdefer allocator.free(buffer);

    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    stream.next_out = buffer.ptr;
    stream.avail_out = @intCast(bound);

    if (c.deflate(&stream, c.Z_FINISH) != c.Z_STREAM_END) return error.ZlibDeflateFailed;
    return try allocator.realloc(buffer, bound - stream.avail_out);
}

fn inflateRaw(input: []const u8, allocator: std.mem.Allocator, hint: usize) ![]u8 {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit2(&stream, -15) != c.Z_OK) return error.ZlibInitFailed;
    defer _ = c.inflateEnd(&stream);

    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var out = try std.ArrayList(u8).initCapacity(allocator, hint);
    defer out.deinit(allocator);

    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        stream.next_out = &chunk;
        stream.avail_out = chunk.len;

        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        try out.appendSlice(allocator, chunk[0 .. chunk.len - stream.avail_out]);

        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.ZlibInflateFailed;
    }

    return out.toOwnedSlice(allocator);
}

inline fn varintSize(value: usize) usize {
    if (value < 0x80) return 1;
    if (value < 0x4000) return 2;
    if (value < 0x200000) return 3;
    if (value < 0x10000000) return 4;
    return 5;
}

inline fn writeVarInt(buffer: []u8, value: usize) usize {
    var remaining = value;
    var pos: usize = 0;
    while (remaining >= 0x80) {
        buffer[pos] = @intCast((remaining & 0x7F) | 0x80);
        remaining >>= 7;
        pos += 1;
    }
    buffer[pos] = @intCast(remaining & 0x7F);
    return pos + 1;
}

const VarInt = struct { value: u32, size: usize };

fn readVarInt(buffer: []const u8) ?VarInt {
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

const testing = std.testing;

test "compressed datagrams round-trip through encode and decode" {
    const allocator = testing.allocator;
    const payload = "x" ** 900;
    const packets = [_][]const u8{ payload, "small" };

    const encoded = try encode(&packets, .{ .compress = true, .threshold = 1 }, allocator);
    defer allocator.free(encoded);

    try testing.expectEqual(GAME_PACKET, encoded[0]);
    try testing.expectEqual(METHOD_ZLIB, encoded[1]);

    const decoded = try decode(encoded, allocator);
    defer decoded.deinit();

    try testing.expectEqual(@as(usize, 2), decoded.packets.len);
    try testing.expectEqualStrings(payload, decoded.packets[0]);
    try testing.expectEqualStrings("small", decoded.packets[1]);
}

test "small datagrams stay uncompressed and declare the none method" {
    const allocator = testing.allocator;
    const packets = [_][]const u8{"tiny"};

    const encoded = try encode(&packets, .{ .compress = true, .threshold = 256 }, allocator);
    defer allocator.free(encoded);
    try testing.expectEqual(METHOD_NONE, encoded[1]);

    const decoded = try decode(encoded, allocator);
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.packets.len);
    try testing.expectEqualStrings("tiny", decoded.packets[0]);
}

test "datagrams without the game packet header count as a single packet" {
    const allocator = testing.allocator;
    const decoded = try decode(&[_]u8{ 0x01, 0xAA, 0xBB }, allocator);
    defer decoded.deinit();

    try testing.expectEqual(@as(usize, 1), decoded.packets.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xAA, 0xBB }, decoded.packets[0]);
}

test "datagrams without a method byte are decoded as uncompressed" {
    const allocator = testing.allocator;
    const packet = [_]u8{ 0x8f, 0x01, 0x02, 0x03 };
    const datagram = [_]u8{ GAME_PACKET, packet.len } ++ packet;

    const decoded = try decode(&datagram, allocator);
    defer decoded.deinit();

    try testing.expectEqual(@as(usize, 1), decoded.packets.len);
    try testing.expectEqualSlices(u8, &packet, decoded.packets[0]);
}

test "unframe rejects a length that runs past the payload" {
    const allocator = testing.allocator;
    try testing.expectError(error.MalformedFraming, decode(&[_]u8{ GAME_PACKET, METHOD_NONE, 0x7F, 0xAA }, allocator));
}
