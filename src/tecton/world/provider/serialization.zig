//! Provider serialization facade.
const codec = @import("nbt_codec.zig");
const sanitize_mod = @import("sanitize.zig");
const items = @import("serialize_items.zig");
const entities = @import("serialize_entities.zig");
const players = @import("serialize_player.zig");

pub const encodeNbt = codec.encodeNbt;
pub const decodeNbt = codec.decodeNbt;

pub const world_border = sanitize_mod.world_border;
pub const max_motion = sanitize_mod.max_motion;

pub const serializeItemStack = items.serializeItemStack;
pub const deserializeItemStack = items.deserializeItemStack;
pub const serializeContainer = items.serializeContainer;
pub const deserializeContainer = items.deserializeContainer;

pub const serializeEntity = entities.serializeEntity;
pub const deserializeEntity = entities.deserializeEntity;

pub const serializePlayer = players.serializePlayer;
pub const deserializePlayer = players.deserializePlayer;
