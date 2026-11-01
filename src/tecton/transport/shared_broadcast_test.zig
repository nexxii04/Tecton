pub fn Suite(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const SharedBroadcast = scope.SharedBroadcast;
        const NetworkHandler = scope.NetworkHandler;
        const PayloadBuffers = scope.PayloadBuffers;
        const Compression = scope.Compression;
        const TransportFake = scope.TransportFake;
        const Connection = scope.Connection;
        const ConnectionRegistry = scope.ConnectionRegistry;
        const events_mod = scope.events_mod;
        const CompressionOptions = @import("./compression/options.zig").CompressionOptions;

        const zlib_options: CompressionOptions = .{ .compression_method = .Zlib, .compression_threshold = 255 };

        fn poolCountsRestored(buffers: *PayloadBuffers) !void {
            for (0..PayloadBuffers.class_sizes.len) |class_index| {
                const capacity = buffers.capacity(class_index);
                if (capacity == 0) continue;
                try std.testing.expectEqual(capacity, buffers.available(class_index));
            }
        }

        fn testHandler(tasks: *@import("../tasks/threaded_tasks.zig").ThreadedTaskQueue, port: ?@import("./port.zig").Port) !*NetworkHandler {
            const handler = try NetworkHandler.init(std.testing.io, std.testing.allocator, tasks, .{
                .ctx = undefined,
                .dispatch = struct {
                    fn run(_: *anyopaque, _: *Connection, _: []const []const u8) void {}
                }.run,
            });
            handler.port = port;
            return handler;
        }

        pub fn case_000() !void {
            var tasks = @import("../tasks/threaded_tasks.zig").ThreadedTaskQueue.init(std.testing.io, std.testing.allocator, 1);
            defer tasks.deinit();
            const handler = try testHandler(&tasks, null);
            defer handler.deinit();

            var broadcast = try SharedBroadcast.begin(handler, "a packet that will be broadcast");
            defer broadcast.deinit();
            const buffers = &handler.payload_buffers;

            try std.testing.expect(broadcast.bytes().len > 0);
            broadcast.deinit();
            try poolCountsRestored(buffers);
        }

        pub fn case_001() !void {
            var tasks = @import("../tasks/threaded_tasks.zig").ThreadedTaskQueue.init(std.testing.io, std.testing.allocator, 1);
            defer tasks.deinit();
            const handler = try testHandler(&tasks, null);
            defer handler.deinit();

            const packet = "broadcast payload that repeats across every recipient";
            var broadcast = try SharedBroadcast.begin(handler, packet);
            defer broadcast.deinit();

            const decompressed = try Compression.decompress(broadcast.bytes(), .{
                .compression_method = .Zlib,
                .compression_threshold = 255,
            }, .negotiated, std.testing.allocator);
            defer decompressed.deinit();
            try std.testing.expectEqual(@as(usize, 1), decompressed.packets.len);
            try std.testing.expectEqualStrings(packet, decompressed.packets[0]);
        }

        pub fn case_002() !void {
            const allocator = std.testing.allocator;
            var tasks = @import("../tasks/threaded_tasks.zig").ThreadedTaskQueue.init(std.testing.io, allocator, 1);
            defer tasks.deinit();

            var fake = TransportFake.init(allocator);
            defer fake.deinit();
            const handler = try testHandler(&tasks, fake.port());
            defer handler.deinit();

            var events = events_mod.Queue.init(std.testing.io, allocator);
            defer events.deinit();
            var registry = ConnectionRegistry.init(allocator, std.testing.io, &events);
            defer registry.deinit();

            var backends: [2]u128 = .{ 0, 0 };
            const first = try registry.create(&backends[0]);
            const second = try registry.create(&backends[1]);

            const packet = "shared broadcast packet";
            var broadcast = try SharedBroadcast.begin(handler, packet);
            defer broadcast.deinit();

            broadcast.send(first, .normal);
            broadcast.send(second, .normal);

            try std.testing.expectEqual(@as(usize, 2), fake.sent.items.len);
            for (fake.sent.items) |entry| {
                try std.testing.expectEqualSlices(u8, broadcast.bytes(), entry.bytes);
            }

            broadcast.deinit();
            try poolCountsRestored(&handler.payload_buffers);

            const decompressed = try Compression.decompress(fake.sent.items[0].bytes, zlib_options, .negotiated, allocator);
            defer decompressed.deinit();
            try std.testing.expectEqualStrings(packet, decompressed.packets[0]);
        }

        pub fn case_003() !void {
            const allocator = std.testing.allocator;
            var tasks = @import("../tasks/threaded_tasks.zig").ThreadedTaskQueue.init(std.testing.io, allocator, 1);
            defer tasks.deinit();
            const handler = try testHandler(&tasks, null);
            defer handler.deinit();

            var events = events_mod.Queue.init(std.testing.io, allocator);
            defer events.deinit();
            var registry = ConnectionRegistry.init(allocator, std.testing.io, &events);
            defer registry.deinit();

            var backend: u128 = 0;
            const conn = try registry.create(&backend);

            var broadcast = try SharedBroadcast.begin(handler, "no transport here");
            broadcast.send(conn, .normal);
            broadcast.deinit();
            try poolCountsRestored(&handler.payload_buffers);
        }
    };
}
