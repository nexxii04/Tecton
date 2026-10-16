pub fn Methods(comptime scope: type) type {
    return struct {
        const std = scope.std;
        const c = scope.c;

        pub fn zlibInflateInto(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
            const stream = try scope.acquireInflateStream();
            stream.next_in = @constCast(input.ptr);
            stream.avail_in = @as(c_uint, @intCast(input.len));

            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(allocator);

            try out.ensureTotalCapacityPrecise(allocator, @max(input.len * 4, 256));
            const grow_step: usize = 64 * 1024;

            while (true) {
                var destination = out.unusedCapacitySlice();
                if (destination.len == 0) {
                    try out.ensureUnusedCapacity(allocator, grow_step);
                    destination = out.unusedCapacitySlice();
                }

                stream.next_out = destination.ptr;
                stream.avail_out = @intCast(@min(destination.len, std.math.maxInt(c_uint)));
                const before = stream.avail_out;

                const ret = c.inflate(stream, c.Z_NO_FLUSH);
                out.items.len += before - stream.avail_out;

                if (ret == c.Z_STREAM_END) break;
                if (ret == c.Z_OK) continue;
                if (ret == c.Z_BUF_ERROR and stream.avail_out == 0) {
                    try out.ensureUnusedCapacity(allocator, grow_step);
                    continue;
                }
                return error.ZlibInflateFailed;
            }

            return out.items;
        }

        pub fn zlibInflate(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
            var stream: c.z_stream = undefined;
            stream.zalloc = null;
            stream.zfree = null;
            stream.@"opaque" = null;
            stream.next_in = @constCast(input.ptr);
            stream.avail_in = @as(c_uint, @intCast(input.len));

            if (c.inflateInit2(&stream, -15) != c.Z_OK) {
                return error.ZlibInitFailed;
            }
            defer _ = c.inflateEnd(&stream);

            var out = try std.ArrayList(u8).initCapacity(allocator, input.len * 4);
            defer out.deinit(allocator);

            const chunk_size = 1024 * 256;
            var chunk: [chunk_size]u8 = undefined;

            while (true) {
                stream.next_out = &chunk;
                stream.avail_out = chunk_size;

                const ret = c.inflate(&stream, c.Z_NO_FLUSH);
                const have = chunk_size - stream.avail_out;
                try out.appendSlice(allocator, chunk[0..have]);

                if (ret == c.Z_STREAM_END) break;
                if (ret != c.Z_OK) return error.ZlibInflateFailed;
            }

            return out.toOwnedSlice(allocator);
        }
    };
}
