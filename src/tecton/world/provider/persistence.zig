const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum(u8) {
    subchunks,
    block_entities,
    entities,
};

pub const Key = struct {
    kind: Kind,
    dim: u8 = 0,
    x: i32 = 0,
    z: i32 = 0,
};

pub fn chunkKey(kind: Kind, dim_index: i32, x: i32, z: i32) Key {
    return .{ .kind = kind, .dim = @intCast(@as(u32, @bitCast(dim_index)) & 0xff), .x = x, .z = z };
}

pub const Put = struct { key: []u8, value: []u8 };

pub const Record = struct {
    puts: std.ArrayListUnmanaged(Put) = .empty,
    deletes: std.ArrayListUnmanaged([]u8) = .empty,
    bytes: usize = 0,

    pub fn addPut(self: *Record, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        errdefer allocator.free(owned_value);
        try self.puts.append(allocator, .{ .key = owned_key, .value = owned_value });
        self.bytes += owned_key.len + owned_value.len;
    }

    pub fn addDelete(self: *Record, allocator: std.mem.Allocator, key: []const u8) !void {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        try self.deletes.append(allocator, owned_key);
        self.bytes += owned_key.len;
    }

    pub fn isEmpty(self: *const Record) bool {
        return self.puts.items.len == 0 and self.deletes.items.len == 0;
    }

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        for (self.puts.items) |put| {
            allocator.free(put.key);
            allocator.free(put.value);
        }
        for (self.deletes.items) |key| allocator.free(key);
        self.puts.deinit(allocator);
        self.deletes.deinit(allocator);
        self.* = .{};
    }
};

pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, puts: []const Put, deletes: []const []u8) anyerror!void,
};

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

/// Write-queue snapshot for the shutdown log.
pub const Stats = struct {
    written: u64 = 0,
    dropped: u64 = 0,
    retries: u64 = 0,
    keyed: u64 = 0,
    /// Keyed sends merged into a pending slot; they need no write of their own.
    coalesced: u64 = 0,
    /// Payloads re-queued while their write was in flight.
    requeued: u64 = 0,
    ordered: u64 = 0,
    /// Sends rejected by `QueueFull`; the producer writes them inline.
    rejected: u64 = 0,
    pending_now: usize = 0,
    pending_peak: usize = 0,
    reads_lock_free: u64 = 0,
    reads_locked: u64 = 0,
    reads_waited: u64 = 0,
};

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    sink: Sink,
    max_pending_bytes: usize = default_max_pending_bytes,
    /// Log write failures with `std.log.err`; off only for give-up path tests.
    log_failures: bool = true,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: std.HashMapUnmanaged(Key, Slot, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    order: std.ArrayListUnmanaged(Key) = .empty,
    order_head: usize = 0,
    spill: std.ArrayListUnmanaged(Record) = .empty,
    spill_head: usize = 0,
    pending_bytes: usize = 0,
    /// Records queued but not yet written; a fast path check for readers.
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
    /// Lock-free: returns before taking the mutex.
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

    /// Blocks until none of `keys` has an unwritten record; the check is per key.
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

    /// Read under the mutex for a consistent snapshot.
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

    /// One line per database at close.
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
            // A newer payload arrived while writing; it goes to the back.
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

const FakeSink = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    gate: std.Io.Condition = .init,
    entered: std.Io.Condition = .init,
    gated: bool = false,
    writing: bool = false,
    released: bool = false,
    writes: usize = 0,
    last_value: []const u8 = &.{},
    value_buf: [64]u8 = undefined,
    fail_remaining: usize = 0,

    fn write(ctx: *anyopaque, puts: []const Put, deletes: []const []u8) anyerror!void {
        const self: *FakeSink = @ptrCast(@alignCast(ctx));
        _ = deletes;

        self.mutex.lock(self.io) catch unreachable;
        if (self.gated) {
            self.writing = true;
            self.entered.broadcast(self.io);
            while (!self.released) self.gate.wait(self.io, &self.mutex) catch break;
        }
        self.writes += 1;
        if (puts.len > 0) {
            const len = @min(self.value_buf.len, puts[0].value.len);
            @memcpy(self.value_buf[0..len], puts[0].value[0..len]);
            self.last_value = self.value_buf[0..len];
        } else {
            self.last_value = &.{};
        }
        const failing = self.fail_remaining > 0;
        if (failing) self.fail_remaining -= 1;
        self.writing = false;
        self.mutex.unlock(self.io);

        if (failing) return error.SimulatedFailure;
    }

    fn openGate(self: *FakeSink) void {
        self.mutex.lock(self.io) catch return;
        self.gated = true;
        self.released = false;
        self.writing = false;
        self.mutex.unlock(self.io);
    }

    fn waitEntered(self: *FakeSink) void {
        self.mutex.lock(self.io) catch return;
        while (!self.writing) self.entered.wait(self.io, &self.mutex) catch break;
        self.mutex.unlock(self.io);
    }

    fn release(self: *FakeSink) void {
        self.mutex.lock(self.io) catch return;
        self.released = true;
        self.gated = false;
        self.gate.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn writeCount(self: *FakeSink) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.writes;
    }
};

fn makeRecord(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Record {
    var record = Record{};
    errdefer record.deinit(allocator);
    try record.addPut(allocator, key, value);
    return record;
}

test "keyed enqueues coalesce into a single pending slot" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    sink.openGate();
    try writer.start();

    const key = chunkKey(.subchunks, 0, 3, 4);
    const first = try makeRecord(allocator, "k", "aaaa");
    try writer.enqueueKeyed(key, first);
    sink.waitEntered();

    const second = try makeRecord(allocator, "k", "bbbbbb");
    try writer.enqueueKeyed(key, second);
    const third = try makeRecord(allocator, "k", "cc");
    try writer.enqueueKeyed(key, third);

    try std.testing.expect(writer.isPending(key));
    try std.testing.expectEqual(@as(usize, 1), writer.unwrittenCount());

    sink.release();
    writer.flush();

    try std.testing.expectEqual(@as(usize, 2), sink.writeCount());
    try std.testing.expectEqualStrings("cc", sink.last_value);
    try std.testing.expect(!writer.isPending(key));
    try std.testing.expectEqual(@as(usize, 0), writer.pendingBytes());

    const stats = writer.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.keyed);
    try std.testing.expectEqual(@as(u64, 2), stats.coalesced);
    try std.testing.expectEqual(@as(u64, 1), stats.requeued);
    try std.testing.expectEqual(@as(u64, 2), stats.written);
}

test "a record still being written counts as pending" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    sink.openGate();
    try writer.start();

    const key = chunkKey(.entities, 1, -5, 9);
    const record = try makeRecord(allocator, "digp", "x");
    try writer.enqueueKeyed(key, record);
    sink.waitEntered();

    try std.testing.expect(writer.isPending(key));

    sink.release();
    writer.flush();
    try std.testing.expectEqual(@as(u64, 1), writer.writtenCount());
    try std.testing.expect(!writer.isPending(key));
}

const AwaitWaiter = struct {
    fn run(w: *Writer, keys: []const Key, done: *std.atomic.Value(bool)) void {
        w.awaitKeys(keys);
        done.store(true, .release);
    }
};

test "awaitKeys returns only after the pending write lands" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    sink.openGate();
    try writer.start();

    const key = chunkKey(.block_entities, 0, 1, 2);
    const record = try makeRecord(allocator, "be", "payload");
    try writer.enqueueKeyed(key, record);
    sink.waitEntered();

    var keys = [_]Key{key};
    var done = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, AwaitWaiter.run, .{ &writer, &keys, &done });

    try std.testing.expect(!done.load(.acquire));

    sink.release();
    waiter.join();
    try std.testing.expect(done.load(.acquire));
}

test "awaitKeys checks every key in its list" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    sink.openGate();
    try writer.start();

    const first = chunkKey(.subchunks, 0, 3, 3);
    try writer.enqueueKeyed(first, try makeRecord(allocator, "one", "1"));
    sink.waitEntered();
    const second = chunkKey(.block_entities, 0, 3, 3);
    try writer.enqueueKeyed(second, try makeRecord(allocator, "two", "2"));

    var keys = [_]Key{ first, second };
    var done = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, AwaitWaiter.run, .{ &writer, &keys, &done });

    try std.testing.expect(!done.load(.acquire));

    sink.release();
    waiter.join();
    try std.testing.expect(done.load(.acquire));
    try std.testing.expect(!writer.isPending(first));
    try std.testing.expect(!writer.isPending(second));
}

test "awaitKeys does not wait for a key outside its list" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    sink.openGate();
    try writer.start();

    const foreign = chunkKey(.subchunks, 0, 7, 7);
    try writer.enqueueKeyed(foreign, try makeRecord(allocator, "k", "v"));
    sink.waitEntered();

    var keys = [_]Key{ chunkKey(.subchunks, 0, 8, 8), chunkKey(.block_entities, 0, 8, 8) };
    var done = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, AwaitWaiter.run, .{ &writer, &keys, &done });

    var spins: usize = 0;
    while (!done.load(.acquire) and spins < 200_000) : (spins += 1) std.Thread.yield() catch {};
    const returned = done.load(.acquire);

    sink.release();
    waiter.join();
    try std.testing.expect(returned);
}

test "stats tell a lock-free read from a locked one and from a waiting one" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    var idle_keys = [_]Key{chunkKey(.subchunks, 0, 1, 1)};
    writer.awaitKeys(&idle_keys);
    try std.testing.expectEqual(@as(u64, 1), writer.stats().reads_lock_free);

    sink.openGate();
    try writer.start();

    const foreign = chunkKey(.subchunks, 0, 2, 2);
    try writer.enqueueKeyed(foreign, try makeRecord(allocator, "k", "v"));
    sink.waitEntered();

    const mine = chunkKey(.block_entities, 0, 3, 3);
    var keys = [_]Key{mine};
    writer.awaitKeys(&keys);
    try std.testing.expectEqual(@as(u64, 1), writer.stats().reads_locked);
    try std.testing.expectEqual(@as(u64, 0), writer.stats().reads_waited);

    try writer.enqueueKeyed(mine, try makeRecord(allocator, "be", "x"));
    var waiter_keys = [_]Key{mine};
    var done = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, AwaitWaiter.run, .{ &writer, &waiter_keys, &done });

    var spins: usize = 0;
    while (writer.stats().reads_waited == 0 and spins < 200_000) : (spins += 1) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u64, 1), writer.stats().reads_waited);

    sink.release();
    waiter.join();
    try std.testing.expect(done.load(.acquire));

    const stats = writer.stats();
    try std.testing.expectEqual(@as(u64, 2), stats.reads_locked);
    try std.testing.expectEqual(@as(u64, 1), stats.reads_lock_free);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_now);
}

test "stats count coalesced, ordered and rejected records" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    writer.max_pending_bytes = 30;
    defer writer.deinit();

    const key_a = chunkKey(.subchunks, 0, 10, 10);
    try writer.enqueueKeyed(key_a, try makeRecord(allocator, "aaaa", "aaaaaaaa"));
    try writer.enqueueKeyed(key_a, try makeRecord(allocator, "bbbb", "bbbbbbbb"));
    try writer.enqueueKeyed(chunkKey(.subchunks, 0, 11, 10), try makeRecord(allocator, "cccc", "cccccccc"));

    var too_big = try makeRecord(allocator, "dddd", "dddddddd");
    try std.testing.expectError(error.QueueFull, writer.enqueueKeyed(chunkKey(.subchunks, 0, 12, 10), too_big));
    too_big.deinit(allocator);
    var ordered_big = try makeRecord(allocator, "eeee", "eeeeeeee");
    try std.testing.expectError(error.QueueFull, writer.enqueueOrdered(ordered_big));
    ordered_big.deinit(allocator);
    try writer.enqueueOrdered(try makeRecord(allocator, "f", "f"));

    const stats = writer.stats();
    try std.testing.expectEqual(@as(u64, 3), stats.keyed);
    try std.testing.expectEqual(@as(u64, 1), stats.coalesced);
    try std.testing.expectEqual(@as(u64, 1), stats.ordered);
    try std.testing.expectEqual(@as(u64, 2), stats.rejected);
    try std.testing.expectEqual(@as(usize, 26), stats.pending_peak);
    try std.testing.expectEqual(@as(usize, 26), stats.pending_now);
    try std.testing.expectEqual(@as(usize, 3), writer.unwrittenCount());
}

test "enqueue reports a full queue instead of growing without bound" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    writer.max_pending_bytes = 20;
    defer writer.deinit();

    const key_a = chunkKey(.subchunks, 0, 0, 0);
    const record_a = try makeRecord(allocator, "aaaa", "aaaaaaaa");
    try writer.enqueueKeyed(key_a, record_a);
    try std.testing.expect(writer.isPending(key_a));

    const key_b = chunkKey(.subchunks, 0, 1, 0);
    var record_b = try makeRecord(allocator, "bbbb", "bbbbbbbb");
    try std.testing.expectError(error.QueueFull, writer.enqueueKeyed(key_b, record_b));

    record_b.deinit(allocator);
    try std.testing.expect(!writer.isPending(key_b));
    try std.testing.expectEqual(@as(usize, 12), writer.pendingBytes());
}

test "a failed write is retried before being reported" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io, .fail_remaining = 2 };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();
    try writer.start();

    const key = chunkKey(.subchunks, 0, 7, 7);
    const record = try makeRecord(allocator, "k", "value");
    try writer.enqueueKeyed(key, record);
    writer.flush();

    try std.testing.expectEqual(@as(usize, 3), sink.writeCount());
    try std.testing.expectEqual(@as(u64, 0), writer.droppedCount());
    try std.testing.expect(!writer.isPending(key));
    try std.testing.expectEqual(@as(usize, 0), writer.pendingBytes());
}

test "a write that never succeeds is reported and the slot released" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io, .fail_remaining = 100 };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    writer.log_failures = false;
    defer writer.deinit();
    try writer.start();

    const key = chunkKey(.subchunks, 0, 8, 8);
    const record = try makeRecord(allocator, "k", "value");
    try writer.enqueueKeyed(key, record);
    writer.flush();

    try std.testing.expectEqual(@as(usize, 3), sink.writeCount());
    try std.testing.expectEqual(@as(u64, 1), writer.droppedCount());
    try std.testing.expect(!writer.isPending(key));
    try std.testing.expectEqual(@as(usize, 0), writer.pendingBytes());
}

test "ordered records keep FIFO order and stop drains them" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();
    try writer.start();

    for (0..50) |i| {
        var name_buf: [16]u8 = undefined;
        const value = try std.fmt.bufPrint(&name_buf, "player-{d}", .{i});
        const record = try makeRecord(allocator, "player", value);
        try writer.enqueueOrdered(record);
    }

    writer.stop();
    try std.testing.expectEqual(@as(usize, 50), sink.writeCount());
    try std.testing.expectEqualStrings("player-49", sink.last_value);
    try std.testing.expectEqual(@as(usize, 0), writer.pendingBytes());
    try std.testing.expectEqual(@as(usize, 0), writer.unwrittenCount());
}
