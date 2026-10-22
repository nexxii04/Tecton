pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const Raknet = scope.Raknet;
        const SharedBroadcast = scope.SharedBroadcast;
        const PayloadBuffers = scope.PayloadBuffers;
        const Compression = scope.Compression;
        const maxFramePayload = scope.maxFramePayload;
        const CompressionOptions = @import("./compression/options.zig").CompressionOptions;

        const zlib_options: CompressionOptions = .{ .compression_method = .Zlib, .compression_threshold = 255 };

        fn poolCountsRestored(buffers: *PayloadBuffers) !void {
            for (0..PayloadBuffers.class_sizes.len) |class_index| {
                const capacity = buffers.capacity(class_index);
                if (capacity == 0) continue;
                try std.testing.expectEqual(capacity, buffers.available(class_index));
            }
        }

        fn buildTransport(allocator: std.mem.Allocator) !Raknet.Server {
            return Raknet.Server.init(std.testing.io, .{
                .allocator = allocator,
                .address = "127.0.0.1",
                .port = 0,
                .output_slab_slots = 8,
                .transient_slab_slots = 4,
                .outbound_queue_slots = 8,
            });
        }

        pub fn case_000() !void {
            const allocator = std.testing.allocator;
            var buffers = PayloadBuffers.init(allocator);
            defer buffers.deinit();

            const packet = "a packet that will be broadcast";
            var broadcast = try SharedBroadcast.begin(&buffers, packet, .{
                .compression_method = .Zlib,
                .compression_threshold = 255,
            });
            try std.testing.expect(broadcast.bytes != null);
            broadcast.deinit();
            broadcast.deinit();

            try poolCountsRestored(&buffers);
        }

        pub fn case_001() !void {
            const allocator = std.testing.allocator;
            var buffers = PayloadBuffers.init(allocator);
            defer buffers.deinit();

            const packet = "broadcast payload that repeats across every recipient";
            var broadcast = try SharedBroadcast.begin(&buffers, packet, .{
                .compression_method = .Zlib,
                .compression_threshold = 1,
            });
            defer broadcast.deinit();

            const decompressed = try Compression.decompress(broadcast.bytes.?, .{
                .compression_method = .Zlib,
                .compression_threshold = 255,
            }, allocator);
            defer decompressed.deinit();
            try std.testing.expectEqual(@as(usize, 1), decompressed.packets.len);
            try std.testing.expectEqualStrings(packet, decompressed.packets[0]);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var transport_failing = std.testing.FailingAllocator.init(allocator, .{});
            var transport = try buildTransport(transport_failing.allocator());
            defer transport.deinit();

            var pool_failing = std.testing.FailingAllocator.init(allocator, .{});
            var buffers = PayloadBuffers.init(pool_failing.allocator());
            defer buffers.deinit();

            const first = try allocator.create(Raknet.Connection);
            defer allocator.destroy(first);
            first.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } }, 1400, 1);
            defer first.deinit();
            try first.comm_data.output_frame_queue.ensureTotalCapacity(transport_failing.allocator(), 4);

            const second = try allocator.create(Raknet.Connection);
            defer allocator.destroy(second);
            second.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 2 } }, 1400, 2);
            defer second.deinit();
            try second.comm_data.output_frame_queue.ensureTotalCapacity(transport_failing.allocator(), 4);

            const packet = "shared broadcast packet";
            {
                var warmup = try SharedBroadcast.begin(&buffers, packet, zlib_options);
                warmup.deinit();
            }

            const transport_allocations = transport_failing.alloc_index;
            const pool_allocations = pool_failing.alloc_index;
            transport_failing.fail_index = transport_allocations;
            pool_failing.fail_index = pool_allocations;

            var broadcast = try SharedBroadcast.begin(&buffers, packet, zlib_options);
            try std.testing.expect(broadcast.bytes.?.len <= maxFramePayload(first));

            broadcast.send(first, .normal);
            broadcast.send(second, .normal);

            try std.testing.expectEqual(transport_allocations, transport_failing.alloc_index);
            try std.testing.expectEqual(pool_allocations, pool_failing.alloc_index);
            try std.testing.expect(!transport_failing.has_induced_failure);
            try std.testing.expect(!pool_failing.has_induced_failure);

            transport_failing.fail_index = std.math.maxInt(usize);
            pool_failing.fail_index = std.math.maxInt(usize);

            for ([_]*Raknet.Connection{ first, second }) |conn| {
                try std.testing.expectEqual(@as(usize, 1), conn.comm_data.output_frame_queue.items.len);
                const frame = &conn.comm_data.output_frame_queue.items[0];
                try std.testing.expectEqual(broadcast.shared.?, frame.shared.?);
                try std.testing.expectEqual(@intFromPtr(broadcast.bytes.?.ptr), @intFromPtr(frame.payload.ptr));
            }

            const decompressed = try Compression.decompress(first.comm_data.output_frame_queue.items[0].payload, .{
                .compression_method = .Zlib,
                .compression_threshold = 255,
            }, allocator);
            defer decompressed.deinit();
            try std.testing.expectEqualStrings(packet, decompressed.packets[0]);

            broadcast.deinit();
            for ([_]*Raknet.Connection{ first, second }) |conn| {
                for (conn.comm_data.output_frame_queue.items) |*frame| frame.deinit();
                conn.comm_data.output_frame_queue.clearRetainingCapacity();
            }
            try poolCountsRestored(&buffers);
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var transport_failing = std.testing.FailingAllocator.init(allocator, .{});
            var transport = try buildTransport(transport_failing.allocator());
            defer transport.deinit();

            var buffers = PayloadBuffers.init(allocator);
            defer buffers.deinit();

            const conn = try allocator.create(Raknet.Connection);
            defer allocator.destroy(conn);
            conn.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 3 } }, 1400, 3);
            defer conn.deinit();

            var packet: [4096]u8 = undefined;
            var state: u32 = 0x9e3779b9;
            for (&packet) |*byte| {
                state = state *% 1664525 +% 1013904223;
                byte.* = @truncate(state >> 16);
            }

            var broadcast = try SharedBroadcast.begin(&buffers, &packet, zlib_options);
            defer broadcast.deinit();

            try std.testing.expect(broadcast.bytes.?.len > maxFramePayload(conn));
            broadcast.send(conn, .normal);

            const frames = conn.comm_data.output_frame_queue.items;
            try std.testing.expect(frames.len > 1);
            for (frames, 0..) |frame, index| {
                try std.testing.expectEqual(@as(u32, @intCast(frames.len)), frame.split_size.?);
                try std.testing.expectEqual(@as(u32, @intCast(index)), frame.split_frame_index.?);
                try std.testing.expect(frame.shared != null);
                try std.testing.expect(@intFromPtr(frame.payload.ptr) != @intFromPtr(broadcast.bytes.?.ptr));
            }
        }
    };
}
