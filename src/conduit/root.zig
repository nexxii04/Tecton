pub const Command = @import("./command/root.zig");
pub const Conduit = @import("./conduit.zig").Conduit;
pub const ServerPaths = @import("./conduit.zig").ServerPaths;
pub const ServerOptions = @import("./conduit.zig").ServerOptions;
/// Public vanilla server entry point for applications embedding Conduit.
pub const Server = Conduit;
pub const ServerProperties = @import("./config.zig").ServerProperties;
pub const Events = @import("./events/root.zig");
pub const TaskQueue = @import("./tasks/tasks.zig").TaskQueue;
pub const Task = @import("./tasks/tasks.zig").Task;
pub const Plugins = @import("./plugins/root.zig");
pub const GameInstance = @import("./world/game-instance.zig").GameInstance;
pub const GameInstanceRegistry = @import("./world/game-instance.zig").GameInstanceRegistry;
pub const ECS = @import("./entity/ecs.zig");
pub const World = @import("./world/world.zig").World;
pub const Dimension = @import("./world/dimension/dimension.zig").Dimension;
pub const Player = @import("./player/player.zig").Player;
pub const Entity = @import("./entity/entity.zig").Entity;
pub const ItemType = @import("./items/item-type.zig").ItemType;
pub const ItemStack = @import("./items/item-stack.zig").ItemStack;
pub const Block = @import("./world/block/block.zig").Block;
pub const BlockPermutation = @import("./world/block/block-permutation.zig").BlockPermutation;
pub const Worlds = struct {
    pub const World = @import("./world/world.zig").World;
    pub const Dimension = @import("./world/dimension/dimension.zig").Dimension;
};
pub const Entities = struct {
    pub const Entity = @import("./entity/entity.zig").Entity;
    pub const ECS = @import("./entity/ecs.zig");
};
pub const Players = struct {
    pub const Player = @import("./player/player.zig").Player;
};
pub const Items = struct {
    pub const ItemType = @import("./items/item-type.zig").ItemType;
    pub const ItemStack = @import("./items/item-stack.zig").ItemStack;
};
pub const Blocks = struct {
    pub const Block = @import("./world/block/block.zig").Block;
    pub const BlockPermutation = @import("./world/block/block-permutation.zig").BlockPermutation;
};
pub const version = @import("./version.zig").version;
