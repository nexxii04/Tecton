const CommandPermission = @import("permission.zig").CommandPermission;

pub const CommandResult = struct {
    success: bool,
    message: []const u8,
};

pub fn permissionToString(perm: CommandPermission) []const u8 {
    _ = perm;
    return "any";
}
