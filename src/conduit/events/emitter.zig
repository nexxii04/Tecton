const std = @import("std");
const types = @import("types.zig");
const Event = types.Event;

pub fn Emitter() type {
    const event_fields = @typeInfo(Event).@"enum".fields;

    return struct {
        const Self = @This();

        const ListenerArrays = blk: {
            var field_names: [event_fields.len * 3][]const u8 = undefined;
            var field_types: [event_fields.len * 3]type = undefined;

            for (event_fields, 0..) |field, i| {
                const e: Event = @enumFromInt(field.value);
                const EventT = Event.DataType(e);
                const BeforeFn = *const fn (*EventT) bool;
                const OnFn = *const fn (*const EventT) void;
                const AfterFn = *const fn (*const EventT, bool) void;

                field_names[i * 3] = field.name ++ "_before";
                field_names[i * 3 + 1] = field.name ++ "_on";
                field_names[i * 3 + 2] = field.name ++ "_after";

                field_types[i * 3] = std.ArrayList(BeforeFn);
                field_types[i * 3 + 1] = std.ArrayList(OnFn);
                field_types[i * 3 + 2] = std.ArrayList(AfterFn);
            }

            break :blk @Struct(
                .auto,
                null,
                &field_names,
                &field_types,
                &@splat(.{}),
            );
        };

        allocator: std.mem.Allocator,
        listeners: ListenerArrays,

        pub fn init(allocator: std.mem.Allocator) Self {
            var listeners: ListenerArrays = undefined;
            inline for (event_fields) |field| {
                @field(listeners, field.name ++ "_before") = .empty;
                @field(listeners, field.name ++ "_on") = .empty;
                @field(listeners, field.name ++ "_after") = .empty;
            }
            return .{ .allocator = allocator, .listeners = listeners };
        }

        pub fn deinit(self: *Self) void {
            inline for (event_fields) |field| {
                @field(self.listeners, field.name ++ "_before").deinit(self.allocator);
                @field(self.listeners, field.name ++ "_on").deinit(self.allocator);
                @field(self.listeners, field.name ++ "_after").deinit(self.allocator);
            }
        }

        pub fn before(self: *Self, comptime event: Event, cb: BeforeFnType(event)) !void {
            try @field(self.listeners, @tagName(event) ++ "_before").append(self.allocator, cb);
        }

        pub fn on(self: *Self, comptime event: Event, cb: OnFnType(event)) !void {
            try @field(self.listeners, @tagName(event) ++ "_on").append(self.allocator, cb);
        }

        pub fn after(self: *Self, comptime event: Event, cb: AfterFnType(event)) !void {
            try @field(self.listeners, @tagName(event) ++ "_after").append(self.allocator, cb);
        }

        pub fn emit(self: *Self, comptime event: Event, data: *Event.DataType(event)) bool {
            const name = @tagName(event);
            var cancelled = false;

            for (@field(self.listeners, name ++ "_before").items) |cb| {
                if (!cb(data)) {
                    cancelled = true;
                    break;
                }
            }

            if (!cancelled) {
                for (@field(self.listeners, name ++ "_on").items) |cb| {
                    cb(data);
                }
            }

            for (@field(self.listeners, name ++ "_after").items) |cb| {
                cb(data, cancelled);
            }

            return !cancelled;
        }

        fn BeforeFnType(comptime event: Event) type {
            return *const fn (*Event.DataType(event)) bool;
        }

        fn OnFnType(comptime event: Event) type {
            return *const fn (*const Event.DataType(event)) void;
        }

        fn AfterFnType(comptime event: Event) type {
            return *const fn (*const Event.DataType(event), bool) void;
        }
    };
}
