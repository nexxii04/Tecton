const keys = @import("keys.zig");
const Put = keys.Put;

pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, puts: []const Put, deletes: []const []u8) anyerror!void,
};

pub const Stats = struct {
    written: u64 = 0,
    dropped: u64 = 0,
    retries: u64 = 0,
    keyed: u64 = 0,

    coalesced: u64 = 0,

    requeued: u64 = 0,
    ordered: u64 = 0,

    rejected: u64 = 0,
    pending_now: usize = 0,
    pending_peak: usize = 0,
    reads_lock_free: u64 = 0,
    reads_locked: u64 = 0,
    reads_waited: u64 = 0,
};
