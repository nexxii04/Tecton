const std = @import("std");
const builtin = @import("builtin");

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
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }
    else
        .{};

    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    const is_windows = target.result.os.tag == .windows;
    const is_macos = target.result.os.tag == .macos;

    const leveldb_lib = b.addLibrary(.{
        .name = "leveldb",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        }),
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

    for (leveldb_sources) |src| {
        leveldb_lib.root_module.addCSourceFile(.{ .file = b.path(b.fmt("libs/leveldb/src/{s}", .{src})), .flags = platform_flags });
    }

    const env_file: []const u8 = if (is_windows) "util/env_windows.cc" else "util/env_posix.cc";
    leveldb_lib.root_module.addCSourceFile(.{ .file = b.path(b.fmt("libs/leveldb/src/{s}", .{env_file})), .flags = platform_flags });

    const binarystream_dep = b.dependency("BinaryStream", .{
        .target = target,
        .optimize = optimize,
    });
    const binarystream_mod = binarystream_dep.module("BinaryStream");

    const raknet_dep = b.dependency("ZigNet", .{
        .target = target,
        .optimize optimize,
    });

    const raknet_mod = raknet_dep.module("Raknet");
    raknet_mod.addImport("BinaryStream", binarystream_mod);

    const nbt_dep = b.dependency("nbt", .{
        .target = target,
        .optimize = optimize,
    });
    const nbt_mod = nbt_dep.module("nbt");

    const protocol_dep = b.dependency("protocol", .{
        .target = target,
        .optimize = optimize,
    });
    const protocol_mod = protocol_dep.module("Protocol");

    const leveldb_mod = b.addModule("leveldb", .{
        .root_source_file = b.path("libs/leveldb/leveldb.zig"),
        .target = target,
    });

    const conduit_mod = b.addModule("conduit", .{
        .root_source_file = b.path("src/conduit/root.zig"),
        .target = target,
    });
    conduit_mod.addImport("BinaryStream", binarystream_mod);
    conduit_mod.addImport("Raknet", raknet_mod);
    conduit_mod.addImport("protocol", protocol_mod);
    conduit_mod.addImport("nbt", nbt_mod);
    conduit_mod.addImport("leveldb", leveldb_mod);
    conduit_mod.linkLibrary(zlib_dep.artifact("z"));
    if (is_windows) {
        conduit_mod.linkSystemLibrary("psapi", .{});
        conduit_mod.linkSystemLibrary("ws2_32", .{});
    }

    const exe = b.addExecutable(.{
        .name = "Conduit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "conduit", .module = conduit_mod },
                .{ .name = "protocol", .module = protocol_mod },
                .{ .name = "nbt", .module = nbt_mod },
                .{ .name = "leveldb", .module = leveldb_mod },
            },
        }),
    });

    exe.root_module.linkLibrary(zlib_dep.artifact("z"));
    exe.root_module.linkLibrary(leveldb_lib);
    if (is_windows) {
        exe.root_module.linkSystemLibrary("winmm", .{});
    }
    // exe.root_module.strip = true;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const chest_test_mod = b.createModule(.{
        .root_source_file = b.path("src/conduit/chest-test-root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "BinaryStream", .module = binarystream_mod },
            .{ .name = "Raknet", .module = raknet_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "nbt", .module = nbt_mod },
            .{ .name = "leveldb", .module = leveldb_mod },
        },
    });
    chest_test_mod.linkLibrary(zlib_dep.artifact("z"));
    if (is_windows) {
        chest_test_mod.linkSystemLibrary("psapi", .{});
    }
    const chest_tests = b.addTest(.{ .root_module = chest_test_mod });
    chest_tests.root_module.linkLibrary(leveldb_lib);
    chest_tests.root_module.linkLibrary(zlib_dep.artifact("z"));
    const run_chest_tests = b.addRunArtifact(chest_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_chest_tests.step);

    const chest_test_step = b.step("test-chest", "Run chest regression tests");
    chest_test_step.dependOn(&run_chest_tests.step);
}
