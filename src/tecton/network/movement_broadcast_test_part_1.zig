pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const testing = scope.testing;
        const BinaryStream = scope.BinaryStream;
        const Protocol = scope.Protocol;
        const MAX_BATCH_BYTES = scope.MAX_BATCH_BYTES;
        const markRef = scope.markRef;
        const DeltaRef = scope.DeltaRef;
        const REGION_BLOCKS = scope.REGION_BLOCKS;
        const regionOf = scope.regionOf;
        const regionRadius = scope.regionRadius;
        const BAND_INTERVALS = scope.BAND_INTERVALS;
        const BAND_DISTANCES = scope.BAND_DISTANCES;
        const bandForDistanceSq = scope.bandForDistanceSq;
        const due = scope.due;
        const emission = scope.emission;
        const ViewerPoint = scope.ViewerPoint;
        const nearestViewerBand = scope.nearestViewerBand;
        const Cursor = scope.Cursor;
        const Index = scope.Index;
        const fillBatch = scope.fillBatch;
        const fakePayload = scope.fakePayload;
        const refAt = scope.refAt;

        pub fn case_000() !void {
            try testing.expectEqual(BAND_DISTANCES.len + 1, BAND_INTERVALS.len);

            try testing.expectEqual(@as(u8, 1), bandForDistanceSq(0));
            try testing.expectEqual(@as(u8, 1), bandForDistanceSq(16.0 * 16.0));
            try testing.expectEqual(@as(u8, 2), bandForDistanceSq(16.001 * 16.001));
            try testing.expectEqual(@as(u8, 2), bandForDistanceSq(32.0 * 32.0));
            try testing.expectEqual(@as(u8, 3), bandForDistanceSq(32.001 * 32.001));
            try testing.expectEqual(@as(u8, 4), bandForDistanceSq(48.001 * 48.001));
            try testing.expectEqual(@as(u8, 4), bandForDistanceSq(std.math.floatMax(f32)));
        }

        pub fn case_001() !void {
            try testing.expect(due(1, 7));
            try testing.expect(due(2, 8));
            try testing.expect(!due(2, 7));
            try testing.expect(due(4, 8));
            try testing.expect(!due(4, 6));
            try testing.expect(due(8, 80));
            try testing.expect(!due(8, 87));
        }

        pub fn case_002() !void {
            const skipped = emission(2, 2, 9, false);
            try testing.expect(!skipped.reset);
            try testing.expect(!skipped.send);

            const on_stride = emission(4, 4, 8, false);
            try testing.expect(!on_stride.reset);
            try testing.expect(on_stride.send);

            const closer = emission(4, 2, 9, false);
            try testing.expect(closer.reset);
            try testing.expect(closer.send);

            const first = emission(null, 4, 9, false);
            try testing.expect(first.reset);
            try testing.expect(first.send);

            const teleport = emission(8, 8, 9, true);
            try testing.expect(!teleport.reset);
            try testing.expect(teleport.send);
        }

        pub fn case_003() !void {
            const viewers = [_]ViewerPoint{
                .{ .runtime_id = 1, .dimension = 7, .x = 0, .z = 0 },
                .{ .runtime_id = 2, .dimension = 7, .x = 10, .z = 0 },
                .{ .runtime_id = 3, .dimension = 7, .x = 100, .z = 0 },
                .{ .runtime_id = 4, .dimension = 8, .x = 0, .z = 0 },
            };

            const close = nearestViewerBand(1, 7, 0, 0, &viewers) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u8, 1), close.band);
            try testing.expectApproxEqAbs(@as(f32, 10), close.distance, 0.001);

            const middle = nearestViewerBand(1, 7, 40, 0, &viewers) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u8, 2), middle.band);
            try testing.expectApproxEqAbs(@as(f32, 30), middle.distance, 0.001);

            const far = [_]ViewerPoint{
                .{ .runtime_id = 2, .dimension = 7, .x = 0, .z = 90 },
            };
            const far_band = nearestViewerBand(1, 7, 0, 0, &far) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u8, 4), far_band.band);
            try testing.expectApproxEqAbs(@as(f32, 90), far_band.distance, 0.001);

            const alone = [_]ViewerPoint{
                .{ .runtime_id = 3, .dimension = 8, .x = 0, .z = 0 },
            };
            try testing.expect(nearestViewerBand(1, 7, 0, 0, &alone) == null);
            try testing.expect(nearestViewerBand(1, 7, 0, 0, viewers[0..1]) == null);
        }

        pub fn case_004() !void {
            const MoveDelta = scope.test_dependency_0;
            const at = struct {
                fn f(x: f32, y: f32, z: f32) MoveDelta.State {
                    return .{ .position = .{ x, y, z }, .rotation = .{ 0, 0, 0 } };
                }
            }.f;

            var last: MoveDelta.LastBroadcast = .{};
            var pending: ?MoveDelta.State = null;
            var emitted: ?Protocol.MoveActorDeltaPacket = null;

            const ticks = [_]struct { tick: u64, state: MoveDelta.State }{
                .{ .tick = 0, .state = at(1, 64, 0) },
                .{ .tick = 1, .state = at(1, 65, 0) },
                .{ .tick = 2, .state = at(1, 65, 1) },
                .{ .tick = 3, .state = at(1, 65, 2) },
                .{ .tick = 4, .state = at(2, 65, 2) },
            };

            for (ticks) |t| {
                pending = t.state;
                if (!due(4, t.tick)) continue;
                emitted = MoveDelta.nextDelta(&last, 7, pending.?, t.tick);
                pending = null;
            }

            try testing.expect(pending == null);
            const packet = emitted orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(?f32, 2), packet.x);
            try testing.expectEqual(@as(?f32, 65), packet.y);
            try testing.expectEqual(@as(?f32, 2), packet.z);
        }

        pub fn case_005() !void {
            const MoveDelta = scope.test_dependency_0;
            var last: MoveDelta.LastBroadcast = .{};
            _ = MoveDelta.nextDelta(&last, 7, .{ .position = .{ 0, 64, 0 }, .rotation = .{ 0, 0, 0 } }, 0) orelse
                return error.TestUnexpectedResult;

            const jumped = MoveDelta.State{ .position = .{ 40, 64, 0 }, .rotation = .{ 0, 0, 0 } };
            try testing.expect(!due(8, 9));
            try testing.expect(MoveDelta.isTeleport(&last, jumped));
            try testing.expect(emission(8, 8, 9, MoveDelta.isTeleport(&last, jumped)).send);

            const packet = MoveDelta.nextDelta(&last, 7, jumped, 9) orelse return error.TestUnexpectedResult;
            try testing.expect(packet.force_move);
        }

        pub fn case_006() !void {
            var view: i32 = 0;
            while (view <= 32) : (view += 1) {
                const radius = regionRadius(view);
                try testing.expect(radius >= 1);
                try testing.expect((radius - 1) * REGION_BLOCKS >= view * 16);
            }
        }

        pub fn case_007() !void {
            const allocator = testing.allocator;
            var index: Index = .{};
            defer index.deinit(allocator);

            var visible = std.AutoHashMap(i64, u32).init(allocator);
            defer visible.deinit();
            try visible.put(10, 1);
            try visible.put(20, 1);

            try visible.put(30, 1);
            try visible.put(40, 1);

            try index.add(allocator, regionOf(1, 0, 0), refAt(10, 0, 2));
            try index.add(allocator, regionOf(1, 0, 0), refAt(20, 2, 2));
            try index.add(allocator, regionOf(1, 1000, 0), refAt(30, 4, 2));
            try index.add(allocator, regionOf(2, 0, 0), refAt(40, 6, 2));
            try index.finish(allocator);

            var candidates: std.ArrayListUnmanaged(u32) = .empty;
            defer candidates.deinit(allocator);
            try index.collect(allocator, &candidates, 1, 0, 0, 2);
            try testing.expectEqual(@as(usize, 1), candidates.items.len);

            const payload = "aabbccdd";
            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(allocator);

            const cursor = fillBatch(
                &out,
                allocator,
                fakePayload(payload),
                index.slots.items,
                index.buckets.items,
                candidates.items,
                .{},
                99,
                visible,
                MAX_BATCH_BYTES,
            );

            try testing.expectEqual(candidates.items.len, cursor.bucket);
            try testing.expectEqual(@as(usize, 2), out.items.len);
            try testing.expectEqualSlices(u8, "aa", out.items[0]);
            try testing.expectEqualSlices(u8, "bb", out.items[1]);
        }

        pub fn case_008() !void {
            const allocator = testing.allocator;
            var index: Index = .{};
            defer index.deinit(allocator);

            var visible = std.AutoHashMap(i64, u32).init(allocator);
            defer visible.deinit();
            try visible.put(10, 1);
            try visible.put(20, 1);

            try index.add(allocator, regionOf(1, 0, 0), refAt(20, 0, 2));
            try index.add(allocator, regionOf(1, 0, 0), refAt(10, 2, 2));
            try index.finish(allocator);

            var candidates: std.ArrayListUnmanaged(u32) = .empty;
            defer candidates.deinit(allocator);
            try index.collect(allocator, &candidates, 1, 0, 0, 1);

            const payload = "aabb";
            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(allocator);

            _ = fillBatch(
                &out,
                allocator,
                fakePayload(payload),
                index.slots.items,
                index.buckets.items,
                candidates.items,
                .{},
                20,
                visible,
                MAX_BATCH_BYTES,
            );

            try testing.expectEqual(@as(usize, 1), out.items.len);
            try testing.expectEqualSlices(u8, "bb", out.items[0]);
        }
    };
}
