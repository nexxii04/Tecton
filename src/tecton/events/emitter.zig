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
    const event_info = @typeInfo(Event).@"enum";
    const event_fields = event_info.field_names;

    const ListenerArrays = blk: {
        var names: [event_fields.len * 3][]const u8 = undefined;
        var field_types: [event_fields.len * 3]type = undefined;
        for (event_fields, 0..) |name, i| {
            names[i * 3] = name ++ "_pre";
            names[i * 3 + 1] = name ++ "_commit";
            names[i * 3 + 2] = name ++ "_post";
            const event: Event = @fromBackingInt(event_info.field_values[i]);
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
        idle_hook: ?*const fn (?*anyopaque) void = null,
        idle_userdata: ?*anyopaque = null,
        emit_depth: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            var listeners: ListenerArrays = undefined;
            inline for (event_fields) |name| {
                @field(listeners, name ++ "_pre") = .empty;
                @field(listeners, name ++ "_commit") = .empty;
                @field(listeners, name ++ "_post") = .empty;
            }
            return .{ .allocator = allocator, .listeners = listeners };
        }

        pub fn setIdleHook(self: *Self, hook: ?*const fn (?*anyopaque) void, userdata: ?*anyopaque) void {
            self.idle_hook = hook;
            self.idle_userdata = userdata;
        }

        pub fn isEmitting(self: *const Self) bool {
            return self.emit_depth > 0;
        }

        pub fn deinit(self: *Self) void {
            inline for (event_fields) |name| {
                @field(self.listeners, name ++ "_pre").deinit(self.allocator);
                @field(self.listeners, name ++ "_commit").deinit(self.allocator);
                @field(self.listeners, name ++ "_post").deinit(self.allocator);
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
            inline for (event_fields) |name| {
                self.removeOwnerFrom(&@field(self.listeners, name ++ "_pre"), owner_id);
                self.removeOwnerFrom(&@field(self.listeners, name ++ "_commit"), owner_id);
                self.removeOwnerFrom(&@field(self.listeners, name ++ "_post"), owner_id);
            }
        }

        pub fn removeOwnerFor(self: *Self, comptime event: Event, phase: EventPhase, owner_id: u32) void {
            self.removeOwnerFrom(self.listenerList(event, phase), owner_id);
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
            self.emit_depth += 1;
            defer {
                self.emit_depth -= 1;
                if (self.emit_depth == 0) {
                    if (self.idle_hook) |hook| hook(self.idle_userdata);
                }
            }
            context.event = event;
            context.cancelled = false;
            context.phase = .pre;
            const limit = self.next_order;
            var min_order: u64 = 0;
            var index: usize = 0;
            while (index < self.listenerList(event, .pre).items.len) {
                const listener = self.listenerList(event, .pre).items[index];
                if (listener.order < min_order or listener.order >= limit) {
                    index += 1;
                    continue;
                }

                min_order = listener.order + 1;
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
                if (index < self.listenerList(event, .pre).items.len and self.listenerList(event, .pre).items[index].order == listener.order) index += 1;
            }

            if (!context.cancelled) {
                context.phase = .commit;
                min_order = 0;
                index = 0;
                while (index < self.listenerList(event, .commit).items.len) {
                    const listener = self.listenerList(event, .commit).items[index];
                    if (listener.order < min_order or listener.order >= limit) {
                        index += 1;
                        continue;
                    }
                    min_order = listener.order + 1;
                    context.listener_userdata = listener.userdata;
                    if (listener.callback(context, data) != .continue_) {
                        context.cancelled = true;
                        break;
                    }

                    if (index < self.listenerList(event, .commit).items.len and self.listenerList(event, .commit).items[index].order == listener.order) index += 1;
                }
            }

            context.phase = .post;
            min_order = 0;
            index = 0;
            while (index < self.listenerList(event, .post).items.len) {
                const listener = self.listenerList(event, .post).items[index];
                if (listener.order < min_order or listener.order >= limit) {
                    index += 1;
                    continue;
                }
                min_order = listener.order + 1;
                context.listener_userdata = listener.userdata;
                _ = listener.callback(context, data);
                if (index < self.listenerList(event, .post).items.len and self.listenerList(event, .post).items[index].order == listener.order) index += 1;
            }
            context.listener_userdata = null;
            return !context.cancelled;
        }

        pub fn hasListeners(self: *const Self, comptime event: Event) bool {
            if (self.listenerListConst(event, .pre).items.len > 0) return true;
            if (self.listenerListConst(event, .commit).items.len > 0) return true;
            if (self.listenerListConst(event, .post).items.len > 0) return true;
            return false;
        }

        fn listenerListConst(self: *const Self, comptime event: Event, phase: EventPhase) *const std.ArrayList(Listener(event)) {
            return switch (phase) {
                .pre => &@field(self.listeners, @tagName(event) ++ "_pre"),
                .commit => &@field(self.listeners, @tagName(event) ++ "_commit"),
                .post => &@field(self.listeners, @tagName(event) ++ "_post"),
            };
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

test "entity events subscribe emit and report listener presence" {
    const Bus = Emitter();
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();

    try std.testing.expect(!bus.hasListeners(.EntityDamage));
    try std.testing.expect(!bus.hasListeners(.EntitySpawn));

    const callbacks = struct {
        var observed_amount: f32 = 0;

        fn reduce(_: *EventContext, damage: *types.EntityDamageEvent) EventResult {
            observed_amount = damage.amount;
            damage.amount = 1;
            return .continue_;
        }
    };

    _ = try bus.subscribe(.EntityDamage, .pre, 0, 1, callbacks.reduce);
    try std.testing.expect(bus.hasListeners(.EntityDamage));

    var damage = types.EntityDamageEvent{
        .target = @import("../ecs/entity_id.zig").EntityId{ .index = 3, .generation = 1, .kind = .mob },
        .target_runtime = 55,
        .amount = 5,
        .cause = .entity_attack,
    };
    try std.testing.expect(bus.emit(.EntityDamage, &damage));
    try std.testing.expectEqual(@as(f32, 5), callbacks.observed_amount);
    try std.testing.expectEqual(@as(f32, 1), damage.amount);

    var spawn = types.EntitySpawnEvent{ .id = .{ .index = 0, .generation = 1, .kind = .item }, .runtime_id = 60 };
    try std.testing.expect(bus.emit(.EntitySpawn, &spawn));
}
