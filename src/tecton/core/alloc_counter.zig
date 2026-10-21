const std = @import("std");

var parent_allocator: std.mem.Allocator = undefined;
var installed: std.atomic.Value(bool) = .init(false);

threadlocal var thread_allocations: usize = 0;
threadlocal var thread_bytes: usize = 0;

pub const Mark = struct { allocations: usize, bytes: usize };
pub const Delta = struct { allocations: usize, bytes: usize };

pub fn install(parent: std.mem.Allocator) bool {
    if (installed.load(.acquire)) return sameAllocator(parent_allocator, parent);
    parent_allocator = parent;
    installed.store(true, .release);
    reset();
    return true;
}

fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

pub fn isInstalled() bool {
    return installed.load(.acquire);
}

pub fn allocator() std.mem.Allocator {
    std.debug.assert(installed.load(.acquire));
    return .{ .ptr = @ptrCast(&parent_allocator), .vtable = &vtable };
}

pub fn reset() void {
    thread_allocations = 0;
    thread_bytes = 0;
}

pub fn mark() Mark {
    return .{ .allocations = thread_allocations, .bytes = thread_bytes };
}

pub fn since(m: Mark) Delta {
    return .{ .allocations = thread_allocations -% m.allocations, .bytes = thread_bytes -% m.bytes };
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

fn allocFn(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const parent: *const std.mem.Allocator = @ptrCast(@alignCast(context));
    const memory = parent.vtable.alloc(parent.ptr, len, alignment, ra);
    if (memory != null) record(len);
    return memory;
}

fn resizeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const parent: *const std.mem.Allocator = @ptrCast(@alignCast(context));
    return parent.vtable.resize(parent.ptr, memory, alignment, new_len, ra);
}

fn remapFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const parent: *const std.mem.Allocator = @ptrCast(@alignCast(context));
    const result = parent.vtable.remap(parent.ptr, memory, alignment, new_len, ra);
    if (result != null and new_len > memory.len) record(new_len - memory.len);
    return result;
}

fn freeFn(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const parent: *const std.mem.Allocator = @ptrCast(@alignCast(context));
    parent.vtable.free(parent.ptr, memory, alignment, ra);
}

fn record(len: usize) void {
    thread_allocations +%= 1;
    thread_bytes +%= len;
}

fn uninstall() void {
    installed.store(false, .release);
    reset();
}

test "the counting allocator records the caller thread allocation" {
    try std.testing.expect(install(std.testing.allocator));
    defer uninstall();
    try std.testing.expect(isInstalled());

    const counted = allocator();
    const before = mark();
    const bytes = try counted.alloc(u8, 64);
    defer counted.free(bytes);

    const delta = since(before);
    try std.testing.expectEqual(@as(usize, 1), delta.allocations);
    try std.testing.expect(delta.bytes >= 64);
}

test "frees are not counted and another thread keeps its own count" {
    try std.testing.expect(install(std.testing.allocator));
    defer uninstall();

    const counted = allocator();
    const before = mark();

    const Worker = struct {
        fn run(alloc: std.mem.Allocator, out: *usize) void {
            const worker_before = mark();
            for (0..16) |_| {
                const bytes = alloc.alloc(u8, 32) catch return;
                alloc.free(bytes);
            }
            out.* = since(worker_before).allocations;
        }
    };
    var worker_count: usize = 0;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ counted, &worker_count });
    thread.join();

    try std.testing.expectEqual(@as(usize, 16), worker_count);
    try std.testing.expectEqual(@as(usize, 0), since(before).allocations);

    const bytes = try counted.alloc(u8, 8);
    counted.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), since(before).allocations);
}

test "list growth through the counting allocator is recorded as an allocation" {
    try std.testing.expect(install(std.testing.allocator));
    defer uninstall();

    const counted = allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(counted);

    const before = mark();
    try list.appendSlice(counted, "0123456789abcdef");
    try std.testing.expect(since(before).allocations >= 1);

    const settled = mark();
    try list.appendSlice(counted, "more");
    try std.testing.expectEqual(@as(usize, 0), since(settled).allocations);
}

test "installing a second allocator is refused instead of rebinding the counter" {
    try std.testing.expect(install(std.testing.allocator));
    defer uninstall();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expect(!install(failing.allocator()));
    try std.testing.expect(install(std.testing.allocator));
}
