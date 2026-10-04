const std = @import("std");
const ItemStack = @import("./item-stack.zig").ItemStack;
const ItemType = @import("./item-type.zig").ItemType;
const CompoundTag = @import("nbt").CompoundTag;
const Player = @import("../player/player.zig").Player;
const Entity = @import("../entity/entity.zig").Entity;

pub const Event = enum {
    Attach,
    Detach,
    Use,
    StopUse,
    StartUseOn,
    StopUseOn,
    Attack,
    Break,
    Consume,
    Serialize,
    Deserialize,

    pub fn VTableFnType(comptime event: Event) type {
        return switch (event) {
            .Attach, .Detach, .Break, .Consume => *const fn (*anyopaque, *ItemStack) void,
            .Use => *const fn (*anyopaque, *ItemStack, *Player) bool,
            .StopUse => *const fn (*anyopaque, *ItemStack, *Player) void,
            .StartUseOn, .StopUseOn => *const fn (*anyopaque, *ItemStack, *Player) void,
            .Attack => *const fn (*anyopaque, *ItemStack, *Entity) void,
            .Serialize => *const fn (*anyopaque, *CompoundTag) void,
            .Deserialize => *const fn (*anyopaque, *const CompoundTag) void,
        };
    }

    pub fn ReturnType(comptime event: Event) type {
        return switch (event) {
            .Use => bool,
            else => void,
        };
    }

    pub fn fieldName(comptime event: Event) []const u8 {
        return switch (event) {
            .Attach => "on_attach",
            .Detach => "on_detach",
            .Use => "on_use",
            .StopUse => "on_stop_use",
            .StartUseOn => "on_start_use_on",
            .StopUseOn => "on_stop_use_on",
            .Attack => "on_attack",
            .Break => "on_break",
            .Consume => "on_consume",
            .Serialize => "on_serialize",
            .Deserialize => "on_deserialize",
        };
    }
};

pub const ItemStackTraitVTable = struct {
    on_attach: ?Event.VTableFnType(.Attach) = null,
    on_detach: ?Event.VTableFnType(.Detach) = null,
    on_use: ?Event.VTableFnType(.Use) = null,
    on_stop_use: ?Event.VTableFnType(.StopUse) = null,
    on_start_use_on: ?Event.VTableFnType(.StartUseOn) = null,
    on_stop_use_on: ?Event.VTableFnType(.StopUseOn) = null,
    on_attack: ?Event.VTableFnType(.Attack) = null,
    on_break: ?Event.VTableFnType(.Break) = null,
    on_consume: ?Event.VTableFnType(.Consume) = null,
    on_serialize: ?Event.VTableFnType(.Serialize) = null,
    on_deserialize: ?Event.VTableFnType(.Deserialize) = null,
    destroy_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    pub fn get(self: *const ItemStackTraitVTable, comptime event: Event) ?Event.VTableFnType(event) {
        return @field(self, event.fieldName());
    }
};

pub const ItemStackTraitInstance = struct {
    vtable: *const ItemStackTraitVTable,
    ctx: *anyopaque,
    identifier: []const u8,
};

pub fn ItemStackTrait(comptime State: type, comptime config: ItemStackTraitConfig(State)) type {
    return struct {
        pub const identifier = config.identifier;
        pub const tags = config.tags;
        pub const TraitState = State;

        pub const vtable = blk: {
            var vt = buildVTable(State, config);
            vt.destroy_fn = &struct {
                fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                    const state: *State = @ptrCast(@alignCast(ctx));
                    allocator.destroy(state);
                }
            }.destroy;
            break :blk vt;
        };

        pub fn create(allocator: std.mem.Allocator, initial: State) !ItemStackTraitInstance {
            const state = try allocator.create(State);
            state.* = initial;
            return .{
                .vtable = &vtable,
                .ctx = @ptrCast(state),
                .identifier = identifier,
            };
        }

        pub fn destroy(instance: ItemStackTraitInstance, allocator: std.mem.Allocator) void {
            const state: *State = @ptrCast(@alignCast(instance.ctx));
            allocator.destroy(state);
        }

        pub fn appliesTo(item_type: *const ItemType) bool {
            for (tags) |tag| {
                if (!item_type.hasTag(tag)) return false;
            }
            return true;
        }
    };
}

fn wrapFn(comptime _: type, comptime event: Event, comptime f: anytype) Event.VTableFnType(event) {
    return switch (event) {
        .Attach, .Detach, .Break, .Consume => &struct {
            fn call(ctx: *anyopaque, stack: *ItemStack) void {
                f(@ptrCast(@alignCast(ctx)), stack);
            }
        }.call,
        .Use => &struct {
            fn call(ctx: *anyopaque, stack: *ItemStack, player: *Player) bool {
                return f(@ptrCast(@alignCast(ctx)), stack, player);
            }
        }.call,
        .StopUse, .StartUseOn, .StopUseOn => &struct {
            fn call(ctx: *anyopaque, stack: *ItemStack, player: *Player) void {
                f(@ptrCast(@alignCast(ctx)), stack, player);
            }
        }.call,
        .Attack => &struct {
            fn call(ctx: *anyopaque, stack: *ItemStack, entity: *Entity) void {
                f(@ptrCast(@alignCast(ctx)), stack, entity);
            }
        }.call,
        .Serialize => &struct {
            fn call(ctx: *anyopaque, nbt: *CompoundTag) void {
                f(@ptrCast(@alignCast(ctx)), nbt);
            }
        }.call,
        .Deserialize => &struct {
            fn call(ctx: *anyopaque, nbt: *const CompoundTag) void {
                f(@ptrCast(@alignCast(ctx)), nbt);
            }
        }.call,
    };
}

fn buildVTable(comptime State: type, comptime config: ItemStackTraitConfig(State)) ItemStackTraitVTable {
    var vt = ItemStackTraitVTable{};
    const fields = @typeInfo(ItemStackTraitConfig(State)).@"struct".fields;
    inline for (fields) |field| {
        if (comptime eventFromFieldName(field.name)) |event| {
            if (@field(config, field.name)) |f| {
                @field(vt, event.fieldName()) = wrapFn(State, event, f);
            }
        }
    }
    return vt;
}

fn eventFromFieldName(comptime name: []const u8) ?Event {
    const events = [_]Event{
        .Attach,     .Detach,    .Use,         .StopUse,
        .StartUseOn, .StopUseOn, .Attack,      .Break,
        .Consume,    .Serialize, .Deserialize,
    };
    inline for (events) |e| {
        if (comptime std.mem.eql(u8, name, e.fieldName())) return e;
    }
    return null;
}

pub fn ItemStackTraitConfig(comptime State: type) type {
    return struct {
        identifier: []const u8,
        tags: []const []const u8 = &.{},
        on_attach: ?*const fn (*State, *ItemStack) void = null,
        on_detach: ?*const fn (*State, *ItemStack) void = null,
        on_use: ?*const fn (*State, *ItemStack, *Player) bool = null,
        on_stop_use: ?*const fn (*State, *ItemStack, *Player) void = null,
        on_start_use_on: ?*const fn (*State, *ItemStack, *Player) void = null,
        on_stop_use_on: ?*const fn (*State, *ItemStack, *Player) void = null,
        on_attack: ?*const fn (*State, *ItemStack, *Entity) void = null,
        on_break: ?*const fn (*State, *ItemStack) void = null,
        on_consume: ?*const fn (*State, *ItemStack) void = null,
        on_serialize: ?*const fn (*State, *CompoundTag) void = null,
        on_deserialize: ?*const fn (*State, *const CompoundTag) void = null,
    };
}
