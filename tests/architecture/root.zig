test "internal module roots expose their existing types" {
    _ = @import("tecton/server/root.zig").ServerOptions;
    _ = @import("tecton/console/root.zig").console;
    _ = @import("tecton/command/list/root.zig").about;
    _ = @import("tecton/network/handlers/root.zig").request_network_settings;
    _ = @import("tecton/world/block/traits/root.zig").BlockTrait;
    _ = @import("tecton/world/chunk/root.zig").Chunk;
    _ = @import("tecton/world/chunk/storage/root.zig").BlockStorage;
    _ = @import("tecton/world/dimension/root.zig").Dimension;
}
