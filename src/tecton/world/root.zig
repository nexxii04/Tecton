pub const block = @import("./block/root.zig");
pub const Chunk = @import("./chunk/chunk.zig").Chunk;
pub const Dimension = @import("./dimension/dimension.zig").Dimension;
pub const GameInstance = @import("./game_instance.zig").GameInstance;
pub const GameInstanceRegistry = @import("./game_instance.zig").GameInstanceRegistry;
pub const generator = @import("./generator/root.zig");
pub const provider = @import("./provider/root.zig");
pub const PlayerSerialization = @import("./provider/serialization.zig");
pub const World = @import("./world.zig").World;

comptime {
    _ = @import("./provider/serialization_test_scope.zig");
}
