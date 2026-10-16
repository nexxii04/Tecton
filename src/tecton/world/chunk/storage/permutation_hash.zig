const std = @import("std");
const NBT = @import("nbt");

pub fn computePermutationHashFast(identifier: []const u8, state_tag: ?NBT.CompoundTag) i32 {
    const FNV_OFFSET: u32 = 0x811c9dc5;
    const FNV_PRIME: u32 = 16777619;

    var buf: [8192]u8 = undefined;
    var pos: usize = 0;

    buf[pos] = 10;
    pos += 1;
    buf[pos] = 0;
    pos += 1;
    buf[pos] = 0;
    pos += 1;

    buf[pos] = 8;
    pos += 1;
    const name_key = "name";
    const name_len: u16 = @intCast(name_key.len);
    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, name_len))));
    pos += 2;
    @memcpy(buf[pos .. pos + name_key.len], name_key);
    pos += name_key.len;
    const id_len: u16 = @intCast(identifier.len);
    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, id_len))));
    pos += 2;
    @memcpy(buf[pos .. pos + identifier.len], identifier);
    pos += identifier.len;

    buf[pos] = 10;
    pos += 1;
    const states_key = "states";
    const states_len: u16 = @intCast(states_key.len);
    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, states_len))));
    pos += 2;
    @memcpy(buf[pos .. pos + states_key.len], states_key);
    pos += states_key.len;

    if (state_tag) |st| {
        var keys_buf: [64][]const u8 = undefined;
        var keys_count: usize = 0;
        var it = st.value.iterator();
        while (it.next()) |entry| {
            if (keys_count < keys_buf.len) {
                keys_buf[keys_count] = entry.key_ptr.*;
                keys_count += 1;
            }
        }
        const keys = keys_buf[0..keys_count];
        std.mem.sort([]const u8, keys, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (keys) |key| {
            const val = st.value.get(key) orelse continue;
            const klen: u16 = @intCast(key.len);
            switch (val) {
                .Byte => |b| {
                    buf[pos] = 1;
                    pos += 1;
                    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, klen))));
                    pos += 2;
                    @memcpy(buf[pos .. pos + key.len], key);
                    pos += key.len;
                    buf[pos] = @bitCast(b.value);
                    pos += 1;
                },
                .Int => |iv| {
                    buf[pos] = 3;
                    pos += 1;
                    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, klen))));
                    pos += 2;
                    @memcpy(buf[pos .. pos + key.len], key);
                    pos += key.len;
                    @memcpy(buf[pos .. pos + 4], &@as([4]u8, @bitCast(std.mem.nativeToLittle(i32, iv.value))));
                    pos += 4;
                },
                .String => |sv| {
                    buf[pos] = 8;
                    pos += 1;
                    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, klen))));
                    pos += 2;
                    @memcpy(buf[pos .. pos + key.len], key);
                    pos += key.len;
                    const slen: u16 = @intCast(sv.value.len);
                    @memcpy(buf[pos .. pos + 2], &@as([2]u8, @bitCast(std.mem.nativeToLittle(u16, slen))));
                    pos += 2;
                    @memcpy(buf[pos .. pos + sv.value.len], sv.value);
                    pos += sv.value.len;
                },
                else => {},
            }
        }
    }

    buf[pos] = 0;
    pos += 1;
    buf[pos] = 0;
    pos += 1;

    var hash: u32 = FNV_OFFSET;
    for (buf[0..pos]) |byte| {
        hash ^= byte;
        hash *%= FNV_PRIME;
    }
    return @bitCast(hash);
}
