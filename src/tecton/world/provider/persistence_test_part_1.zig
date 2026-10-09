pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Key = scope.Key;
        const chunkKey = scope.chunkKey;
        const Put = scope.Put;
        const Record = scope.Record;
        const Writer = scope.Writer;

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

        const AwaitWaiter = struct {
            fn run(w: *Writer, keys: []const Key, done: *std.atomic.Value(bool)) void {
                w.awaitKeys(keys);
                done.store(true, .release);
            }
        };

        pub fn case_000() !void {
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

        pub fn case_001() !void {
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

        pub fn case_002() !void {
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

        pub fn case_003() !void {
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

        pub fn case_004() !void {
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

        pub fn case_005() !void {
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
    };
}
