const std = @import("std");

pub const user_agent = "libhttpclient/1.0.0.0";

pub const max_response_bytes: usize = 256 * 1024;

pub const Error = error{
    RequestFailed,
    UnexpectedStatus,
    ResponseTooLarge,
    InvalidJson,
    OutOfMemory,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpClient {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn getText(self: *HttpClient, url: []const u8) Error![]u8 {
        const buffer = try self.allocator.alloc(u8, max_response_bytes);
        errdefer self.allocator.free(buffer);

        var writer: std.Io.Writer = .fixed(buffer);
        const result = self.client.fetch(.{
            .keep_alive = false,
            .location = .{ .url = url },
            .response_writer = &writer,
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "user-agent", .value = user_agent },
            },
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ResponseTooLarge,
            else => return error.RequestFailed,
        };

        if (result.status != .ok) return error.UnexpectedStatus;
        return try self.allocator.realloc(buffer, writer.end);
    }

    pub fn getJson(self: *HttpClient, url: []const u8) Error!std.json.Parsed(std.json.Value) {
        const text = try self.getText(url);
        defer self.allocator.free(text);
        return std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch
            return error.InvalidJson;
    }
};
