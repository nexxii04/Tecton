const std = @import("std");

pub fn unframe(payload: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
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

pub inline fn varintSize(value: usize) usize {
    if (value < 0x80) return 1;
    if (value < 0x4000) return 2;
    if (value < 0x200000) return 3;
    if (value < 0x10000000) return 4;
    return 5;
}

pub inline fn writeVarInt(buffer: []u8, value: usize) usize {
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

pub fn readVarInt(buffer: []const u8) ?VarIntResult {
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
