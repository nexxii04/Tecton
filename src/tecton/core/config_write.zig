const std = @import("std");

pub fn Methods(comptime ServerProperties: type, comptime comments: anytype) type {
    return struct {
        pub fn save(self: *const ServerProperties, io: std.Io, path: []const u8) !void {
            var buf: [8192]u8 = undefined;
            var pos: usize = 0;

            inline for (@typeInfo(ServerProperties).@"struct".field_names, @typeInfo(ServerProperties).@"struct".field_types) |name, FieldType| {
                if (comptime std.mem.eql(u8, name, "allocator") or
                    std.mem.eql(u8, name, "_allocated_strings")) continue;

                const file_key = comptime blk: {
                    var name_buf: [name.len]u8 = undefined;
                    @memcpy(&name_buf, name);
                    std.mem.replaceScalar(u8, &name_buf, '_', '-');
                    break :blk name_buf;
                };

                if (@hasField(@TypeOf(comments), name)) {
                    const comment = std.fmt.bufPrint(buf[pos..], "# {s}\n", .{@field(comments, name)}) catch return error.BufferOverflow;
                    pos += comment.len;
                }

                const val = @field(self, name);
                const line = if (FieldType == []const u8)
                    std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, val }) catch return error.BufferOverflow
                else if (FieldType == bool)
                    std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, if (val) "true" else "false" }) catch return error.BufferOverflow
                else if (@typeInfo(FieldType) == .@"enum")
                    std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ file_key, @tagName(val) }) catch return error.BufferOverflow
                else if (@typeInfo(FieldType) == .int)
                    std.fmt.bufPrint(buf[pos..], "{s}={d}\n", .{ file_key, val }) catch return error.BufferOverflow
                else
                    unreachable;
                pos += line.len;
            }

            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            var write_buf: [8194]u8 = undefined;
            var writer = file.writer(io, &write_buf);
            writer.interface.writeAll(buf[0..pos]) catch return error.WriteError;
            writer.interface.flush() catch |err| {
                std.log.err("failed to flush writer: {}", .{err});
            };
        }
    };
}
