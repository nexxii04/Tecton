const Protocol = @import("protocol");

pub const CompressionOptions = struct {
    compression_method: Protocol.CompressionMethod,
    compression_threshold: u16,
};
