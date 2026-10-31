pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const c = scope.c;
        const max_output_bytes = scope.max_uncompressed_bytes;

        pub fn zlibInflateInto(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
            if (input.len > max_output_bytes) return error.DecompressedTooLarge;

            const stream = try scope.acquireInflateStream();
            stream.next_in = @constCast(input.ptr);
            stream.avail_in = @as(c_uint, @intCast(input.len));

            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);

            const initial_capacity = @min(@max(input.len *| 4, 256), max_output_bytes);
            try out.ensureTotalCapacityPrecise(allocator, initial_capacity);
            const grow_step: usize = 64 * 1024;

            while (true) {
                if (out.items.len >= max_output_bytes) return error.DecompressedTooLarge;

                var destination = out.unusedCapacitySlice();
                if (destination.len == 0) {
                    try out.ensureUnusedCapacity(allocator, @min(grow_step, max_output_bytes - out.items.len));
                    destination = out.unusedCapacitySlice();
                }

                const room = @min(destination.len, max_output_bytes - out.items.len);
                stream.next_out = destination.ptr;
                stream.avail_out = @intCast(@min(room, std.math.maxInt(c_uint)));
                const before = stream.avail_out;

                const ret = c.inflate(stream, c.Z_NO_FLUSH);
                out.items.len += before - stream.avail_out;

                if (ret == c.Z_STREAM_END) break;
                if (ret == c.Z_OK) continue;
                if (ret == c.Z_BUF_ERROR and stream.avail_out == 0) {
                    if (out.items.len >= max_output_bytes) return error.DecompressedTooLarge;
                    try out.ensureUnusedCapacity(allocator, @min(grow_step, max_output_bytes - out.items.len));
                    continue;
                }
                return error.ZlibInflateFailed;
            }

            return out.items;
        }

        pub fn zlibInflate(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
            if (input.len > max_output_bytes) return error.DecompressedTooLarge;

            var stream: c.z_stream = undefined;
            stream.zalloc = null;
            stream.zfree = null;
            stream.@"opaque" = null;
            stream.next_in = @constCast(input.ptr);
            stream.avail_in = @as(c_uint, @intCast(input.len));

            if (c.inflateInit2(&stream, -15) != c.Z_OK) return error.ZlibInitFailed;
            defer _ = c.inflateEnd(&stream);

            var out = try std.ArrayList(u8).initCapacity(allocator, @min(@max(input.len *| 4, 256), max_output_bytes));
            defer out.deinit(allocator);

            const chunk_size = 256 * 1024;
            var chunk: [chunk_size]u8 = undefined;

            while (true) {
                stream.next_out = &chunk;
                stream.avail_out = chunk_size;

                const ret = c.inflate(&stream, c.Z_NO_FLUSH);
                const have = chunk_size - stream.avail_out;
                if (have > max_output_bytes - out.items.len) return error.DecompressedTooLarge;
                try out.appendSlice(allocator, chunk[0..have]);

                if (ret == c.Z_STREAM_END) break;
                if (ret != c.Z_OK) return error.ZlibInflateFailed;
            }

            return out.toOwnedSlice(allocator);
        }
    };
}
