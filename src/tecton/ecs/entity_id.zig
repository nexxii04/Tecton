pub const Kind = enum(u8) {
    generic = 0,
    player = 1,
    mob = 2,
    item = 3,
    projectile = 4,
    floating_text = 5,
};

pub const EntityId = packed struct(u64) {
    index: u32,
    generation: u16,
    kind: Kind = .generic,
    reserved: u8 = 0,

    pub fn invalid() EntityId {
        return @bitCast(@as(u64, 0));
    }

    pub fn isValid(self: EntityId) bool {
        return self.generation != 0;
    }
};

test "entity id packs index generation and kind into a u64" {
    const id = EntityId{ .index = 0x0123_4567, .generation = 0x89AB, .kind = .mob };
    const raw: u64 = @bitCast(id);
    try @import("std").testing.expectEqual(@as(u64, 0x0002_89AB_0123_4567), raw);
    const round: EntityId = @bitCast(raw);
    try @import("std").testing.expectEqual(id.index, round.index);
    try @import("std").testing.expectEqual(id.generation, round.generation);
    try @import("std").testing.expectEqual(id.kind, round.kind);
}

test "zero entity id is invalid because generations start at one" {
    try @import("std").testing.expect(!EntityId.invalid().isValid());
    try @import("std").testing.expect((EntityId{ .index = 0, .generation = 1, .kind = .player }).isValid());
}
