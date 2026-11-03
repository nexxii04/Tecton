const std = @import("std");
const builtin = @import("builtin");
pub const abi = @import("abi.zig");

const NativeHandle = if (builtin.os.tag == .windows) ?*anyopaque else ?*anyopaque;

const rtl_local: c_int = if (builtin.os.tag == .macos) 4 else 0;

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
    SymbolMissing,
    LegacyAbi,
    AbiMajor,
    AbiMinor,
    HostTooOld,
    BuildTarget,
    FingerprintMismatch,
    Descriptor,
    Metadata,
    RequiredFeature,
    MissingCallback,
    CallbackFailed,
    OutOfMemory,
};

pub fn reasonCode(err: Error) u32 {
    return switch (err) {
        error.OpenFailed => abi.load_dlopen,
        error.SymbolMissing => abi.load_symbol_missing,
        error.LegacyAbi => abi.load_legacy_abi,
        error.AbiMajor => abi.load_abi_major,
        error.AbiMinor => abi.load_abi_minor,
        error.HostTooOld, error.BuildTarget => abi.load_abi_major,
        error.FingerprintMismatch => abi.load_fingerprint,
        error.Descriptor => abi.load_descriptor,
        error.Metadata => abi.load_metadata,
        error.RequiredFeature => abi.load_required_feature,
        error.MissingCallback => abi.load_missing_callback,
        error.CallbackFailed => abi.load_callback_failed,
        error.OutOfMemory => abi.load_out_of_memory,
    };
}

pub fn reasonName(err: Error) []const u8 {
    return reasonNameCode(reasonCode(err));
}

pub fn reasonNameCode(code: u32) []const u8 {
    return switch (code) {
        abi.load_ok => "ok",
        abi.load_dlopen => "dlopen",
        abi.load_symbol_missing => "symbol_missing",
        abi.load_legacy_abi => "legacy_abi",
        abi.load_abi_major => "abi_major",
        abi.load_abi_minor => "abi_minor",
        abi.load_fingerprint => "fingerprint",
        abi.load_descriptor => "descriptor",
        abi.load_metadata => "metadata",
        abi.load_duplicate_name => "duplicate_name",
        abi.load_required_feature => "required_feature",
        abi.load_missing_callback => "missing_callback",
        abi.load_callback_failed => "callback_failed",
        abi.load_out_of_memory => "out_of_memory",
        else => "unknown",
    };
}

pub const SharedLibrary = struct {
    handle: NativeHandle,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) error{ OpenFailed, OutOfMemory }!SharedLibrary {
        const zero_terminated = try allocator.dupeZ(u8, path);
        defer allocator.free(zero_terminated);
        if (builtin.os.tag == .windows) {
            const handle = native.LoadLibraryA(zero_terminated.ptr) orelse return error.OpenFailed;
            return .{ .handle = handle };
        }
        const handle = native.dlopen(zero_terminated.ptr, 2 | rtl_local) orelse return error.OpenFailed;
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

    pub fn rawSymbol(self: *const SharedLibrary, name: [:0]const u8) ?*anyopaque {
        const handle = self.handle orelse return null;
        return if (builtin.os.tag == .windows)
            native.GetProcAddress(handle, name.ptr)
        else
            native.dlsym(handle, name.ptr);
    }

    pub fn symbol(self: *const SharedLibrary, comptime T: type, name: [:0]const u8) ?T {
        const address = self.rawSymbol(name) orelse return null;
        return @ptrCast(address);
    }
};

pub const NativePlugin = struct {
    allocator: std.mem.Allocator,
    library: SharedLibrary,
    descriptor: *const abi.Descriptor,
    context: *abi.Context,
    loaded: bool = false,
    load_attempted: bool = false,
    unload_called: bool = false,
    started: bool = false,
    start_attempted: bool = false,
    shutdown_called: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, host: *const abi.HostApi, plugin_id: u32) Error!NativePlugin {
        var library = try SharedLibrary.open(allocator, path);
        errdefer library.close();

        const query = library.symbol(abi.QueryFn, "tecton_plugin_query") orelse {
            if (library.rawSymbol("tecton_plugin_get_descriptor") != null) return error.LegacyAbi;
            return error.SymbolMissing;
        };

        var host_query = abi.hostQuery(host.features);
        var info = abi.PluginInfo{
            .struct_size = @sizeOf(abi.PluginInfo),
            .status = abi.plugin_status_abi_major,
            .abi_major = 0,
            .abi_minor = 0,
            .abi_fingerprint = 0,
            .descriptor = null,
            .diagnostic = .{},
            .reserved = 0,
        };
        _ = query(&host_query, &info);
        abi.validateQuery(&host_query, &info) catch |err| return mapError(err);
        const descriptor = info.descriptor.?;
        abi.validateDescriptor(descriptor, host.features) catch |err| return mapError(err);

        const context = try allocator.create(abi.Context);
        errdefer allocator.destroy(context);
        context.* = .{
            .struct_size = @sizeOf(abi.Context),
            .plugin_id = plugin_id,
            .host = host,
            .engine = null,
            .reserved = 0,
        };
        return .{
            .allocator = allocator,
            .library = library,
            .descriptor = descriptor,
            .context = context,
        };
    }

    pub fn load(self: *NativePlugin) Error!void {
        if (self.loaded) return;
        const on_load = self.descriptor.on_load orelse return error.MissingCallback;
        self.load_attempted = true;
        if (on_load(self.context) != 0) return error.CallbackFailed;
        self.loaded = true;
    }

    pub fn start(self: *NativePlugin) Error!void {
        if (self.started) return;
        const on_start = self.descriptor.on_start orelse return error.MissingCallback;
        self.start_attempted = true;
        self.shutdown_called = false;
        if (on_start(self.context) != 0) return error.CallbackFailed;
        self.started = true;
    }

    pub fn ready(self: *NativePlugin) void {
        if (!self.started) return;
        if (self.descriptor.on_ready) |on_ready| on_ready(self.context);
    }

    pub fn shutdown(self: *NativePlugin, reason: abi.ShutdownReason) void {
        if (!self.start_attempted or self.shutdown_called) return;
        if (self.descriptor.on_shutdown) |on_shutdown| on_shutdown(self.context, @intFromEnum(reason));
        self.shutdown_called = true;
        self.started = false;
    }

    pub fn unload(self: *NativePlugin) void {
        if (!self.load_attempted or self.unload_called) return;
        if (self.descriptor.on_unload) |on_unload| on_unload(self.context);
        self.unload_called = true;
        self.loaded = false;
    }

    pub fn deinit(self: *NativePlugin) void {
        self.shutdown(.normal);
        self.unload();
        self.allocator.destroy(self.context);
        self.library.close();
    }

    fn mapError(err: abi.Error) Error {
        return switch (err) {
            error.InvalidArgument => error.Descriptor,
            error.AbiMajor => error.AbiMajor,
            error.AbiMinor => error.AbiMinor,
            error.HostTooOld => error.HostTooOld,
            error.BuildTarget => error.BuildTarget,
            error.Fingerprint => error.FingerprintMismatch,
            error.Descriptor => error.Descriptor,
            error.Metadata => error.Metadata,
            error.RequiredFeature => error.RequiredFeature,
            error.MissingCallback => error.MissingCallback,
            error.CallbackFailed => error.CallbackFailed,
        };
    }
};

test "native loader rejects a nonexistent library" {
    if (builtin.os.tag == .windows) return;
    try std.testing.expectError(error.OpenFailed, SharedLibrary.open(std.testing.allocator, "missing-tecton-plugin.so"));
}
