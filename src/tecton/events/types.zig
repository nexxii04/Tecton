const Protocol = @import("protocol");

const Entity = @import("../entity/entity.zig").Entity;
const EntityId = @import("../ecs/entity_id.zig").EntityId;
const Player = @import("../player/player.zig").Player;
const BlockPermutation = @import("../world/block/block_permutation.zig").BlockPermutation;
const ItemStack = @import("../items/item_stack.zig").ItemStack;
const enchantment = @import("../items/enchantments/enchantment.zig");

pub const ItemDrop = struct {
    identifier: []const u8,
    count: u16 = 1,
};

pub const ServerStartEvent = struct {};
pub const ServerShutdownEvent = struct {};
pub const ServerTickEvent = struct { tick: u64 };

pub const PlayerJoinEvent = struct {
    player: *Player,
};

pub const PlayerDisconnectEvent = struct {
    player: *Player,
};

pub const PlayerChatEvent = struct {
    player: *Player,
    message: []const u8,

    owned_message: ?[]const u8 = null,
};

pub const ItemUseEvent = struct {
    player: *Player,
    identifier: []const u8,
};

pub const PlayerMoveEvent = struct {
    player: *Player,
    from: Protocol.Vector3f,
    to: Protocol.Vector3f,
};

pub const DamageCause = enum(u8) {
    entity_attack = 0,
    fire = 1,
    fire_tick = 2,
    lava = 3,
    fall = 4,
    explosion = 5,
    projectile = 6,
    thorns = 7,
    magic = 8,
    drowning = 9,
    starvation = 10,
    void = 11,
};

pub const DamageEvent = struct {
    attacker: ?*Entity,
    victim: *Entity,
    amount: f32,
    cause: DamageCause,
};

pub const CombustSource = enum {
    command,
    fire_aspect,
    fire_block,
    lava,
    projectile,
};

pub const EntityCombustEvent = struct {
    entity: *Entity,
    duration: i32,
    instigator: ?*Entity,
    source: CombustSource,
};

pub const BlockPlaceEvent = struct {
    player: *Player,
    position: Protocol.BlockPosition,
    permutation: *BlockPermutation,
};

pub const BlockBreakEvent = struct {
    player: *Player,
    position: Protocol.BlockPosition,
    permutation: *BlockPermutation,
    drops: ?[]const ItemDrop = null,
    entities: ?[]*Entity = null,

    pub fn getDrops(self: *const BlockBreakEvent) []const ItemDrop {
        return self.drops orelse &[_]ItemDrop{};
    }

    pub fn setDrops(self: *BlockBreakEvent, drops: []const ItemDrop) void {
        self.drops = drops;
    }
};

pub const InventoryOpenEvent = struct {
    player: *Player,
    container_id: u8,
};

pub const InventoryClickEvent = struct {
    player: *Player,
    slot: u16,
    button: u8,
};

pub const InventoryCloseEvent = struct {
    player: *Player,
    container_id: u8,
};

pub const TransactionEvent = struct {
    transaction_id: [16]u8,
    player: *Player,
    committed: bool = false,
};

pub const EnchantmentApplyEvent = struct {
    stack: *ItemStack,
    definition: *const enchantment.Enchantment,
    previous_level: ?u8,
    level: u8,
    source: enchantment.Source,
    actor: ?*Player = null,
};

pub const EnchantmentRemoveEvent = struct {
    stack: *ItemStack,
    definition: ?*const enchantment.Enchantment,
    definition_id: u16,
    previous_level: u8,
    source: enchantment.Source,
    actor: ?*Player = null,
};

pub const DespawnCause = enum(u8) {
    death = 0,
    expired = 1,
    unloaded = 2,
    transferred = 3,
    disconnected = 4,
};

pub const EntitySpawnEvent = struct {
    id: EntityId,
    runtime_id: i64,
};

pub const EntityDespawnEvent = struct {
    id: EntityId,
    runtime_id: i64,
    cause: DespawnCause,
};

pub const EntityDamageEvent = struct {
    target: EntityId,
    target_runtime: i64,
    amount: f32,
    source: ?EntityId = null,
    source_runtime: ?i64 = null,
    cause: DamageCause,
};

pub const EntityDeathEvent = struct {
    id: EntityId,
    runtime_id: i64,
    killer_runtime: ?i64 = null,
    position: Protocol.Vector3f,
};

pub const EntityInteractEvent = struct {
    target: EntityId,
    target_runtime: i64,
    player: *Player,
    action: Protocol.InteractAction,
};

pub const Event = enum {
    ServerStart,
    ServerShutdown,
    ServerTick,
    PlayerJoin,
    PlayerDisconnect,
    PlayerChat,
    ItemUse,
    PlayerMove,
    Damage,
    EntityCombust,
    BlockPlace,
    BlockBreak,
    InventoryOpen,
    InventoryClick,
    InventoryClose,
    TransactionPrepare,
    TransactionCommit,
    TransactionAbort,
    EnchantmentApply,
    EnchantmentRemove,
    EntitySpawn,
    EntityDespawn,
    EntityDamage,
    EntityDeath,
    EntityInteract,

    pub fn DataType(comptime event: Event) type {
        return switch (event) {
            .ServerStart => ServerStartEvent,
            .ServerShutdown => ServerShutdownEvent,
            .ServerTick => ServerTickEvent,
            .PlayerJoin => PlayerJoinEvent,
            .PlayerDisconnect => PlayerDisconnectEvent,
            .PlayerChat => PlayerChatEvent,
            .ItemUse => ItemUseEvent,
            .PlayerMove => PlayerMoveEvent,
            .Damage => DamageEvent,
            .EntityCombust => EntityCombustEvent,
            .BlockPlace => BlockPlaceEvent,
            .BlockBreak => BlockBreakEvent,
            .InventoryOpen => InventoryOpenEvent,
            .InventoryClick => InventoryClickEvent,
            .InventoryClose => InventoryCloseEvent,
            .TransactionPrepare, .TransactionCommit, .TransactionAbort => TransactionEvent,
            .EnchantmentApply => EnchantmentApplyEvent,
            .EnchantmentRemove => EnchantmentRemoveEvent,
            .EntitySpawn => EntitySpawnEvent,
            .EntityDespawn => EntityDespawnEvent,
            .EntityDamage => EntityDamageEvent,
            .EntityDeath => EntityDeathEvent,
            .EntityInteract => EntityInteractEvent,
        };
    }
};
