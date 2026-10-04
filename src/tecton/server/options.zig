pub const ServerPaths = struct {
    worlds: []const u8 = "worlds",
    plugins: []const u8 = "plugins",
    banned_players: []const u8 = "banned-players.json",
    permissions: []const u8 = "permissions.json",
    player_locations: []const u8 = "player_locations.json",
};

pub const CommandPermissionChecker = *const fn (?*anyopaque, []const u8, []const u8) bool;

pub const ServerOptions = struct {
    paths: ServerPaths = .{},
    enable_console: bool = true,
    discover_native_plugins: bool = true,
    auto_load_worlds: bool = true,
    create_default_world: bool = true,
    tick_callback: ?*const fn (?*anyopaque) void = null,
    tick_userdata: ?*anyopaque = null,
    prepare_callback: ?*const fn (?*anyopaque) void = null,
    start_callback: ?*const fn (?*anyopaque) void = null,
    shutdown_callback: ?*const fn (?*anyopaque) void = null,
    lifecycle_userdata: ?*anyopaque = null,
    command_permission_checker: ?CommandPermissionChecker = null,
    command_permission_userdata: ?*anyopaque = null,
};
