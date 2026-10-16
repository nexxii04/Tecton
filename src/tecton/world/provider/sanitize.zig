const std = @import("std");

const NBT = @import("nbt");
const Tag = NBT.Tag;

pub const world_border: f32 = 30_000_000;
pub const max_motion: f32 = 1_000;

pub fn sane(value: f32, limit: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, -limit, limit);
}

pub fn getFloat(tag: *const Tag) f32 {
    return switch (tag.*) {
        .Float => |f| f.value,
        else => 0,
    };
}
