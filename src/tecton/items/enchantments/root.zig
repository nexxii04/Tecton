pub const enchantment = @import("enchantment.zig");
pub const Enchantment = enchantment.Enchantment;
pub const EnchantmentInstance = enchantment.EnchantmentInstance;
pub const Category = enchantment.Category;
pub const Slot = enchantment.Slot;
pub const SlotSet = enchantment.SlotSet;
pub const Source = enchantment.Source;
pub const MAX_ENCHANTMENT_ID = enchantment.MAX_ENCHANTMENT_ID;

pub const storage = @import("storage.zig");
pub const EnchantmentStorage = storage.EnchantmentStorage;
pub const MergeMode = storage.MergeMode;
pub const SetResult = storage.SetResult;
pub const MAX_ENCHANTMENTS = storage.MAX_ENCHANTMENTS;

pub const set = @import("set.zig");
pub const EnchantmentSet = set.EnchantmentSet;

pub const registry = @import("registry.zig");
pub const Registry = registry.Registry;
pub const load = registry.load;
pub const ensureGlobal = registry.ensureGlobal;

pub fn getRegistry() ?*const Registry {
    return registry.ensureGlobal();
}

pub const rules = @import("rules.zig");
pub const Reject = rules.Reject;
pub const Options = rules.Options;
pub const Rule = rules.Rule;
pub const Verdict = rules.Verdict;
pub const registerRule = rules.registerRule;
pub const unregisterOwner = rules.unregisterOwner;

pub const nbt = @import("nbt.zig");
pub const ops = @import("ops.zig");
pub const Outcome = ops.Outcome;

pub const compat = @import("compat.zig");
pub const ArmorAggregate = compat.ArmorAggregate;

// Tests live in sibling files: zig build test collects none from root.zig.

pub const effects = @import("effects.zig");
pub const MeleeImpact = effects.MeleeImpact;
pub const Family = effects.Family;

