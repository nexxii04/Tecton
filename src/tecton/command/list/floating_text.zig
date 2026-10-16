const std = @import("std");

const Protocol = @import("protocol");

const registration = @import("floating_text_registration.zig");
const output = @import("floating_text_output.zig");
const CommandRegistry = @import("../registry.zig").CommandRegistry;
const handlers = @import("floating_text_handlers.zig");

pub const handle = handlers.handle;
pub const handleAdd = handlers.handleAdd;
pub const handleEdit = handlers.handleEdit;
pub const handleRemove = handlers.handleRemove;
pub const handleList = handlers.handleList;
pub const handleInfo = handlers.handleInfo;
pub const findManager = handlers.findManager;
pub const writeDimensionHolograms = handlers.writeDimensionHolograms;

const text_args = @import("floating_text_args.zig");
pub const PERMISSION = text_args.PERMISSION;
pub const MAX_NAME_LENGTH = text_args.MAX_NAME_LENGTH;
pub const MAX_TEXT_LENGTH = text_args.MAX_TEXT_LENGTH;
pub const AddArgs = text_args.AddArgs;
pub const NameError = text_args.NameError;
pub const AddArgsError = text_args.AddArgsError;
pub const TextError = text_args.TextError;
pub const hasValidNameCharacters = text_args.has_valid_name_characters;
pub const validateText = text_args.validate_text;
pub const parseAddArgs = text_args.parse_add_args;
pub const parseRemoveArgs = text_args.parse_remove_args;
const writeHologramLine = text_args.write_hologram_line;

pub fn register(registry: *CommandRegistry) !void {
    try registration.register(registry, .{
        .handle = &handlers.handle,
        .add = &handlers.handleAdd,
        .edit = &handlers.handleEdit,
        .remove = &handlers.handleRemove,
        .list = &handlers.handleList,
        .info = &handlers.handleInfo,
    });
}

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Protocol = test_owner.Protocol;
    pub const CommandRegistry = test_owner.CommandRegistry;
    pub const MAX_NAME_LENGTH = test_owner.MAX_NAME_LENGTH;
    pub const MAX_TEXT_LENGTH = test_owner.MAX_TEXT_LENGTH;
    pub const hasValidNameCharacters = test_owner.hasValidNameCharacters;
    pub const validateText = test_owner.validateText;
    pub const parseAddArgs = test_owner.parseAddArgs;
    pub const parseRemoveArgs = test_owner.parseRemoveArgs;
    pub const register = test_owner.register;
    pub const writeHologramLine = test_owner.writeHologramLine;
    pub const output = test_owner.output;
    pub const handle = test_owner.handle;
    pub const handle_add = test_owner.handleAdd;
    pub const handle_edit = test_owner.handleEdit;
    pub const handle_remove = test_owner.handleRemove;
    pub const handle_list = test_owner.handleList;
    pub const handle_info = test_owner.handleInfo;
};

test "parseAddArgs keeps free text with spaces and color codes" {
    try @import("floating_text_test.zig").Suite(test_scope).case_000();
}

test "parseAddArgs rejects missing and oversized pieces" {
    try @import("floating_text_test.zig").Suite(test_scope).case_001();
}

test "parseAddArgs rejects names with unsafe characters" {
    try @import("floating_text_test.zig").Suite(test_scope).case_002();
}

test "parseRemoveArgs reads a single name" {
    try @import("floating_text_test.zig").Suite(test_scope).case_003();
}

test "validateText accepts line breaks and color codes only" {
    try @import("floating_text_test.zig").Suite(test_scope).case_004();
}

test "escaped line breaks become real nametag lines" {
    try @import("floating_text_test.zig").Suite(test_scope).case_005();
}

test "register wires the hologram name enum into the name arguments" {
    try @import("floating_text_test.zig").Suite(test_scope).case_006();
}

test "listing line reports name, position and viewers" {
    try @import("floating_text_test.zig").Suite(test_scope).case_007();
}

test "edit rejects text that decodes into blank lines" {
    try @import("floating_text_test.zig").Suite(test_scope).case_008();
}

test "floating text diagnostics retain their exact output" {
    try @import("floating_text_test.zig").Suite(test_scope).case_009();
}
