const std = @import("std");
const enchantment = @import("enchantment.zig");
const Enchantment = enchantment.Enchantment;
const Slot = enchantment.Slot;
const SlotSet = enchantment.SlotSet;
const Category = enchantment.Category;
const MAX_ENCHANTMENT_ID = enchantment.MAX_ENCHANTMENT_ID;
const MAX_LEVEL = enchantment.MAX_LEVEL;
const set_width = @import("set.zig").WIDTH;

const vanilla_source = @embedFile("data/enchantments.json");

pub const MAX_ALIASES = 8;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    definitions: std.ArrayList(*Enchantment) = .empty,
    by_id: std.ArrayList(?*const Enchantment) = .empty,
    by_name: std.StringHashMapUnmanaged(*const Enchantment) = .{},
    strings: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.definitions.items) |definition| self.allocator.destroy(definition);
        self.definitions.deinit(self.allocator);
        self.by_id.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
        for (self.strings.items) |string| self.allocator.free(string);
        self.strings.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn loadVanilla(self: *Registry) !usize {
        return self.loadJson(vanilla_source);
    }

    pub fn loadJson(self: *Registry, source: []const u8) !usize {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, source, .{});
        defer parsed.deinit();

        const list_value = switch (parsed.value) {
            .object => |object| object.get("enchantments") orelse return error.InvalidEnchantmentData,
            else => return error.InvalidEnchantmentData,
        };
        if (list_value != .array) return error.InvalidEnchantmentData;

        var loaded: usize = 0;
        for (list_value.array.items) |entry| {
            if (entry != .object) return error.InvalidEnchantmentData;
            try self.registerEntry(entry.object);
            loaded += 1;
        }
        return loaded;
    }

    fn registerEntry(self: *Registry, object: std.json.ObjectMap) !void {
        const identifier_field = object.get("identifier") orelse return error.InvalidEnchantmentData;
        const identifier_source = asString(identifier_field) orelse return error.InvalidEnchantmentData;

        const id_field = object.get("id") orelse return error.InvalidEnchantmentData;
        const id_value = asInt(id_field) orelse return error.InvalidEnchantmentData;
        if (id_value < 0 or id_value > MAX_ENCHANTMENT_ID) return error.EnchantmentIdOutOfRange;

        const max_level_field = object.get("max_level") orelse return error.InvalidEnchantmentData;
        const max_level_value = asInt(max_level_field) orelse return error.InvalidEnchantmentData;
        if (max_level_value < 1 or max_level_value > MAX_LEVEL) return error.InvalidEnchantmentMaxLevel;

        const slots_field = object.get("slots") orelse return error.InvalidEnchantmentData;
        const slots = try parseSlots(slots_field);

        var name_source = identifier_source;
        if (object.get("name")) |name_field| {
            name_source = asString(name_field) orelse return error.InvalidEnchantmentData;
        }

        var aliases: [MAX_ALIASES][]const u8 = undefined;
        var alias_count: usize = 0;
        if (object.get("aliases")) |aliases_field| {
            if (aliases_field != .array) return error.InvalidEnchantmentData;
            for (aliases_field.array.items) |alias_field| {
                if (alias_count == MAX_ALIASES) return error.TooManyEnchantmentAliases;
                const alias_source = asString(alias_field) orelse return error.InvalidEnchantmentData;
                aliases[alias_count] = shortName(alias_source);
                alias_count += 1;
            }
        }
        const short_name = shortName(identifier_source);
        if (short_name.len == 0) return error.InvalidEnchantmentData;
        if (self.by_name.contains(short_name)) return error.DuplicateEnchantmentIdentifier;
        for (aliases[0..alias_count], 0..) |alias, index| {
            if (alias.len == 0) return error.InvalidEnchantmentData;
            if (std.mem.eql(u8, alias, short_name)) return error.DuplicateEnchantmentIdentifier;
            for (aliases[index + 1 .. alias_count]) |other| {
                if (std.mem.eql(u8, alias, other)) return error.DuplicateEnchantmentIdentifier;
            }
            if (self.by_name.contains(alias)) return error.DuplicateEnchantmentIdentifier;
        }

        var category: Category = .other;
        if (object.get("category")) |category_field| {
            const category_name = asString(category_field) orelse return error.InvalidEnchantmentData;
            category = std.meta.stringToEnum(Category, category_name) orelse return error.InvalidEnchantmentCategory;
        }

        var group: u8 = 0;
        if (object.get("group")) |group_field| {
            const group_value = asInt(group_field) orelse return error.InvalidEnchantmentData;
            if (group_value < 0 or group_value > 255) return error.InvalidEnchantmentData;
            group = @intCast(group_value);
        }

        var treasure = false;
        if (object.get("treasure")) |treasure_field| {
            treasure = asBool(treasure_field) orelse return error.InvalidEnchantmentData;
        }

        var curse = false;
        if (object.get("curse")) |curse_field| {
            curse = asBool(curse_field) orelse return error.InvalidEnchantmentData;
        }

        var anvil_cost: u8 = 1;
        if (object.get("anvil_cost")) |anvil_field| {
            const anvil_value = asInt(anvil_field) orelse return error.InvalidEnchantmentData;
            if (anvil_value < 1 or anvil_value > 255) return error.InvalidEnchantmentData;
            anvil_cost = @intCast(anvil_value);
        }

        const identifier = try self.ownString(short_name);
        const name = try self.ownString(name_source);

        const definition = try self.allocator.create(Enchantment);
        var listed = false;
        errdefer if (!listed) self.allocator.destroy(definition);
        definition.* = .{
            .id = @intCast(id_value),
            .identifier = identifier,
            .name = name,
            .max_level = @intCast(max_level_value),
            .category = category,
            .slots = slots,
            .group = group,
            .treasure = treasure,
            .curse = curse,
            .anvil_cost = anvil_cost,
        };
        try self.definitions.append(self.allocator, definition);
        listed = true;
        try self.mapId(definition);
        try self.mapName(identifier, definition);

        for (aliases[0..alias_count]) |alias| {
            try self.mapName(try self.ownString(alias), definition);
        }
    }

    pub fn register(self: *Registry, definition: Enchantment) !*const Enchantment {
        if (definition.id > MAX_ENCHANTMENT_ID) return error.EnchantmentIdOutOfRange;
        if (definition.max_level == 0) return error.InvalidEnchantmentMaxLevel;
        if (definition.slots.count() == 0) return error.InvalidEnchantmentData;
        const short = shortName(definition.identifier);
        if (short.len == 0) return error.InvalidEnchantmentData;
        if (self.get(definition.id) != null) return error.DuplicateEnchantmentId;
        if (self.by_name.contains(short)) return error.DuplicateEnchantmentIdentifier;

        const identifier = try self.ownString(short);
        const name = try self.ownString(definition.name);
        const owned = try self.allocator.create(Enchantment);
        var listed = false;
        errdefer if (!listed) self.allocator.destroy(owned);
        owned.* = definition;
        owned.identifier = identifier;
        owned.name = name;
        try self.definitions.append(self.allocator, owned);
        listed = true;
        try self.mapId(owned);
        try self.mapName(identifier, owned);
        return owned;
    }

    fn ownString(self: *Registry, value: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    fn mapId(self: *Registry, definition: *const Enchantment) !void {
        const index: usize = definition.id;
        if (self.by_id.items.len <= index) {
            const previous = self.by_id.items.len;
            try self.by_id.resize(self.allocator, index + 1);
            for (self.by_id.items[previous..]) |*entry| entry.* = null;
        }
        if (self.by_id.items[index] != null) return error.DuplicateEnchantmentId;
        self.by_id.items[index] = definition;
    }

    fn mapName(self: *Registry, name: []const u8, definition: *const Enchantment) !void {
        if (self.by_name.contains(name)) return error.DuplicateEnchantmentIdentifier;
        try self.by_name.put(self.allocator, name, definition);
    }

    pub fn get(self: *const Registry, id: u16) ?*const Enchantment {
        if (id >= self.by_id.items.len) return null;
        return self.by_id.items[id];
    }

    pub fn byName(self: *const Registry, name: []const u8) ?*const Enchantment {
        if (name.len == 0) return null;
        return self.by_name.get(shortName(name));
    }

    pub fn resolve(self: *const Registry, name: []const u8) ?*const Enchantment {
        if (name.len == 0) return null;
        const short = shortName(name);
        if (self.by_name.get(short)) |definition| return definition;
        var iterator = self.by_name.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, short)) return entry.value_ptr.*;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.definitions.items.len;
    }

    pub fn list(self: *const Registry) []const *Enchantment {
        return self.definitions.items;
    }
};

pub fn shortName(identifier: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, identifier, ':')) |index| return identifier[index + 1 ..];
    return identifier;
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn asInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn asBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn parseSlots(value: std.json.Value) !SlotSet {
    if (value != .array) return error.InvalidEnchantmentData;
    var slots: SlotSet = .empty;
    for (value.array.items) |entry| {
        const name = asString(entry) orelse return error.InvalidEnchantmentData;
        const slot = std.meta.stringToEnum(Slot, name) orelse return error.InvalidEnchantmentData;
        slots.insert(slot);
    }
    if (slots.count() == 0) return error.InvalidEnchantmentData;
    return slots;
}

/// The vanilla table, loaded from the embedded JSON on first use and allocated
/// for the life of the process. First load is not thread-safe: use the main thread.
var global_table: ?Registry = null;

/// Loads the vanilla table once; idempotent and retryable after a failure.
pub fn load() !usize {
    if (global_table) |*table| return table.count();

    var table = Registry.init(std.heap.page_allocator);
    errdefer table.deinit();
    _ = try table.loadVanilla();
    global_table = table;
    return table.count();
}

/// Same as `load`, for callers with nowhere to report a load failure.
pub fn ensureGlobal() ?*const Registry {
    _ = load() catch return null;
    return &global_table.?;
}

/// Read-only: nothing can deinit the shared table through it.
pub fn global() ?*const Registry {
    if (global_table) |*table| return table;
    return null;
}

pub fn isLoaded() bool {
    return global_table != null;
}

test "a rejected registration does not leave a definition behind" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();
    const before = registry.count();

    const slots = SlotSet.initOne(.sword);
    var duplicate_id = Enchantment{
        .id = 9,
        .identifier = "test_duplicate_id",
        .name = "Test",
        .max_level = 1,
        .category = .other,
        .slots = slots,
        .group = 0,
        .treasure = false,
        .curse = false,
        .anvil_cost = 1,
    };
    try std.testing.expectError(error.DuplicateEnchantmentId, registry.register(duplicate_id));
    try std.testing.expectEqual(before, registry.count());

    duplicate_id.id = 200;
    duplicate_id.identifier = "sharpness";
    try std.testing.expectError(error.DuplicateEnchantmentIdentifier, registry.register(duplicate_id));
    try std.testing.expectEqual(before, registry.count());
    try std.testing.expect(registry.get(200) == null);

    duplicate_id.identifier = "test_duplicate_id";
    const registered = try registry.register(duplicate_id);
    try std.testing.expectEqual(before + 1, registry.count());
    try std.testing.expectEqual(registered, registry.get(200).?);
}

test "the global table is loaded once and never taken away" {
    const first = try load();
    try std.testing.expectEqual(first, try load());
    try std.testing.expectEqual(first, global().?.count());
    try std.testing.expect(isLoaded());

    const registry = ensureGlobal() orelse return error.ExpectedRegistry;
    try std.testing.expectEqual(registry, global().?);
    try std.testing.expect(registry.count() > 40);
    try std.testing.expectEqual(@as(u16, 9), registry.resolve("sharpness").?.id);
}

test "the table comes back read only and it is always the same one" {
    const Pointer = std.meta.Child(@typeInfo(@TypeOf(global)).@"fn".return_type.?);
    try std.testing.expect(@typeInfo(Pointer).pointer.is_const);

    const loaded = try load();
    const view = global() orelse return error.ExpectedRegistry;
    try std.testing.expectEqual(view, ensureGlobal().?);
    try std.testing.expectEqual(loaded, view.count());
    try std.testing.expectEqual(@as(u16, 9), view.resolve("sharpness").?.id);
}

test "a load that fails halfway leaves no definition the lookups cannot see" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const source =
        \\{"enchantments":[
        \\{"identifier":"test_half_a","id":200,"max_level":1,"slots":["sword"]},
        \\{"identifier":"test_half_b","id":201,"max_level":0,"slots":["sword"]}
        \\]}
    ;
    try std.testing.expectError(error.InvalidEnchantmentMaxLevel, registry.loadJson(source));

    for (registry.list()) |definition| {
        try std.testing.expectEqual(definition, registry.get(definition.id).?);
        try std.testing.expectEqual(definition, registry.byName(definition.identifier).?);
    }
}

test "the id space fits both the bitset and the nbt short" {
    try std.testing.expectEqual(@as(u16, 256), set_width);
    try std.testing.expect(MAX_ENCHANTMENT_ID + 1 == set_width);
    try std.testing.expect(MAX_ENCHANTMENT_ID <= std.math.maxInt(i16));
    try std.testing.expect(MAX_LEVEL <= std.math.maxInt(i16));
}

test "the vanilla table loads with unique ids and identifiers" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const loaded = try registry.loadVanilla();
    try std.testing.expect(loaded > 40);
    try std.testing.expectEqual(loaded, registry.count());
    for (registry.list()) |definition| {
        try std.testing.expect(definition.max_level > 0);
        try std.testing.expect(definition.slots.count() > 0);
        try std.testing.expectEqual(definition, registry.get(definition.id).?);
    }
}

test "resolve accepts short, namespaced and alias names" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();

    try std.testing.expectEqual(@as(u16, 9), registry.resolve("sharpness").?.id);
    try std.testing.expectEqual(@as(u16, 9), registry.resolve("minecraft:sharpness").?.id);
    try std.testing.expectEqual(@as(u16, 9), registry.resolve("SHARPNESS").?.id);
    try std.testing.expectEqual(@as(u16, 27), registry.resolve("curse_of_binding").?.id);
    try std.testing.expectEqual(@as(u16, 28), registry.resolve("curse_of_vanishing").?.id);
    try std.testing.expect(registry.resolve("nope") == null);
    try std.testing.expect(registry.resolve("") == null);
}

test "the incompatibility groups match vanilla" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();
    _ = try registry.loadVanilla();

    try std.testing.expectEqual(@as(u8, 1), registry.resolve("protection").?.group);
    try std.testing.expectEqual(@as(u8, 1), registry.resolve("projectile_protection").?.group);
    try std.testing.expectEqual(@as(u8, 2), registry.resolve("sharpness").?.group);
    try std.testing.expectEqual(@as(u8, 2), registry.resolve("bane_of_arthropods").?.group);
    try std.testing.expectEqual(@as(u8, 0), registry.resolve("unbreaking").?.group);
    try std.testing.expect(registry.resolve("mending").?.treasure);
    try std.testing.expect(registry.resolve("binding").?.curse);
}

test "duplicate ids and identifiers are rejected" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    const source =
        \\{"enchantments":[
        \\{"identifier":"test_a","id":200,"max_level":1,"slots":["sword"]},
        \\{"identifier":"test_b","id":200,"max_level":1,"slots":["sword"]}
        \\]}
    ;
    try std.testing.expectError(error.DuplicateEnchantmentId, registry.loadJson(source));

    const duplicate_name =
        \\{"enchantments":[
        \\{"identifier":"test_a","id":201,"max_level":1,"slots":["sword"]},
        \\{"identifier":"test_a","id":202,"max_level":1,"slots":["sword"]}
        \\]}
    ;
    try std.testing.expectError(error.DuplicateEnchantmentIdentifier, registry.loadJson(duplicate_name));
}

test "malformed entries fail the load" {
    const allocator = std.testing.allocator;
    var registry = Registry.init(allocator);
    defer registry.deinit();

    try std.testing.expectError(error.InvalidEnchantmentMaxLevel, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":0,\"slots\":[\"sword\"]}]}"));
    try std.testing.expectError(error.InvalidEnchantmentData, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[]}]}"));
    try std.testing.expectError(error.InvalidEnchantmentData, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[\"nope\"]}]}"));
    try std.testing.expectError(error.InvalidEnchantmentCategory, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":1,\"max_level\":1,\"slots\":[\"sword\"],\"category\":\"nope\"}]}"));
    try std.testing.expectError(error.EnchantmentIdOutOfRange, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":99999,\"max_level\":1,\"slots\":[\"sword\"]}]}"));
    try std.testing.expectError(error.EnchantmentIdOutOfRange, registry.loadJson("{\"enchantments\":[{\"identifier\":\"x\",\"id\":256,\"max_level\":1,\"slots\":[\"sword\"]}]}"));
}
