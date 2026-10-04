const std = @import("std");
const types = @import("types.zig");
const Event = types.Event;

pub const EventPhase = enum { pre, commit, post };
pub const EventResult = enum { continue_, cancel, defer_ };

pub const Subscription = struct {
    owner_id: u32,
    event: Event,
    phase: EventPhase,
};

pub const EventContext = struct {
    event: Event,
    phase: EventPhase,
    tick: u64 = 0,
    cancelled: bool = false,
    listener_userdata: ?*anyopaque = null,
};

pub fn Listener(comptime event: Event) type {
    const Data = Event.DataType(event);
    return struct {
        callback: *const fn (*EventContext, *Data) EventResult,
        priority: i16,
        order: u64,
        owner_id: u32,
        userdata: ?*anyopaque,
    };
}

pub fn Emitter() type {
    const event_fields = @typeInfo(Event).@"enum".fields;

    const ListenerArrays = blk: {
        var names: [event_fields.len * 3][]const u8 = undefined;
        var field_types: [event_fields.len * 3]type = undefined;
        for (event_fields, 0..) |field, i| {
            names[i * 3] = field.name ++ "_pre";
            names[i * 3 + 1] = field.name ++ "_commit";
            names[i * 3 + 2] = field.name ++ "_post";
            const event: Event = @enumFromInt(field.value);
            field_types[i * 3] = std.ArrayList(Listener(event));
            field_types[i * 3 + 1] = std.ArrayList(Listener(event));
            field_types[i * 3 + 2] = std.ArrayList(Listener(event));
        }
        break :blk @Struct(.auto, null, &names, &field_types, &@splat(.{}));
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        listeners: ListenerArrays,
        next_order: u64 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            var listeners: ListenerArrays = undefined;
            inline for (event_fields) |field| {
                @field(listeners, field.name ++ "_pre") = .empty;
                @field(listeners, field.name ++ "_commit") = .empty;
                @field(listeners, field.name ++ "_post") = .empty;
            }
            return .{ .allocator = allocator, .listeners = listeners };
        }

        pub fn deinit(self: *Self) void {
            inline for (event_fields) |field| {
                @field(self.listeners, field.name ++ "_pre").deinit(self.allocator);
                @field(self.listeners, field.name ++ "_commit").deinit(self.allocator);
                @field(self.listeners, field.name ++ "_post").deinit(self.allocator);
            }
        }

        pub fn subscribe(
            self: *Self,
            comptime event: Event,
            phase: EventPhase,
            priority: i16,
            owner_id: u32,
            callback: *const fn (*EventContext, *Event.DataType(event)) EventResult,
        ) !Subscription {
            return self.subscribeWithContext(event, phase, priority, owner_id, callback, null);
        }

        pub fn subscribeWithContext(
            self: *Self,
            comptime event: Event,
            phase: EventPhase,
            priority: i16,
            owner_id: u32,
            callback: *const fn (*EventContext, *Event.DataType(event)) EventResult,
            userdata: ?*anyopaque,
        ) !Subscription {
            const list = self.listenerList(event, phase);
            const listener = Listener(event){
                .callback = callback,
                .priority = priority,
                .order = self.next_order,
                .owner_id = owner_id,
                .userdata = userdata,
            };
            self.next_order += 1;

            var index: usize = 0;
            while (index < list.items.len and list.items[index].priority >= priority) : (index += 1) {}
            try list.insert(self.allocator, index, listener);
            return .{ .owner_id = owner_id, .event = event, .phase = phase };
        }

        pub fn removeOwner(self: *Self, owner_id: u32) void {
            inline for (event_fields) |field| {
                self.removeOwnerFrom(&@field(self.listeners, field.name ++ "_pre"), owner_id);
                self.removeOwnerFrom(&@field(self.listeners, field.name ++ "_commit"), owner_id);
                self.removeOwnerFrom(&@field(self.listeners, field.name ++ "_post"), owner_id);
            }
        }

        fn removeOwnerFrom(self: *Self, list: anytype, owner_id: u32) void {
            _ = self;
            var index: usize = 0;
            while (index < list.items.len) {
                if (list.items[index].owner_id == owner_id) {
                    _ = list.orderedRemove(index);
                } else {
                    index += 1;
                }
            }
        }

        pub fn emit(self: *Self, comptime event: Event, data: *Event.DataType(event)) bool {
            var context = EventContext{ .event = event, .phase = .pre };
            return self.emitWithContext(event, data, &context);
        }

        pub fn emitWithContext(
            self: *Self,
            comptime event: Event,
            data: *Event.DataType(event),
            context: *EventContext,
        ) bool {
            context.event = event;
            context.cancelled = false;
            context.phase = .pre;
            const pre = self.listenerList(event, .pre);
            for (pre.items) |listener| {
                context.listener_userdata = listener.userdata;
                switch (listener.callback(context, data)) {
                    .cancel => {
                        context.cancelled = true;
                        break;
                    },
                    .defer_ => {
                        context.cancelled = true;
                        break;
                    },
                    .continue_ => {},
                }
            }

            if (!context.cancelled) {
                context.phase = .commit;
                const commit = self.listenerList(event, .commit);
                for (commit.items) |listener| {
                    context.listener_userdata = listener.userdata;
                    if (listener.callback(context, data) != .continue_) {
                        context.cancelled = true;
                        break;
                    }
                }
            }

            context.phase = .post;
            const post = self.listenerList(event, .post);
            for (post.items) |listener| {
                context.listener_userdata = listener.userdata;
                _ = listener.callback(context, data);
            }
            context.listener_userdata = null;
            return !context.cancelled;
        }

        fn listenerList(self: *Self, comptime event: Event, phase: EventPhase) *std.ArrayList(Listener(event)) {
            return switch (phase) {
                .pre => &@field(self.listeners, @tagName(event) ++ "_pre"),
                .commit => &@field(self.listeners, @tagName(event) ++ "_commit"),
                .post => &@field(self.listeners, @tagName(event) ++ "_post"),
            };
        }
    };
}

test "event phases honor priority and cancellation" {
    const Bus = Emitter();
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    const callbacks = struct {
        fn cancel(context: *EventContext, _: *types.ServerStartEvent) EventResult {
            context.tick = 10;
            return .cancel;
        }

        fn shouldNotRun(context: *EventContext, _: *types.ServerStartEvent) EventResult {
            context.tick = 99;
            return .continue_;
        }

        fn post(context: *EventContext, _: *types.ServerStartEvent) EventResult {
            context.tick += 1;
            return .continue_;
        }
    };

    _ = try bus.subscribe(.ServerStart, .pre, 100, 1, callbacks.cancel);
    _ = try bus.subscribe(.ServerStart, .pre, 0, 2, callbacks.shouldNotRun);
    _ = try bus.subscribe(.ServerStart, .post, 0, 1, callbacks.post);

    var event = types.ServerStartEvent{};
    var context = EventContext{ .event = .ServerStart, .phase = .pre };
    try std.testing.expect(!bus.emitWithContext(.ServerStart, &event, &context));
    try std.testing.expectEqual(@as(u64, 11), context.tick);
    try std.testing.expect(context.cancelled);
}
