const Protocol = @import("protocol");

pub fn blockPosHash(pos: Protocol.BlockPosition) i64 {
    const x: i64 = @intCast(pos.x);
    const y: i64 = @intCast(pos.y);
    const z: i64 = @intCast(pos.z);
    return (x & 0x3FFFFFF) | ((z & 0x3FFFFFF) << 26) | ((y & 0xFFF) << 52);
}
