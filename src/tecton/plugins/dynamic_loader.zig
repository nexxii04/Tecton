const std = @import("std");
const builtin = @import("builtin");
pub const abi = @import("abi.zig");

const NativeHandle = if (builtin.os.tag == .windows) ?*anyopaque else ?*anyopaque;

const rtl_local: c_int = if (builtin.os.tag == .macos) 4 else 0;

const native = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(handle: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(handle: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
} else struct {
    extern "dl" fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
    extern "dl" fn dlclose(handle: *anyopaque) c_int;
    extern "dl" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
    extern "dl" fn dlerror() ?[*:0]const u8;
};

pub const LoadResult = struct {
    reason: u32 = abi.load_ok,
    abi_major: u16 = 0,
    abi_minor: u16 = 0,
    fingerprint: u64 = 0,
    detail: [128]u8 = @splat(0),
    detail_len: u8 = 0,

    pub fn set(self: *LoadResult, reason: u32, detail: []const u8) void {
        self.reason = reason;
        const length = @min(detail.len, self.detail.len);
        if (length > 0) @memcpy(self.detail[0..length], detail[0..length]);
        self.detail_len = @intCast(length);
    }

    pub fn detailSlice(self: *const LoadResult) []const u8 {
        return self.detail[0..self.detail_len];
    }
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
    return abi.loadReasonName(reasonCode(err));
}

pub fn reasonNameCode(code: u32) []const u8 {
    return abi.loadReasonName(code);
}

pub const SharedLibrary = struct {
    handle: NativeHandle,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) error{ OpenFailed, OutOfMemory }!SharedLibrary {
        var result: LoadResult = .{};
        return openDetailed(allocator, path, &result);
    }

    pub fn openDetailed(allocator: std.mem.Allocator, path: []const u8, result: *LoadResult) error{ OpenFailed, OutOfMemory }!SharedLibrary {
        const zero_terminated = allocator.allocSentinel(u8, path.len, 0) catch {
            result.set(abi.load_out_of_memory, "path allocation");
            return error.OutOfMemory;
        };
        @memcpy(zero_terminated, path);
        defer allocator.free(zero_terminated);
        if (builtin.os.tag == .windows) {
            const handle = native.LoadLibraryA(zero_terminated.ptr) orelse {
                var buffer: [64]u8 = undefined;
                const detail = std.fmt.bufPrint(&buffer, "LoadLibraryA error {d}", .{native.GetLastError()}) catch "LoadLibraryA failed";
                result.set(abi.load_dlopen, detail);
                return error.OpenFailed;
            };
            return .{ .handle = handle };
        }
        const handle = native.dlopen(zero_terminated.ptr, 2 | rtl_local) orelse {
            const message = native.dlerror();
            result.set(abi.load_dlopen, if (message) |text| std.mem.span(text) else "dlopen failed");
            return error.OpenFailed;
        };
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
    abi_major: u16 = 0,
    abi_minor: u16 = 0,
    fingerprint: u64 = 0,
    required_features: u64 = 0,
    optional_features: u64 = 0,
    loaded: bool = false,
    load_attempted: bool = false,
    unload_called: bool = false,
    started: bool = false,
    start_attempted: bool = false,
    shutdown_called: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, host: *const abi.HostApi, plugin_id: u32) Error!NativePlugin {
        var result: LoadResult = .{};
        return openDetailed(allocator, path, host, plugin_id, &result);
    }

    pub fn openDetailed(allocator: std.mem.Allocator, path: []const u8, host: *const abi.HostApi, plugin_id: u32, result: *LoadResult) Error!NativePlugin {
        result.* = .{};
        var library = SharedLibrary.openDetailed(allocator, path, result) catch |err| return err;
        errdefer library.close();

        const query = library.symbol(abi.QueryFn, "tecton_plugin_query") orelse {
            if (library.rawSymbol("tecton_plugin_get_descriptor") != null) {
                result.set(abi.load_legacy_abi, "tecton_plugin_get_descriptor");
                return error.LegacyAbi;
            }
            result.set(abi.load_symbol_missing, "tecton_plugin_query");
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
        result.abi_major = @truncate(info.abi_major);
        result.abi_minor = @truncate(info.abi_minor);
        result.fingerprint = info.abi_fingerprint;
        abi.validateQuery(&host_query, &info) catch |err| {
            const mapped = mapError(err);
            result.set(reasonCode(mapped), @errorName(err));
            return mapped;
        };
        const descriptor = info.descriptor.?;
        abi.validateDescriptor(descriptor, host.features) catch |err| {
            const mapped = mapError(err);
            result.set(reasonCode(mapped), @errorName(err));
            return mapped;
        };

        const context = allocator.create(abi.Context) catch {
            result.set(abi.load_out_of_memory, "context allocation");
            return error.OutOfMemory;
        };
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
            .abi_major = @intCast(info.abi_major),
            .abi_minor = @intCast(info.abi_minor),
            .fingerprint = info.abi_fingerprint,
            .required_features = descriptor.metadata.required_features,
            .optional_features = descriptor.metadata.optional_features,
        };
    }

    pub fn load(self: *NativePlugin) Error!void {
        return self.loadWithDetail(null);
    }

    pub fn loadWithDetail(self: *NativePlugin, result: ?*LoadResult) Error!void {
        if (self.loaded) return;
        const on_load = self.descriptor.on_load orelse {
            if (result) |output| output.set(abi.load_missing_callback, "on_load");
            return error.MissingCallback;
        };
        self.load_attempted = true;
        if (on_load(self.context) != 0) {
            if (result) |output| output.set(abi.load_callback_failed, "on_load returned nonzero");
            return error.CallbackFailed;
        }
        self.loaded = true;
    }

    pub fn start(self: *NativePlugin) Error!void {
        return self.startWithDetail(null);
    }

    pub fn startWithDetail(self: *NativePlugin, result: ?*LoadResult) Error!void {
        if (self.started) return;
        const on_start = self.descriptor.on_start orelse {
            if (result) |output| output.set(abi.load_missing_callback, "on_start");
            return error.MissingCallback;
        };
        self.start_attempted = true;
        self.shutdown_called = false;
        if (on_start(self.context) != 0) {
            if (result) |output| output.set(abi.load_callback_failed, "on_start returned nonzero");
            return error.CallbackFailed;
        }
        self.started = true;
    }

    pub fn ready(self: *NativePlugin) void {
        if (!self.started) return;
        if (self.descriptor.on_ready) |on_ready| on_ready(self.context);
    }

    pub fn shutdown(self: *NativePlugin, reason: abi.ShutdownReason) void {
        if (!self.start_attempted or self.shutdown_called) return;
        if (self.descriptor.on_shutdown) |on_shutdown| on_shutdown(self.context, @backingInt(reason));
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
    var result: LoadResult = .{};
    try std.testing.expectError(error.OpenFailed, SharedLibrary.openDetailed(std.testing.allocator, "missing-tecton-plugin.so", &result));
    try std.testing.expectEqual(abi.load_dlopen, result.reason);
    try std.testing.expect(result.detail_len > 0);
}
