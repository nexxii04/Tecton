const std = @import("std");
const builtin = @import("builtin");

const key_types = @import("keys.zig");
const stats_mod = @import("stats.zig");

pub const Kind = key_types.Kind;
pub const Key = key_types.Key;
pub const chunkKey = key_types.chunkKey;
pub const Put = key_types.Put;
pub const Record = key_types.Record;
pub const Sink = stats_mod.Sink;
pub const Stats = stats_mod.Stats;

pub const default_max_pending_bytes: usize = 16 * 1024 * 1024;
const max_write_attempts: u8 = 3;

const Slot = struct {
    record: ?Record = null,
    version: u64 = 0,
    failures: u8 = 0,
    queued: bool = false,
};

const KeyContext = struct {
    const SEED: u64 = 0x9e3779b97f4a7c15;

    pub fn hash(_: KeyContext, key: Key) u64 {
        var state = std.hash.Wyhash.init(SEED);
        state.update(std.mem.asBytes(&key.x));
        state.update(std.mem.asBytes(&key.z));
        state.update(&[_]u8{ @intFromEnum(key.kind), key.dim });
        return state.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.kind == b.kind and a.dim == b.dim and a.x == b.x and a.z == b.z;
    }
};

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    sink: Sink,
    max_pending_bytes: usize = default_max_pending_bytes,

    log_failures: bool = true,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: std.HashMapUnmanaged(Key, Slot, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    order: std.ArrayListUnmanaged(Key) = .empty,
    order_head: usize = 0,
    spill: std.ArrayListUnmanaged(Record) = .empty,
    spill_head: usize = 0,
    pending_bytes: usize = 0,

    unwritten: std.atomic.Value(usize) = .init(0),
    running: bool = false,
    thread: ?std.Thread = null,
    written: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),

    keyed: u64 = 0,
    coalesced: u64 = 0,
    requeued: u64 = 0,
    ordered: u64 = 0,
    rejected: u64 = 0,
    retries: u64 = 0,
    pending_peak_bytes: usize = 0,
    read_locks: u64 = 0,
    read_waits: u64 = 0,

    read_lock_free: std.atomic.Value(u64) = .init(0),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, sink: Sink) Writer {
        return .{ .io = io, .allocator = allocator, .sink = sink };
    }

    pub fn start(self: *Writer) !void {
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn enqueueKeyed(self: *Writer, key: Key, record: Record) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending_bytes + record.bytes > self.max_pending_bytes) {
            self.rejected += 1;
            return error.QueueFull;
        }
        self.keyed += 1;

        const gop = try self.pending.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            _ = self.unwritten.fetchAdd(1, .monotonic);
        } else {
            self.coalesced += 1;
        }

        const slot = gop.value_ptr;
        if (slot.record) |*replaced| {
            self.pending_bytes -= replaced.bytes;
            replaced.deinit(self.allocator);
        }
        slot.record = record;
        slot.version += 1;
        slot.failures = 0;
        self.pending_bytes += record.bytes;
        if (self.pending_bytes > self.pending_peak_bytes) self.pending_peak_bytes = self.pending_bytes;

        if (!slot.queued) {
            try self.order.append(self.allocator, key);
            slot.queued = true;
        }
        self.cond.signal(self.io);
    }

    pub fn enqueueOrdered(self: *Writer, record: Record) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending_bytes + record.bytes > self.max_pending_bytes) {
            self.rejected += 1;
            return error.QueueFull;
        }

        try self.spill.append(self.allocator, record);
        self.pending_bytes += record.bytes;
        if (self.pending_bytes > self.pending_peak_bytes) self.pending_peak_bytes = self.pending_bytes;
        self.ordered += 1;
        _ = self.unwritten.fetchAdd(1, .monotonic);
        self.cond.signal(self.io);
    }

    pub fn isPending(self: *Writer, key: Key) bool {
        if (self.unwritten.load(.monotonic) == 0) return false;
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        return self.pending.getPtr(key) != null;
    }

    pub fn awaitKeys(self: *Writer, keys: []const Key) void {
        if (self.unwritten.load(.monotonic) == 0) {
            _ = self.read_lock_free.fetchAdd(1, .monotonic);
            return;
        }
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.read_locks += 1;
        var waited = false;
        while (self.anyPending(keys)) {
            if (!waited) {
                self.read_waits += 1;
                waited = true;
            }
            self.cond.wait(self.io, &self.mutex) catch return;
        }
    }

    fn anyPending(self: *Writer, keys: []const Key) bool {
        for (keys) |key| {
            if (self.pending.getPtr(key) != null) return true;
        }
        return false;
    }

    pub fn flush(self: *Writer) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        while (self.unwritten.load(.monotonic) != 0) {
            self.cond.wait(self.io, &self.mutex) catch return;
        }
    }

    pub fn stop(self: *Writer) void {
        self.mutex.lock(self.io) catch {};
        self.running = false;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Writer) void {
        self.stop();

        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.record) |*record| record.deinit(self.allocator);
        }
        self.pending.deinit(self.allocator);
        self.pending = .empty;
        if (self.order.capacity > 0) self.order.deinit(self.allocator);
        self.order = .empty;
        self.order_head = 0;
        for (self.spill.items) |*record| record.deinit(self.allocator);
        if (self.spill.capacity > 0) self.spill.deinit(self.allocator);
        self.spill = .empty;
        self.spill_head = 0;
        self.pending_bytes = 0;
        self.unwritten.store(0, .monotonic);
    }

    pub fn pendingBytes(self: *Writer) usize {
        return self.pending_bytes;
    }

    pub fn unwrittenCount(self: *Writer) usize {
        return self.unwritten.load(.monotonic);
    }

    pub fn writtenCount(self: *Writer) u64 {
        return self.written.load(.monotonic);
    }

    pub fn droppedCount(self: *Writer) u64 {
        return self.dropped.load(.monotonic);
    }

    pub fn stats(self: *Writer) Stats {
        self.mutex.lock(self.io) catch return .{};
        defer self.mutex.unlock(self.io);
        return .{
            .written = self.written.load(.monotonic),
            .dropped = self.dropped.load(.monotonic),
            .retries = self.retries,
            .keyed = self.keyed,
            .coalesced = self.coalesced,
            .requeued = self.requeued,
            .ordered = self.ordered,
            .rejected = self.rejected,
            .pending_now = self.pending_bytes,
            .pending_peak = self.pending_peak_bytes,
            .reads_lock_free = self.read_lock_free.load(.monotonic),
            .reads_locked = self.read_locks,
            .reads_waited = self.read_waits,
        };
    }

    pub fn logStats(self: *Writer, label: []const u8) void {
        if (builtin.is_test) return;
        const s = self.stats();
        std.log.info(
            "write queue '{s}': {d} keyed ({d} merged, {d} requeued) + {d} ordered, {d} rejected | {d} written, {d} retried, {d} dropped | {d} reads ({d} lock-free, {d} locked, {d} waited) | backlog {d:.1} KiB now, {d:.1} KiB peak, cap {d:.1} KiB",
            .{
                label,
                s.keyed,
                s.coalesced,
                s.requeued,
                s.ordered,
                s.rejected,
                s.written,
                s.retries,
                s.dropped,
                s.reads_lock_free + s.reads_locked,
                s.reads_lock_free,
                s.reads_locked,
                s.reads_waited,
                Writer.kib(s.pending_now),
                Writer.kib(s.pending_peak),
                Writer.kib(self.max_pending_bytes),
            },
        );
    }

    fn kib(bytes: usize) f64 {
        return @as(f64, @floatFromInt(bytes)) / 1024.0;
    }

    fn orderCount(self: *const Writer) usize {
        return self.order.items.len - self.order_head;
    }

    fn spillCount(self: *const Writer) usize {
        return self.spill.items.len - self.spill_head;
    }

    fn compactOrder(self: *Writer) void {
        if (self.order_head == self.order.items.len) {
            self.order.clearRetainingCapacity();
            self.order_head = 0;
        }
    }

    fn takeSpill(self: *Writer) Record {
        const record = self.spill.items[self.spill_head];
        self.spill_head += 1;
        if (self.spill_head == self.spill.items.len) {
            self.spill.clearRetainingCapacity();
            self.spill_head = 0;
        }
        return record;
    }

    fn writeAndSettle(self: *Writer, key: ?Key, version: u64, record: Record) void {
        const bytes = record.bytes;
        const result = self.sink.write(self.sink.ctx, record.puts.items, record.deletes.items);

        self.mutex.lock(self.io) catch {
            var failed = record;
            failed.deinit(self.allocator);
            return;
        };

        if (result) |_| {
            var written = record;
            written.deinit(self.allocator);
            self.pending_bytes -= bytes;
            _ = self.written.fetchAdd(1, .monotonic);
            if (key) |settled| {
                self.settleKey(settled, version);
            } else {
                _ = self.unwritten.fetchSub(1, .monotonic);
            }
        } else |err| {
            self.settleFailure(key, record, err, bytes);
        }

        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn settleKey(self: *Writer, key: Key, version: u64) void {
        const slot = self.pending.getPtr(key) orelse {
            _ = self.unwritten.fetchSub(1, .monotonic);
            self.order_head += 1;
            self.compactOrder();
            return;
        };

        if (slot.version == version) {
            slot.queued = false;
            _ = self.pending.remove(key);
            self.order_head += 1;
            _ = self.unwritten.fetchSub(1, .monotonic);
        } else if (self.order.append(self.allocator, key)) |_| {
            self.requeued += 1;
            self.order_head += 1;
        } else |_| {}

        self.compactOrder();
    }

    fn settleFailure(self: *Writer, key: ?Key, record: Record, err: anyerror, bytes: usize) void {
        const settle = key orelse {
            if (self.log_failures) std.log.err("persistence: dropping ordered record after write failure: {any}", .{err});
            _ = self.dropped.fetchAdd(1, .monotonic);
            self.pending_bytes -= bytes;
            _ = self.unwritten.fetchSub(1, .monotonic);
            var dropped = record;
            dropped.deinit(self.allocator);
            return;
        };

        const slot = self.pending.getPtr(settle) orelse {
            if (self.log_failures) std.log.err("persistence: dropping record for a released slot after write failure: {any}", .{err});
            _ = self.dropped.fetchAdd(1, .monotonic);
            self.pending_bytes -= bytes;
            _ = self.unwritten.fetchSub(1, .monotonic);
            var dropped = record;
            dropped.deinit(self.allocator);
            return;
        };

        slot.failures += 1;
        if (slot.failures >= max_write_attempts or slot.record != null) {
            if (self.log_failures) {
                std.log.err(
                    "persistence: giving up on a record after {d} attempts (chunk {d},{d} dim {d}): {any}",
                    .{ slot.failures, settle.x, settle.z, settle.dim, err },
                );
            }
            _ = self.dropped.fetchAdd(1, .monotonic);
            self.pending_bytes -= bytes;
            if (slot.record == null) {
                slot.queued = false;
                _ = self.pending.remove(settle);
                _ = self.unwritten.fetchSub(1, .monotonic);
            }
            self.order_head += 1;
            self.compactOrder();
            var dropped = record;
            dropped.deinit(self.allocator);
            return;
        }

        slot.record = record;
        self.retries += 1;
        if (self.order.append(self.allocator, settle)) |_| {
            self.order_head += 1;
        } else |_| {}
        self.compactOrder();
    }

    fn run(self: *Writer) void {
        while (true) {
            self.mutex.lock(self.io) catch return;

            while (self.orderCount() == 0 and self.spillCount() == 0 and self.running) {
                self.cond.wait(self.io, &self.mutex) catch {
                    self.mutex.unlock(self.io);
                    return;
                };
            }
            if (self.orderCount() == 0 and self.spillCount() == 0) {
                self.mutex.unlock(self.io);
                return;
            }

            var record: Record = undefined;
            var key: ?Key = null;
            var version: u64 = 0;

            if (self.spillCount() > 0) {
                record = self.takeSpill();
            } else {
                const pending_key = self.order.items[self.order_head];
                const slot = self.pending.getPtr(pending_key) orelse {
                    self.order_head += 1;
                    self.compactOrder();
                    self.mutex.unlock(self.io);
                    continue;
                };
                key = pending_key;
                version = slot.version;
                record = slot.record.?;
                slot.record = null;
            }

            self.mutex.unlock(self.io);
            self.writeAndSettle(key, version, record);
        }
    }
};

const test_owner = @This();
const test_scope = struct {
    pub const std = test_owner.std;
    pub const Key = test_owner.Key;
    pub const chunkKey = test_owner.chunkKey;
    pub const Put = test_owner.Put;
    pub const Record = test_owner.Record;
    pub const Writer = test_owner.Writer;
};

test "keyed enqueues coalesce into a single pending slot" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_000();
}

test "a record still being written counts as pending" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_001();
}

test "awaitKeys returns only after the pending write lands" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_002();
}

test "awaitKeys checks every key in its list" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_003();
}

test "awaitKeys does not wait for a key outside its list" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_004();
}

test "stats tell a lock-free read from a locked one and from a waiting one" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_005();
}

test "stats count coalesced, ordered and rejected records" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_006();
}

test "enqueue reports a full queue instead of growing without bound" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_007();
}

test "a failed write is retried before being reported" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_008();
}

test "a write that never succeeds is reported and the slot released" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_009();
}

test "ordered records keep FIFO order and stop drains them" {
    try @import("persistence_writer_test.zig").Suite(test_scope).case_010();
}

test "chunk keys carry kind, coordinates and masked dimension" {
    try @import("persistence_keys_test.zig").Suite(test_scope).case_keys_000();
}

test "records account bytes and reset on deinit" {
    try @import("persistence_keys_test.zig").Suite(test_scope).case_keys_001();
}
