const std = @import("std");
const Protocol = @import("protocol");

pub const PERMISSION: []const u8 = "tecton.command.floatingtext";
pub const MAX_NAME_LENGTH: usize = 32;
pub const MAX_TEXT_LENGTH: usize = 1024;

pub const AddArgs = struct {
    name: []const u8,
    text: []const u8,
};

pub const NameError = error{
    MissingName,
    InvalidName,
    NameTooLong,
};

pub const AddArgsError = NameError || error{
    MissingText,
    TextTooLong,
};

pub const TextError = error{
    EmptyText,
    InvalidText,
};

pub fn has_valid_name_characters(name: []const u8) bool {
    for (name) |byte| {
        const is_alpha = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
        const is_digit = byte >= '0' and byte <= '9';
        if (!is_alpha and !is_digit and byte != '_' and byte != '-' and byte != '.') return false;
    }
    return true;
}

pub fn validate_text(text: []const u8) TextError!void {
    var has_content = false;
    for (text) |byte| {
        if (byte == 0x7f) return error.InvalidText;
        if (byte < 0x20) {
            if (byte != '\n') return error.InvalidText;
            continue;
        }
        if (byte != ' ') has_content = true;
    }
    if (!has_content) return error.EmptyText;
}

pub fn parse_add_args(args: []const u8) AddArgsError!AddArgs {
    const trimmed = std.mem.trimStart(u8, args, " ");
    const name_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.MissingName;
    const name = trimmed[0..name_end];
    const text = std.mem.trim(u8, trimmed[name_end + 1 ..], " ");

    if (name.len == 0) return error.MissingName;
    if (name.len > MAX_NAME_LENGTH) return error.NameTooLong;
    if (!has_valid_name_characters(name)) return error.InvalidName;
    if (text.len == 0) return error.MissingText;
    if (text.len > MAX_TEXT_LENGTH) return error.TextTooLong;

    return .{ .name = name, .text = text };
}

pub fn parse_remove_args(args: []const u8) NameError![]const u8 {
    const trimmed = std.mem.trim(u8, args, " ");
    const name_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const name = trimmed[0..name_end];

    if (name.len == 0) return error.MissingName;
    if (name.len > MAX_NAME_LENGTH) return error.NameTooLong;
    if (!has_valid_name_characters(name)) return error.InvalidName;

    return name;
}

pub fn write_hologram_line(writer: *std.Io.Writer, name: []const u8, position: Protocol.Vector3f, viewers: usize) !void {
    try std.Io.Writer.print(writer, "\n  §b{s}§r §8- §a{d:.1}§7,§a{d:.1}§7,§a{d:.1}§r §8(§7viewers: §f{d}§8)", .{
        name,
        position.x,
        position.y,
        position.z,
        viewers,
    });
}
