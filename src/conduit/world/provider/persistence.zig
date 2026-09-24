const std = @import("std");

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

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    sink: Sink,
    max_pending_bytes: usize = default_max_pending_bytes,
    /// Write failures are reported through `std.log.err`. Only tests that
    /// exercise the give-up path turn this off: the test runner counts any
    /// logged error as a failed run.
    log_failures: bool = true,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    pending: std.HashMapUnmanaged(Key, Slot, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    order: std.ArrayListUnmanaged(Key) = .empty,
    order_head: usize = 0,
    spill: std.ArrayListUnmanaged(Record) = .empty,
    spill_head: usize = 0,
    pending_bytes: usize = 0,
    /// Records queued but not yet written. Read without the lock as a fast path
    /// for readers: a non-zero value only means "take the lock and check".
    unwritten: std.atomic.Value(usize) = .init(0),
    running: bool = false,
    thread: ?std.Thread = null,
    written: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),

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

        if (self.pending_bytes + record.bytes > self.max_pending_bytes) return error.QueueFull;

        const gop = try self.pending.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            _ = self.unwritten.fetchAdd(1, .monotonic);
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

        if (!slot.queued) {
            try self.order.append(self.allocator, key);
            slot.queued = true;
        }
        self.cond.signal(self.io);
    }

    /// FIFO record without a coalescing key.
    pub fn enqueueOrdered(self: *Writer, record: Record) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending_bytes + record.bytes > self.max_pending_bytes) return error.QueueFull;

        try self.spill.append(self.allocator, record);
        self.pending_bytes += record.bytes;
        _ = self.unwritten.fetchAdd(1, .monotonic);
        self.cond.signal(self.io);
    }

    pub fn isPending(self: *Writer, key: Key) bool {
        if (self.unwritten.load(.monotonic) == 0) return false;
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        return self.pending.getPtr(key) != null;
    }

    /// Blocks until `key` has no unwritten record. Only readers call this, so
    /// the tick thread keeps its budget intact.
    pub fn awaitKey(self: *Writer, key: Key) void {
        if (self.unwritten.load(.monotonic) == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        while (self.pending.getPtr(key)) |_| {
            self.cond.wait(self.io, &self.mutex) catch return;
        }
    }

    /// Blocks until every queued record has reached the sink.
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

    // The writer handed the payload to the sink but must keep the slot visible:
    // a reader arriving here would otherwise read the pre-write value.
    try std.testing.expect(writer.isPending(key));

    sink.release();
    writer.flush();
    try std.testing.expectEqual(@as(u64, 1), writer.writtenCount());
    try std.testing.expect(!writer.isPending(key));
}

test "awaitKey returns only after the pending write lands" {
    const allocator = std.testing.allocator;
    var sink = FakeSink{ .io = std.testing.io };
    var writer = Writer.init(std.testing.io, allocator, .{ .ctx = &sink, .write = FakeSink.write });
    defer writer.deinit();

    const Waiter = struct {
        fn run(w: *Writer, k: Key, reached: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            reached.store(true, .release);
            w.awaitKey(k);
            done.store(true, .release);
        }
    };

    sink.openGate();
    try writer.start();

    const key = chunkKey(.block_entities, 0, 1, 2);
    const record = try makeRecord(allocator, "be", "payload");
    try writer.enqueueKeyed(key, record);
    sink.waitEntered();

    var reached = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &writer, key, &reached, &done });
    while (!reached.load(.acquire)) std.Thread.yield() catch {};

    // The sink stays gated, so the write cannot have landed no matter how the
    // waiter thread is scheduled.
    try std.testing.expect(!done.load(.acquire));

    sink.release();
    waiter.join();
    try std.testing.expect(done.load(.acquire));
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

    // Rejected: the caller owns it now and must write it synchronously.
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
