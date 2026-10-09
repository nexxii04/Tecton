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

        pub fn case_009() !void {
            const allocator = testing.allocator;
            var payload: [100 * 29]u8 = undefined;
            for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

            var index: Index = .{};
            defer index.deinit(allocator);

            var visible = std.AutoHashMap(i64, u32).init(allocator);
            defer visible.deinit();
            for (0..100) |i| {
                try index.add(allocator, regionOf(1, @floatFromInt(i * REGION_BLOCKS * 2), 0), refAt(@intCast(i), i * 29, 29));
                try visible.put(@intCast(i), 1);
            }

            var candidates: std.ArrayListUnmanaged(u32) = .empty;
            defer candidates.deinit(allocator);
            try index.finish(allocator);
            try index.collect(allocator, &candidates, 1, 0, 0, 200);
            try testing.expectEqual(@as(usize, 100), candidates.items.len);

            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(allocator);

            var batches: usize = 0;
            var delivered: usize = 0;
            var cursor: Cursor = .{};
            while (cursor.bucket < candidates.items.len) {
                out.clearRetainingCapacity();
                cursor = fillBatch(
                    &out,
                    allocator,
                    fakePayload(&payload),
                    index.slots.items,
                    index.buckets.items,
                    candidates.items,
                    cursor,
                    1000,
                    visible,
                    MAX_BATCH_BYTES,
                );
                try testing.expect(out.items.len > 0);

                var bytes: usize = 0;
                for (out.items) |slice| bytes += slice.len;
                try testing.expect(bytes <= MAX_BATCH_BYTES or out.items.len == 1);

                batches += 1;
                delivered += out.items.len;
            }

            try testing.expectEqual(@as(usize, 100), delivered);
            try testing.expect(batches > 1);
        }

        pub fn case_010() !void {
            const allocator = testing.allocator;
            var index: Index = .{};
            defer index.deinit(allocator);

            var visible = std.AutoHashMap(i64, u32).init(allocator);
            defer visible.deinit();
            try visible.put(10, 1);

            const payload = [_]u8{0xAA} ** (MAX_BATCH_BYTES * 2);
            try index.add(allocator, regionOf(1, 0, 0), refAt(10, 0, payload.len));
            try index.finish(allocator);

            var candidates: std.ArrayListUnmanaged(u32) = .empty;
            defer candidates.deinit(allocator);
            try index.collect(allocator, &candidates, 1, 0, 0, 1);

            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(allocator);

            const cursor = fillBatch(
                &out,
                allocator,
                fakePayload(&payload),
                index.slots.items,
                index.buckets.items,
                candidates.items,
                .{},
                99,
                visible,
                MAX_BATCH_BYTES,
            );

            try testing.expectEqual(candidates.items.len, cursor.bucket);
            try testing.expectEqual(@as(usize, 1), out.items.len);
        }

        pub fn case_011() !void {
            const allocator = testing.allocator;
            var index: Index = .{};
            defer index.deinit(allocator);

            var visible = std.AutoHashMap(i64, u32).init(allocator);
            defer visible.deinit();
            try visible.put(50, 1);

            var payload: [51 * 29]u8 = undefined;
            for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

            for (0..51) |i| {
                const rid: i64 = if (i == 50) 50 else @intCast(i);
                try index.add(allocator, regionOf(1, @floatFromInt(i), 0), refAt(rid, i * 29, 29));
            }
            try index.finish(allocator);

            var candidates: std.ArrayListUnmanaged(u32) = .empty;
            defer candidates.deinit(allocator);
            try index.collect(allocator, &candidates, 1, 0, 0, 50);

            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(allocator);

            const cursor = fillBatch(
                &out,
                allocator,
                fakePayload(&payload),
                index.slots.items,
                index.buckets.items,
                candidates.items,
                .{},
                99,
                visible,
                MAX_BATCH_BYTES,
            );

            try testing.expectEqual(candidates.items.len, cursor.bucket);
            try testing.expectEqual(@as(usize, 1), out.items.len);
        }

        pub fn case_012() !void {
            var stream = BinaryStream.init(testing.allocator, null, null);
            defer stream.deinit();

            var refs: std.ArrayList(DeltaRef) = .empty;
            defer refs.deinit(testing.allocator);

            const initial_capacity = stream.capacity();

            for (0..300) |i| {
                const packet = Protocol.MoveActorDeltaPacket{
                    .runtime_id = @intCast(i),
                    .x = @floatFromInt(i),
                    .y = @floatFromInt(i * 2),
                    .z = @floatFromInt(i * 3),
                    .rotation_x = @intCast(@as(i32, @intCast(i % 128)) - 64),
                    .on_ground = i % 2 == 0,
                };
                const before = stream.getBuffer().len;
                _ = try packet.serialize(&stream);
                try refs.append(testing.allocator, markRef(&stream, @intCast(i), before));
            }

            try testing.expect(stream.capacity() > initial_capacity);

            const payload = stream.getBuffer();

            var total: usize = 0;
            for (refs.items) |ref| total += ref.len;
            try testing.expectEqual(payload.len, total);

            for (refs.items, 0..) |ref, i| {
                var reader = BinaryStream.init(testing.allocator, ref.slice(payload), null);
                const decoded = try Protocol.MoveActorDeltaPacket.deserialize(&reader);
                try testing.expectEqual(@as(u64, i), decoded.runtime_id);
                try testing.expectEqual(@as(?f32, @floatFromInt(i)), decoded.x);
                try testing.expectEqual(@as(?f32, @floatFromInt(i * 3)), decoded.z);
                try testing.expectEqual(i % 2 == 0, decoded.on_ground);
            }
        }
    };
}
