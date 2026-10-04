pub const Emitter = @import("emitter.zig").Emitter;
pub const EventContext = @import("emitter.zig").EventContext;
pub const EventPhase = @import("emitter.zig").EventPhase;
pub const EventResult = @import("emitter.zig").EventResult;
pub const Subscription = @import("emitter.zig").Subscription;
pub const types = @import("types.zig");
pub const Event = types.Event;

pub const Events = Emitter();
