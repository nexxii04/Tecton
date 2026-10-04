const std = @import("std");
const BinaryStream = @import("BinaryStream").BinaryStream;

/// Reusable serialization buffer; `begin` hands out an exclusive lease.
pub const ScratchBuffer = struct {
    stream: BinaryStream,
    held: bool = false,

    pub fn init(allocator: std.mem.Allocator) ScratchBuffer {
        return .{ .stream = BinaryStream.init(allocator, null, null) };
    }

    pub fn deinit(self: *ScratchBuffer) void {
        self.stream.deinit();
    }

    pub fn begin(self: *ScratchBuffer) Lease {
        std.debug.assert(!self.held);
        self.held = true;
        self.stream.reset();
        return .{ .buffer = self };
    }

    pub const Lease = struct {
        buffer: *ScratchBuffer,

        pub fn stream(self: Lease) *BinaryStream {
            return &self.buffer.stream;
        }

        pub fn deinit(self: Lease) void {
            self.buffer.held = false;
        }
    };
};

test "the scratch buffer is taken exclusively and starts empty" {
    const allocator = std.testing.allocator;
    var scratch = ScratchBuffer.init(allocator);
    defer scratch.deinit();

    {
        const lease = scratch.begin();
        defer lease.deinit();
        try std.testing.expect(scratch.held);
        try lease.stream().writeUint8(0xab);
        try lease.stream().writeUint8(0xcd);
        try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, lease.stream().getBuffer());
    }
    try std.testing.expect(!scratch.held);

    const second = scratch.begin();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), second.stream().getBuffer().len);
}
