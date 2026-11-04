const std = @import("std");
const builtin = @import("builtin");
const plugin_abi = @import("src/tecton/plugins/abi.zig");

const leveldb_sources = &[_][]const u8{
    "db/builder.cc",
    "db/c.cc",
    "db/db_impl.cc",
    "db/db_iter.cc",
    "db/dbformat.cc",
    "db/dumpfile.cc",
    "db/filename.cc",
    "db/log_reader.cc",
    "db/log_writer.cc",
    "db/memtable.cc",
    "db/repair.cc",
    "db/table_cache.cc",
    "db/version_edit.cc",
    "db/version_set.cc",
    "db/write_batch.cc",
    "table/block_builder.cc",
    "table/block.cc",
    "table/filter_block.cc",
    "table/format.cc",
    "table/iterator.cc",
    "table/merger.cc",
    "table/table_builder.cc",
    "table/table.cc",
    "table/two_level_iterator.cc",
    "util/arena.cc",
    "util/bloom.cc",
    "util/cache.cc",
    "util/coding.cc",
    "util/comparator.cc",
    "util/crc32c.cc",
    "util/env.cc",
    "util/filter_policy.cc",
    "util/hash.cc",
    "util/logging.cc",
    "util/options.cc",
    "util/status.cc",
};

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.os.tag == .linux) .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } else .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
    const is_windows = target.result.os.tag == .windows;
    const is_macos = target.result.os.tag == .macos;

    const leveldb_lib = addLevelDb(b, target, zlib_dep, is_windows, is_macos);

    const binarystream_dep = b.dependency("BinaryStream", .{ .target = target, .optimize = optimize });
    const binarystream_mod = binarystream_dep.module("BinaryStream");
    const nbt_dep = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    const nbt_mod = nbt_dep.module("nbt");
    const protocol_dep = b.dependency("protocol", .{ .target = target, .optimize = optimize });
    const protocol_mod = protocol_dep.module("Protocol");

    nbt_mod.addImport("BinaryStream", binarystream_mod);
    protocol_mod.addImport("BinaryStream", binarystream_mod);

    const leveldb_mod = b.addModule("leveldb", .{ .root_source_file = b.path("libs/leveldb/leveldb.zig"), .target = target });
    const nethernet_mod = b.dependency("nethernet_zig", .{ .target = target, .optimize = optimize }).module("nethernet-zig");
    // Pin mbedTLS to the revision webrtc resolves, so the C build is shared.
    const mbedtls_dep = b.dependency("mbedtls", .{ .target = target, .optimize = .ReleaseFast });
    const mbedtls = mbedtls_dep.artifact("mbedtls");
    const mbedtls_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/tecton/server/tls_mbedtls.h"),
        .target = target,
        .optimize = optimize,
    });

    // Translate with the library's config; mbedTLS sizes its contexts from those macros.
    mirrorModule(mbedtls_translate, mbedtls.root_module);
    const mbedtls_mod = mbedtls_translate.createModule();
    const tecton_mod = b.addModule("tecton", .{ .root_source_file = b.path("src/tecton/root.zig"), .target = target });
    tecton_mod.addImport("BinaryStream", binarystream_mod);
    tecton_mod.addImport("nethernet", nethernet_mod);
    tecton_mod.addImport("mbedtls", mbedtls_mod);
    tecton_mod.linkLibrary(mbedtls);
    tecton_mod.addImport("protocol", protocol_mod);
    tecton_mod.addImport("nbt", nbt_mod);
    tecton_mod.addImport("leveldb", leveldb_mod);
    tecton_mod.linkLibrary(zlib_dep.artifact("z"));
    if (is_windows) {
        tecton_mod.linkSystemLibrary("psapi", .{});
        tecton_mod.linkSystemLibrary("ws2_32", .{});
    }

    const exe = b.addExecutable(.{
        .name = "Tecton",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "tecton", .module = tecton_mod },
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "nbt", .module = nbt_mod },
                .{ .name = "leveldb", .module = leveldb_mod },
            },
        }),
    });

    exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    exe.root_module.linkLibrary(leveldb_lib);
    exe.root_module.linkLibrary(mbedtls);
    if (is_windows) exe.root_module.linkSystemLibrary("winmm", .{});
    b.installArtifact(exe);

    const embedded_example = b.addExecutable(.{
        .name = "TectonEmbeddedExample",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embedded_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "tecton", .module = tecton_mod },
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "nbt", .module = nbt_mod },
                .{ .name = "leveldb", .module = leveldb_mod },
            },
        }),
    });
    embedded_example.root_module.linkLibrary(zlib_dep.artifact("z"));
    embedded_example.root_module.linkLibrary(leveldb_lib);
    embedded_example.root_module.linkLibrary(mbedtls);
    if (is_windows) embedded_example.root_module.linkSystemLibrary("winmm", .{});
    const embedded_example_step = b.step("embedded-example", "Build the embedded vanilla server example");
    embedded_example_step.dependOn(&embedded_example.step);

    const soak_exe = b.addExecutable(.{
        .name = "TectonSoak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/soak/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "tecton", .module = tecton_mod },
            },
        }),
    });

    soak_exe.root_module.linkLibrary(leveldb_lib);
    soak_exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    soak_exe.root_module.linkLibrary(mbedtls);

    if (is_windows) soak_exe.root_module.linkSystemLibrary("winmm", .{});
    const soak_step = b.step("soak", "Run the transport load, lifecycle and soak scenarios");
    const run_soak = b.addRunArtifact(soak_exe);
    if (b.args) |args| run_soak.addArgs(args);
    soak_step.dependOn(&run_soak.step);

    const native_example = addPluginExample(b, target, optimize);
    const native_mismatch = addTestPlugin(b, target, optimize, "tecton-c-fingerprint-mismatch", "tests/plugins/fingerprint_mismatch_plugin.c");
    const native_legacy = addTestPlugin(b, target, optimize, "tecton-c-legacy", "tests/plugins/legacy_plugin.c");
    const native_failure = addTestPlugin(b, target, optimize, "tecton-c-failure", "tests/plugins/failure_plugin.c");
    const native_no_query = addTestPlugin(b, target, optimize, "tecton-c-no-query", "tests/plugins/no_query_plugin.c");
    const native_reason_abi_major = addReasonPlugin(b, target, optimize, "tecton-c-reason-abi-major", 1);
    const native_reason_abi_minor = addReasonPlugin(b, target, optimize, "tecton-c-reason-abi-minor", 2);
    const native_reason_descriptor = addReasonPlugin(b, target, optimize, "tecton-c-reason-descriptor", 3);
    const native_reason_metadata = addReasonPlugin(b, target, optimize, "tecton-c-reason-metadata", 4);
    const native_reason_required_feature = addReasonPlugin(b, target, optimize, "tecton-c-reason-required-feature", 5);
    const native_reason_missing_callback = addReasonPlugin(b, target, optimize, "tecton-c-reason-missing-callback", 6);
    const native_trace_a = addTracePlugin(b, target, optimize, "tecton-c-trace-a", "tecton-trace-a", "a");
    const native_trace_b = addTracePlugin(b, target, optimize, "tecton-c-trace-b", "tecton-trace-b", "b");
    const native_trace_duplicate = addTracePlugin(b, target, optimize, "tecton-c-trace-duplicate", "tecton-trace-a", "d");
    const native_example_step = b.step("plugin-example", "Build the minimal C ABI plugin");
    native_example_step.dependOn(b.getInstallStep());
    native_example_step.dependOn(&native_example.step);

    const native_bench = addTestPlugin(b, target, optimize, "tecton-bench-plugin", "tests/plugins/bench_plugin.c");
    const bench_options = b.addOptions();
    bench_options.addOptionPath("plugin_path", native_bench.getEmittedBin());
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/plugins/bench_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{ .{ .name = "tecton", .module = tecton_mod }, .{ .name = "nbt", .module = nbt_mod } },
    });

    bench_mod.addOptions("bench-options", bench_options);
    const bench_exe = b.addExecutable(.{ .name = "tecton-bench-plugins", .root_module = bench_mod });
    bench_exe.root_module.linkLibrary(leveldb_lib);
    bench_exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    bench_exe.root_module.linkLibrary(mbedtls);
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(&native_bench.step);
    const bench_step = b.step("bench-plugins", "Run the plugin hot-path benchmark (measure with -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const chest_sources = b.addWriteFiles();
    _ = chest_sources.addCopyDirectory(b.path("src/tecton"), "tecton", .{ .include_extensions = &.{ ".zig", ".json" } });
    const chest_root = chest_sources.addCopyFile(b.path("tests/chest/root.zig"), "root.zig");
    const chest_test_mod = b.createModule(.{
        .root_source_file = chest_root,
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{ .{ .name = "BinaryStream", .module = binarystream_mod }, .{ .name = "nethernet", .module = nethernet_mod }, .{ .name = "mbedtls", .module = mbedtls_mod }, .{ .name = "protocol", .module = protocol_mod }, .{ .name = "nbt", .module = nbt_mod }, .{ .name = "leveldb", .module = leveldb_mod } },
    });
    chest_test_mod.linkLibrary(zlib_dep.artifact("z"));
    if (is_windows) chest_test_mod.linkSystemLibrary("psapi", .{});
    const chest_tests = b.addTest(.{ .root_module = chest_test_mod });
    chest_tests.root_module.linkLibrary(leveldb_lib);
    chest_tests.root_module.linkLibrary(zlib_dep.artifact("z"));
    chest_tests.root_module.linkLibrary(mbedtls);
    const run_chest_tests = b.addRunArtifact(chest_tests);

    const plugin_options = b.addOptions();
    plugin_options.addOptionPath("path", native_example.getEmittedBin());
    plugin_options.addOptionPath("mismatch_path", native_mismatch.getEmittedBin());
    plugin_options.addOptionPath("legacy_path", native_legacy.getEmittedBin());
    plugin_options.addOptionPath("failure_path", native_failure.getEmittedBin());
    plugin_options.addOptionPath("no_query_path", native_no_query.getEmittedBin());
    plugin_options.addOptionPath("reason_abi_major_path", native_reason_abi_major.getEmittedBin());
    plugin_options.addOptionPath("reason_abi_minor_path", native_reason_abi_minor.getEmittedBin());
    plugin_options.addOptionPath("reason_descriptor_path", native_reason_descriptor.getEmittedBin());
    plugin_options.addOptionPath("reason_metadata_path", native_reason_metadata.getEmittedBin());
    plugin_options.addOptionPath("reason_required_feature_path", native_reason_required_feature.getEmittedBin());
    plugin_options.addOptionPath("reason_missing_callback_path", native_reason_missing_callback.getEmittedBin());
    plugin_options.addOptionPath("trace_a_path", native_trace_a.getEmittedBin());
    plugin_options.addOptionPath("trace_b_path", native_trace_b.getEmittedBin());
    plugin_options.addOptionPath("trace_duplicate_path", native_trace_duplicate.getEmittedBin());
    const plugin_test_mod = b.createModule(.{ .root_source_file = b.path("tests/plugins/plugin_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const plugin_loader_mod = b.createModule(.{ .root_source_file = b.path("src/tecton/plugins/dynamic_loader.zig"), .target = target, .optimize = optimize });
    plugin_test_mod.addImport("tecton-plugin-loader", plugin_loader_mod);
    plugin_test_mod.addOptions("plugin-options", plugin_options);
    const plugin_tests = b.addTest(.{ .root_module = plugin_test_mod });
    const run_plugin_tests = b.addRunArtifact(plugin_tests);
    run_plugin_tests.step.dependOn(&native_example.step);
    run_plugin_tests.step.dependOn(&native_mismatch.step);
    run_plugin_tests.step.dependOn(&native_legacy.step);
    run_plugin_tests.step.dependOn(&native_failure.step);
    run_plugin_tests.step.dependOn(b.getInstallStep());

    const runtime_plugin_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/plugins/runtime_plugin_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "tecton", .module = tecton_mod }, .{ .name = "nbt", .module = nbt_mod } },
    });
    runtime_plugin_test_mod.addOptions("plugin-options", plugin_options);
    const runtime_plugin_tests = b.addTest(.{ .root_module = runtime_plugin_test_mod });
    runtime_plugin_tests.root_module.linkLibrary(leveldb_lib);
    runtime_plugin_tests.root_module.linkLibrary(zlib_dep.artifact("z"));
    runtime_plugin_tests.root_module.linkLibrary(mbedtls);
    const run_runtime_plugin_tests = b.addRunArtifact(runtime_plugin_tests);
    run_runtime_plugin_tests.step.dependOn(&native_failure.step);
    run_runtime_plugin_tests.step.dependOn(&native_no_query.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_abi_major.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_abi_minor.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_descriptor.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_metadata.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_required_feature.step);
    run_runtime_plugin_tests.step.dependOn(&native_reason_missing_callback.step);
    run_runtime_plugin_tests.step.dependOn(&native_trace_a.step);
    run_runtime_plugin_tests.step.dependOn(&native_trace_b.step);
    run_runtime_plugin_tests.step.dependOn(&native_trace_duplicate.step);

    const plugin_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tecton/plugins_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "BinaryStream", .module = binarystream_mod },
            .{ .name = "nethernet", .module = nethernet_mod },
            .{ .name = "mbedtls", .module = mbedtls_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "nbt", .module = nbt_mod },
            .{ .name = "leveldb", .module = leveldb_mod },
        },
    });
    plugin_unit_mod.linkLibrary(leveldb_lib);
    plugin_unit_mod.linkLibrary(zlib_dep.artifact("z"));
    plugin_unit_mod.linkLibrary(mbedtls);
    const plugin_unit_tests = b.addTest(.{ .root_module = plugin_unit_mod });
    const run_plugin_unit_tests = b.addRunArtifact(plugin_unit_tests);
    const plugin_unit_step = b.step("test-plugins", "Run plugin runtime unit tests");
    plugin_unit_step.dependOn(&run_plugin_unit_tests.step);

    const conformance = addPluginConformance(b, target, optimize);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_chest_tests.step);
    test_step.dependOn(&run_plugin_tests.step);
    test_step.dependOn(&run_runtime_plugin_tests.step);
    test_step.dependOn(&run_plugin_unit_tests.step);
    test_step.dependOn(conformance);
    const chest_test_step = b.step("test-chest", "Run chest regression tests");
    chest_test_step.dependOn(&run_chest_tests.step);
}

/// Copies include dirs and macros so translate-c matches the compiled library.
fn mirrorModule(translate_c: *std.Build.Step.TranslateC, from: *std.Build.Module) void {
    for (from.include_dirs.items) |include_dir| switch (include_dir) {
        .path => |path| translate_c.addIncludePath(path),
        .path_system => |path| translate_c.addSystemIncludePath(path),
        .path_after => |path| translate_c.addAfterIncludePath(path),
        .config_header_step => |header| translate_c.addConfigHeader(header),
        .other_step => |comp| if (comp.installed_headers_include_tree) |tree|
            translate_c.addIncludePath(tree.getDirectory()),
        else => {},
    };
    for (from.c_macros.items) |macro| {
        // Module stores `-DNAME=VALUE`; translate-c adds the `-D` itself.
        const definition = if (std.mem.startsWith(u8, macro, "-D")) macro[2..] else macro;
        translate_c.defineCMacroRaw(definition);
    }
}

fn addLevelDb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zlib_dep: *std.Build.Dependency,
    is_windows: bool,
    is_macos: bool,
) *std.Build.Step.Compile {
    const leveldb_lib = b.addLibrary(.{
        .name = "leveldb",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libcpp = true }),
    });

    leveldb_lib.root_module.addIncludePath(b.path("libs/leveldb/src"));
    leveldb_lib.root_module.addIncludePath(b.path("libs/leveldb/src/include"));
    leveldb_lib.root_module.linkLibrary(zlib_dep.artifact("z"));

    const platform_flags: []const []const u8 = if (is_windows)
        &.{ "-std=c++17", "-DLEVELDB_PLATFORM_WINDOWS", "-D_UNICODE", "-DUNICODE", "-DWIN32_LEAN_AND_MEAN", "-DNOMINMAX" }
    else if (is_macos)
        &.{ "-std=c++17", "-DLEVELDB_PLATFORM_POSIX", "-DHAVE_FULLFSYNC=1", "-DHAVE_O_CLOEXEC=1" }
    else
        &.{ "-std=c++17", "-DLEVELDB_PLATFORM_POSIX", "-DHAVE_FDATASYNC=1", "-DHAVE_O_CLOEXEC=1" };
    for (leveldb_sources) |src| leveldb_lib.root_module.addCSourceFile(.{ .file = b.path(b.fmt("libs/leveldb/src/{s}", .{src})), .flags = platform_flags });
    const env_file: []const u8 = if (is_windows) "util/env_windows.cc" else "util/env_posix.cc";
    leveldb_lib.root_module.addCSourceFile(.{ .file = b.path(b.fmt("libs/leveldb/src/{s}", .{env_file})), .flags = platform_flags });
    b.installArtifact(leveldb_lib);
    return leveldb_lib;
}

fn addPluginExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const native_example = addTestPlugin(b, target, optimize, "tecton-c-example", "tests/plugins/minimal_plugin.c");
    b.installArtifact(native_example);
    return native_example;
}

fn addTestPlugin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const plugin = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    plugin.root_module.addIncludePath(b.path("include"));
    plugin.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{"-std=c11"} });
    return plugin;
}

fn addTracePlugin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    trace_name: []const u8,
    label: []const u8,
) *std.Build.Step.Compile {
    const plugin = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    plugin.root_module.addIncludePath(b.path("include"));
    plugin.root_module.addCSourceFile(.{ .file = b.path("tests/plugins/trace_plugin.c"), .flags = &.{
        "-std=c11",
        b.fmt("-DTECTON_TRACE_NAME=\"{s}\"", .{trace_name}),
        b.fmt("-DTECTON_TRACE_LABEL=\"{s}\"", .{label}),
    } });
    return plugin;
}

fn addReasonPlugin(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    reason_case: u32,
) *std.Build.Step.Compile {
    const plugin = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    plugin.root_module.addIncludePath(b.path("include"));
    plugin.root_module.addCSourceFile(.{ .file = b.path("tests/plugins/reason_plugin.c"), .flags = &.{
        "-std=c11",
        b.fmt("-DTECTON_REASON_CASE={d}", .{reason_case}),
    } });
    return plugin;
}

fn addPluginConformance(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const generated = b.addWriteFiles();
    _ = generated.add("abi_layout_expected.h", expectedLayoutHeader(b) catch @panic("OOM"));

    const probe = b.addExecutable(.{
        .name = "abi-layout-probe",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    probe.root_module.addIncludePath(b.path("include"));
    probe.root_module.addIncludePath(generated.getDirectory());
    probe.root_module.addCSourceFile(.{ .file = b.path("tests/plugins/abi_layout_probe.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic" } });
    const run_probe = b.addRunArtifact(probe);

    const cpp_check = b.addObject(.{
        .name = "abi-header-cpp-check",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    cpp_check.root_module.addIncludePath(b.path("include"));
    cpp_check.root_module.addCSourceFile(.{ .file = b.path("tests/plugins/abi_header_check.cpp"), .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-Wpedantic" } });

    const step = b.step("plugin-conformance", "Compile and run the ABI layout probe");
    step.dependOn(&run_probe.step);
    step.dependOn(&cpp_check.step);
    return step;
}

const layout_types = .{
    .{ "tecton_string_view", plugin_abi.StringView },
    .{ "tecton_api_version", plugin_abi.ApiVersion },
    .{ "tecton_host_query", plugin_abi.HostQuery },
    .{ "tecton_plugin_info", plugin_abi.PluginInfo },
    .{ "tecton_plugin_metadata", plugin_abi.Metadata },
    .{ "tecton_plugin_descriptor", plugin_abi.Descriptor },
    .{ "tecton_plugin_context", plugin_abi.Context },
    .{ "tecton_allocator", plugin_abi.Allocator },
    .{ "tecton_host_api", plugin_abi.HostApi },
    .{ "tecton_interface_header", plugin_abi.InterfaceHeader },
    .{ "tecton_event_view", plugin_abi.EventView },
    .{ "tecton_server_tick_event", plugin_abi.ServerTickEvent },
    .{ "tecton_player_event", plugin_abi.PlayerEvent },
    .{ "tecton_player_join_event", plugin_abi.PlayerJoinEvent },
    .{ "tecton_player_ref_event", plugin_abi.PlayerRefEvent },
    .{ "tecton_player_chat_event", plugin_abi.PlayerChatEvent },
    .{ "tecton_item_use_event", plugin_abi.ItemUseEvent },
    .{ "tecton_player_move_event", plugin_abi.PlayerMoveEvent },
    .{ "tecton_damage_event", plugin_abi.DamageEvent },
    .{ "tecton_block_place_event", plugin_abi.BlockPlaceEvent },
    .{ "tecton_block_break_event", plugin_abi.BlockBreakEvent },
    .{ "tecton_inventory_event", plugin_abi.InventoryEvent },
    .{ "tecton_inventory_click_event", plugin_abi.InventoryClickEvent },
    .{ "tecton_transaction_event", plugin_abi.TransactionEvent },
    .{ "tecton_entity_combust_event", plugin_abi.EntityCombustEvent },
    .{ "tecton_enchant_event", plugin_abi.EnchantEvent },
    .{ "tecton_entity_spawn_event", plugin_abi.EntitySpawnEvent },
    .{ "tecton_entity_despawn_event", plugin_abi.EntityDespawnEvent },
    .{ "tecton_entity_damage_event", plugin_abi.EntityDamageEvent },
    .{ "tecton_entity_death_event", plugin_abi.EntityDeathEvent },
    .{ "tecton_entity_interact_event", plugin_abi.EntityInteractEvent },
    .{ "tecton_snapshot_header", plugin_abi.SnapshotHeader },
    .{ "tecton_world_snapshot", plugin_abi.WorldSnapshot },
    .{ "tecton_player_snapshot", plugin_abi.PlayerSnapshot },
    .{ "tecton_block_box", plugin_abi.BlockBox },
    .{ "tecton_entity_snapshot", plugin_abi.EntitySnapshot },
    .{ "tecton_item_snapshot", plugin_abi.ItemSnapshot },
    .{ "tecton_block_snapshot", plugin_abi.BlockSnapshot },
    .{ "tecton_inventory_item_snapshot", plugin_abi.InventoryItemSnapshot },
    .{ "tecton_world_api", plugin_abi.WorldApi },
    .{ "tecton_players_api", plugin_abi.PlayersApi },
    .{ "tecton_entities_api", plugin_abi.EntitiesApi },
    .{ "tecton_items_api", plugin_abi.ItemsApi },
    .{ "tecton_blocks_api", plugin_abi.BlocksApi },
    .{ "tecton_inventories_api", plugin_abi.InventoriesApi },
    .{ "tecton_core_api", plugin_abi.CoreApi },
    .{ "tecton_scheduler_api", plugin_abi.SchedulerApi },
    .{ "tecton_network_api", plugin_abi.NetworkApi },
    .{ "tecton_logging_api", plugin_abi.LoggingApi },
    .{ "tecton_events_api", plugin_abi.EventsApi },
    .{ "tecton_registry_view", plugin_abi.RegistryView },
    .{ "tecton_block_state_entry", plugin_abi.BlockStateEntry },
    .{ "tecton_item_entry", plugin_abi.ItemEntry },
    .{ "tecton_entity_type_entry", plugin_abi.EntityTypeEntry },
    .{ "tecton_registries_api", plugin_abi.RegistriesApi },
    .{ "tecton_command_desc", plugin_abi.CommandDesc },
    .{ "tecton_command_call", plugin_abi.CommandCall },
    .{ "tecton_commands_api", plugin_abi.CommandsApi },
};

fn expectedLayoutHeader(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "#ifndef TECTON_ABI_LAYOUT_EXPECTED_H\n#define TECTON_ABI_LAYOUT_EXPECTED_H\n#include <stddef.h>\n#include <stdint.h>\n#include <stdio.h>\n");
    const fingerprint = try std.fmt.allocPrint(allocator, "#define TECTON_ABI_EXPECTED_FINGERPRINT UINT64_C(0x{x})\n", .{plugin_abi.abi_fingerprint});
    try out.appendSlice(allocator, fingerprint);
    try out.appendSlice(allocator, "#define TECTON_ABI_EXPECT_SIZE(type, expected) TECTON_STATIC_ASSERT(sizeof(type) == (expected), #type \" sizeof drift\")\n#define TECTON_ABI_EXPECT_OFFSET(type, field, expected) TECTON_STATIC_ASSERT(offsetof(type, field) == (expected), #type \".\" #field \" offset drift\")\n");
    inline for (layout_types) |entry| {
        const line = try std.fmt.allocPrint(allocator, "TECTON_ABI_EXPECT_SIZE({s}, {d});\n", .{ entry[0], @sizeOf(entry[1]) });
        try out.appendSlice(allocator, line);
        inline for (@typeInfo(entry[1]).@"struct".fields) |field| {
            const offset = try std.fmt.allocPrint(allocator, "TECTON_ABI_EXPECT_OFFSET({s}, {s}, {d});\n", .{ entry[0], field.name, @offsetOf(entry[1], field.name) });
            try out.appendSlice(allocator, offset);
        }
    }
    try out.appendSlice(allocator, "TECTON_STATIC_ASSERT(TECTON_ABI_FINGERPRINT == TECTON_ABI_EXPECTED_FINGERPRINT, \"TECTON_ABI_FINGERPRINT drift between header and abi.zig\");\nstatic void tecton_probe_print_layout(void) {\n");
    inline for (layout_types) |entry| {
        const size = try std.fmt.allocPrint(allocator, "  printf(\"{s}.size %zu\\n\", sizeof({s}));\n", .{ entry[0], entry[0] });
        try out.appendSlice(allocator, size);
        inline for (@typeInfo(entry[1]).@"struct".fields) |field| {
            const offset = try std.fmt.allocPrint(allocator, "  printf(\"{s}.{s} %zu\\n\", offsetof({s}, {s}));\n", .{ entry[0], field.name, entry[0], field.name });
            try out.appendSlice(allocator, offset);
        }
    }
    try out.appendSlice(allocator, "  printf(\"fingerprint %016llx\\n\", (unsigned long long)TECTON_ABI_FINGERPRINT);\n}\n#endif\n");
    return out.toOwnedSlice(allocator);
}
