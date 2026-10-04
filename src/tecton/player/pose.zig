const std = @import("std");
const testing = std.testing;

const EntityActorFlags = @import("../entity/metadata/actor-flags.zig").EntityActorFlags;

pub const Pose = enum(u8) {
    standing,
    sneaking,
    gliding,
    swimming,
    crawling,

    pub const Size = EntityActorFlags.Size;

    pub fn select(gliding: bool, swimming: bool, crawling: bool, sneaking: bool) Pose {
        if (gliding) return .gliding;
        if (swimming) return .swimming;
        if (crawling) return .crawling;
        if (sneaking) return .sneaking;
        return .standing;
    }

    pub fn next(current: Pose, gliding: bool, swimming: bool, crawling: bool, sneaking: bool) ?Pose {
        const pose = select(gliding, swimming, crawling, sneaking);
        return if (pose == current) null else pose;
    }

    pub fn size(self: Pose) Size {
        return switch (self) {
            .standing => .{ .width = 0.6, .height = 1.8 },
            .sneaking => .{ .width = 0.6, .height = 1.5 },
            .gliding, .swimming, .crawling => .{ .width = 0.6, .height = 0.6 },
        };
    }
};

test "a higher pose wins over a lower one" {
    try testing.expectEqual(Pose.gliding, Pose.select(true, true, true, true));
    try testing.expectEqual(Pose.swimming, Pose.select(false, true, true, true));
    try testing.expectEqual(Pose.crawling, Pose.select(false, false, true, true));
    try testing.expectEqual(Pose.sneaking, Pose.select(false, false, false, true));
    try testing.expectEqual(Pose.standing, Pose.select(false, false, false, false));
}

test "a pose that did not move is not a change to broadcast" {
    try testing.expectEqual(@as(?Pose, null), Pose.next(.standing, false, false, false, false));
    try testing.expectEqual(@as(?Pose, Pose.gliding), Pose.next(.standing, true, false, false, false));
    try testing.expectEqual(@as(?Pose, null), Pose.next(.gliding, true, false, false, false));
    try testing.expectEqual(@as(?Pose, Pose.standing), Pose.next(.gliding, false, false, false, false));
    try testing.expectEqual(@as(?Pose, null), Pose.next(.sneaking, false, false, false, true));
}

test "only gliding, swimming and crawling shrink the player to one block" {
    try testing.expectEqual(@as(f32, 0.6), Pose.gliding.size().height);
    try testing.expectEqual(@as(f32, 0.6), Pose.swimming.size().height);
    try testing.expectEqual(@as(f32, 0.6), Pose.crawling.size().height);
    try testing.expectEqual(@as(f32, 1.5), Pose.sneaking.size().height);
    try testing.expectEqual(@as(f32, 1.8), Pose.standing.size().height);
}

test "every pose keeps the player width" {
    for (std.enums.values(Pose)) |pose| {
        try testing.expectEqual(@as(f32, 0.6), pose.size().width);
    }
}
