const std = @import("std");
const args = @import("floating_text_args.zig");

pub fn send_text_args_error(ctx: anytype, err: args.AddArgsError, usage: []const u8) void {
    switch (err) {
        error.MissingName => ctx.sendOutput(false, usage),
        error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
        error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
        error.MissingText => ctx.sendOutput(false, "Floating text cannot be empty"),
        error.TextTooLong => ctx.sendOutput(false, "Floating text is too long"),
    }
}

pub fn send_text_error(ctx: anytype, err: args.TextError) void {
    switch (err) {
        error.EmptyText => ctx.sendOutput(false, "Floating text cannot be empty"),
        error.InvalidText => ctx.sendOutput(false, "Floating text contains invalid characters"),
    }
}

pub fn report_not_found(ctx: anytype, name: []const u8) void {
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Floating text '{s}' not found", .{name}) catch return;
    ctx.sendOutput(false, msg);
}

pub fn send_name_error(ctx: anytype, err: args.NameError, usage: []const u8) void {
    switch (err) {
        error.MissingName => ctx.sendOutput(false, usage),
        error.InvalidName => ctx.sendOutput(false, "Name may only contain letters, numbers, '_', '-' and '.'"),
        error.NameTooLong => ctx.sendOutput(false, "Name must be 32 characters or less"),
    }
}
