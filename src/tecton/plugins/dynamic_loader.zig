const std = @import("std");
const builtin = @import("builtin");
pub const abi = @import("abi.zig");

const NativeHandle = if (builtin.os.tag == .windows) ?*anyopaque else ?*anyopaque;

const native = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(handle: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(handle: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
} else struct {
    extern "dl" fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
    extern "dl" fn dlclose(handle: *anyopaque) c_int;
    extern "dl" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
};

pub const Error = error{
    OpenFailed,
    SymbolNotFound,
    InvalidPlugin,
    UnsupportedPlatform,
};

pub const SharedLibrary = struct {
    handle: NativeHandle,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SharedLibrary {
        const zero_terminated = try allocator.dupeZ(u8, path);
        defer allocator.free(zero_terminated);
        if (builtin.os.tag == .windows) {
            const handle = native.LoadLibraryA(zero_terminated.ptr) orelse return error.OpenFailed;
            return .{ .handle = handle };
        }
        const handle = native.dlopen(zero_terminated.ptr, 2) orelse return error.OpenFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: *SharedLibrary) void {
        if (self.handle) |handle| {
            if (builtin.os.tag == .windows) {
                _ = native.FreeLibrary(handle);
            } else {
                _ = native.dlclose(handle);
            }
            self.handle = null;
        }
    }

    pub fn symbol(self: *const SharedLibrary, comptime T: type, allocator: std.mem.Allocator, name: []const u8) !T {
        const zero_terminated = try allocator.dupeZ(u8, name);
        defer allocator.free(zero_terminated);
        const address = if (builtin.os.tag == .windows)
            native.GetProcAddress(self.handle.?, zero_terminated.ptr)
        else
            native.dlsym(self.handle.?, zero_terminated.ptr);
        const ptr = address orelse return error.SymbolNotFound;
        return @ptrCast(ptr);
    }
};

pub const NativePlugin = struct {
    allocator: std.mem.Allocator,
    library: SharedLibrary,
    descriptor: *const abi.Descriptor,
    context: *abi.Context,
    loaded: bool = false,
    started: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, host: *const abi.HostApi, plugin_id: u32, protocol: u32) !NativePlugin {
        var library = try SharedLibrary.open(allocator, path);
        errdefer library.close();

        const get_descriptor = library.symbol(abi.GetDescriptorFn, allocator, "tecton_plugin_get_descriptor") catch return error.InvalidPlugin;
        const descriptor = get_descriptor(abi.abi_major, abi.descriptor_query_minor) orelse return error.InvalidPlugin;
        abi.validateDescriptor(descriptor, protocol) catch return error.InvalidPlugin;

        const context = try allocator.create(abi.Context);
        errdefer allocator.destroy(context);
        context.* = .{ .struct_size = @sizeOf(abi.Context), .plugin_id = plugin_id, .host = host };
        return .{
            .allocator = allocator,
            .library = library,
            .descriptor = descriptor,
            .context = context,
        };
    }

    pub fn start(self: *NativePlugin) !void {
        if (self.loaded) return;

        const on_load = self.descriptor.on_load.?;
        if (on_load(self.context) != 0) return error.CallbackFailed;
        self.loaded = true;
        const on_start = self.descriptor.on_start.?;
        if (on_start(self.context) != 0) {
            self.shutdown(.fault);
            return error.CallbackFailed;
        }

        self.started = true;
    }

    pub fn shutdown(self: *NativePlugin, reason: abi.ShutdownReason) void {
        if (self.started) {
            self.descriptor.on_shutdown.?(self.context, @intFromEnum(reason));
            self.started = false;
        }
        if (self.loaded) {
            self.descriptor.on_unload.?(self.context);
            self.loaded = false;
        }
    }

    pub fn deinit(self: *NativePlugin) void {
        self.shutdown(.shutdown);
        self.allocator.destroy(self.context);
        self.library.close();
    }
};

test "native loader rejects a nonexistent library" {
    if (builtin.os.tag == .windows) return;
    try std.testing.expectError(error.OpenFailed, SharedLibrary.open(std.testing.allocator, "missing-tecton-plugin.so"));
}
