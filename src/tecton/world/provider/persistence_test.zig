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

        const AwaitWaiter = struct {
            fn run(w: *Writer, keys: []const Key, done: *std.atomic.Value(bool)) void {
                w.awaitKeys(keys);
                done.store(true, .release);
            }
        };

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

        pub fn case_006() !void {
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

        pub fn case_007() !void {
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

        pub fn case_008() !void {
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

        pub fn case_009() !void {
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

        pub fn case_010() !void {
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
    };
}
