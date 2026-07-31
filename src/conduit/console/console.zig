const std = @import("std");
const builtin = @import("builtin");

const Conduit = @import("../conduit.zig").Conduit;

const INPUT_MAX = 256;
const RING_CAPACITY = 128;
const HISTORY_MAX = 32;
const PROMPT = "\x1b[92m>\x1b[0m ";

const TermState = switch (builtin.os.tag) {
    .windows => u32,
    else => std.posix.termios,
};

pub const Console = struct {
    allocator: std.mem.Allocator,
    conduit: *Conduit,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    ring_data: [RING_CAPACITY][INPUT_MAX]u8 = undefined,
    ring_len: [RING_CAPACITY]usize = undefined,
    ring_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    ring_tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    orig_termios: TermState = undefined,
    is_raw: bool = false,

    buf: [INPUT_MAX]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    hist_data: [HISTORY_MAX][INPUT_MAX]u8 = undefined,
    hist_len: [HISTORY_MAX]usize = undefined,
    hist_count: usize = 0,
    hist_idx: usize = 0,

    pub fn start(self: *Console, conduit: *Conduit) !void {
        self.* = .{
            .allocator = conduit.allocator,
            .conduit = conduit,
            .thread = null,
            .running = std.atomic.Value(bool).init(true),
        };

        self.is_raw = enableRawMode(&self.orig_termios);
        self.thread = try std.Thread.spawn(.{}, stdinReaderThread, .{self});
    }

    pub fn deinit(self: *Console) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.is_raw) {
            disableRawMode(&self.orig_termios);
            self.is_raw = false;
        }
    }

    pub fn drainCommands(self: *Console) void {
        const registry = &self.conduit.command_registry;
        var local_buf: [INPUT_MAX]u8 = undefined;
        var processed = false;
        while (self.pop(&local_buf)) |line| {
            processed = true;
            registry.dispatchConsole(self.conduit, line);
        }
        if (processed) self.showPrompt();
    }

    fn stdinReaderThread(self: *Console) void {
        if (self.is_raw) self.showPrompt();

        while (self.running.load(.acquire)) {
            if (!waitStdin()) continue;

            if (self.is_raw) {
                if (readChar()) |ch| {
                    self.handleChar(ch);
                } else break;
            } else {
                if (readLineCooked()) |line| {
                    _ = self.push(line);
                } else break;
            }
        }
    }

    fn handleChar(self: *Console, ch: u8) void {
        switch (ch) {
            0x03 => {
                const cmd = "stop";
                @memcpy(self.buf[0..cmd.len], cmd);
                self.len = cmd.len;
                self.cursor = cmd.len;
                self.doEnter();
            },
            0x08, 0x7F => self.doBackspace(),
            0x0A, 0x0D => self.doEnter(),
            0x01 => {
                self.cursor = 0;
                self.redraw();
            },
            0x05 => {
                self.cursor = self.len;
                self.redraw();
            },
            0x0B => {
                self.len = self.cursor;
                self.redraw();
            },
            0x15 => {
                self.clearInput();
                self.showPrompt();
            },
            0x0C => {
                std.debug.print("\x1b[2J\x1b[H", .{});
                self.showPrompt();
                self.redraw();
            },
            0x1B => self.handleEscape(),
            0x20...0x7E => self.insertChar(ch),
            else => {},
        }
    }

    fn handleEscape(self: *Console) void {
        if (!waitEscapeSeq()) return;
        const b0 = readEscapeByte() orelse return;
        if (b0 != '[') return;
        const b1 = readEscapeByte() orelse return;

        switch (b1) {
            'A' => self.doHistoryUp(),
            'B' => self.doHistoryDown(),
            'C' => self.doCursorRight(),
            'D' => self.doCursorLeft(),
            else => {},
        }
    }

    fn insertChar(self: *Console, ch: u8) void {
        if (self.len >= INPUT_MAX) return;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = ch;
        self.cursor += 1;
        self.len += 1;
        self.redraw();
    }

    fn doBackspace(self: *Console) void {
        if (self.cursor == 0) return;
        var i = self.cursor - 1;
        while (i < self.len - 1) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.cursor -= 1;
        self.len -= 1;
        self.redraw();
    }

    fn doEnter(self: *Console) void {
        const cmd = self.buf[0..self.len];
        std.debug.print("\r\x1b[2K", .{});
        if (cmd.len > 0) {
            std.debug.print("{s}{s}\n", .{ PROMPT, cmd });
            _ = self.push(cmd);
            self.addHistory(cmd);
        } else {
            self.showPrompt();
        }
        self.len = 0;
        self.cursor = 0;
        self.hist_idx = 0;
    }

    fn doCursorLeft(self: *Console) void {
        if (self.cursor > 0) {
            self.cursor -= 1;
            self.redraw();
        }
    }

    fn doCursorRight(self: *Console) void {
        if (self.cursor < self.len) {
            self.cursor += 1;
            self.redraw();
        }
    }

    fn doHistoryUp(self: *Console) void {
        if (self.hist_count == 0) return;
        if (self.hist_idx < self.hist_count) self.hist_idx += 1;
        self.loadHistory();
    }

    fn doHistoryDown(self: *Console) void {
        if (self.hist_idx > 0) self.hist_idx -= 1;
        self.loadHistory();
    }

    fn loadHistory(self: *Console) void {
        if (self.hist_idx == 0) {
            self.len = 0;
            self.cursor = 0;
        } else {
            const idx = self.hist_idx - 1;
            const cmd_len = self.hist_len[idx];
            @memcpy(self.buf[0..cmd_len], self.hist_data[idx][0..cmd_len]);
            self.len = cmd_len;
            self.cursor = cmd_len;
        }
        self.redraw();
    }

    fn addHistory(self: *Console, cmd: []const u8) void {
        if (self.hist_count > 0) {
            const prev = self.hist_data[self.hist_count - 1][0..self.hist_len[self.hist_count - 1]];
            if (std.mem.eql(u8, prev, cmd)) return;
        }
        if (self.hist_count == HISTORY_MAX) {
            var i: usize = 0;
            while (i < HISTORY_MAX - 1) : (i += 1) {
                @memcpy(self.hist_data[i][0..self.hist_len[i + 1]], self.hist_data[i + 1][0..self.hist_len[i + 1]]);
                self.hist_len[i] = self.hist_len[i + 1];
            }
            self.hist_len[HISTORY_MAX - 1] = 0;
        } else {
            self.hist_count += 1;
        }
        const idx = self.hist_count - 1;
        @memcpy(self.hist_data[idx][0..cmd.len], cmd);
        self.hist_len[idx] = cmd.len;
    }

    fn clearInput(self: *Console) void {
        std.debug.print("\r\x1b[2K", .{});
        self.len = 0;
        self.cursor = 0;
    }

    fn showPrompt(_: *Console) void {
        std.debug.print("{s}", .{PROMPT});
    }

    fn redraw(self: *Console) void {
        std.debug.print("\r\x1b[2K{s}{s}", .{ PROMPT, self.buf[0..self.len] });
        if (self.cursor < self.len) {
            std.debug.print("\x1b[{d}D", .{self.len - self.cursor});
        }
    }

    fn push(self: *Console, bytes: []const u8) bool {
        if (bytes.len > INPUT_MAX) return false;
        const h = self.ring_head.load(.acquire);
        const t = self.ring_tail.load(.acquire);
        const next = (h + 1) % RING_CAPACITY;
        if (next == t) return false;
        @memcpy(self.ring_data[h][0..bytes.len], bytes);
        self.ring_len[h] = bytes.len;
        self.ring_head.store(next, .release);
        return true;
    }

    fn pop(self: *Console, out: *[INPUT_MAX]u8) ?[]const u8 {
        const t = self.ring_tail.load(.acquire);
        const h = self.ring_head.load(.acquire);
        if (t == h) return null;
        const len = self.ring_len[t];
        @memcpy(out[0..len], self.ring_data[t][0..len]);
        self.ring_tail.store((t + 1) % RING_CAPACITY, .release);
        return out[0..len];
    }
};

// --- Platform-specific I/O ---

const Kernel32 = struct {
    const w32 = std.os.windows;
    const STD_INPUT_HANDLE: w32.DWORD = @bitCast(@as(i32, -10));
    const STD_OUTPUT_HANDLE: w32.DWORD = @bitCast(@as(i32, -11));
    const ENABLE_ECHO_INPUT = 0x0004;
    const ENABLE_LINE_INPUT = 0x0002;
    const ENABLE_PROCESSED_INPUT = 0x0001;
    const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
    const WAIT_OBJECT_0: w32.DWORD = 0;

    extern "kernel32" fn GetStdHandle(nStdHandle: w32.DWORD) callconv(.winapi) w32.HANDLE;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: w32.HANDLE, lpMode: *w32.DWORD) callconv(.winapi) w32.BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: w32.HANDLE, dwMode: w32.DWORD) callconv(.winapi) w32.BOOL;
    extern "kernel32" fn ReadConsoleW(
        hConsoleInput: w32.HANDLE,
        lpBuffer: [*]u16,
        nNumberOfCharsToRead: w32.DWORD,
        lpNumberOfCharsRead: *w32.DWORD,
        pInputControl: ?*anyopaque,
    ) callconv(.winapi) w32.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: w32.HANDLE, dwMilliseconds: w32.DWORD) callconv(.winapi) w32.DWORD;
};

fn enableRawMode(orig: *TermState) bool {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return false;

            var mode: u32 = undefined;
            if (Kernel32.GetConsoleMode(stdin_handle, &mode) == .FALSE) return false;
            orig.* = mode;

            var new_mode = mode;
            const disable_mask: u32 = Kernel32.ENABLE_ECHO_INPUT | Kernel32.ENABLE_LINE_INPUT | Kernel32.ENABLE_PROCESSED_INPUT;
            new_mode &= ~disable_mask;
            new_mode |= Kernel32.ENABLE_VIRTUAL_TERMINAL_INPUT;
            if (Kernel32.SetConsoleMode(stdin_handle, new_mode) == .FALSE) return false;

            const stdout_handle = Kernel32.GetStdHandle(Kernel32.STD_OUTPUT_HANDLE);
            if (stdout_handle != std.os.windows.INVALID_HANDLE_VALUE) {
                var out_mode: u32 = undefined;
                if (Kernel32.GetConsoleMode(stdout_handle, &out_mode) != .FALSE) {
                    out_mode |= Kernel32.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
                    _ = Kernel32.SetConsoleMode(stdout_handle, out_mode);
                }
            }

            return true;
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            const termios = std.posix.tcgetattr(stdin_fd) catch return false;
            orig.* = termios;
            var raw = termios;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch return false;
            return true;
        },
    }
}

fn disableRawMode(orig: *const TermState) void {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle != std.os.windows.INVALID_HANDLE_VALUE) {
                _ = Kernel32.SetConsoleMode(stdin_handle, orig.*);
            }
        },
        else => {
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig.*) catch {};
        },
    }
}

fn waitStdin() bool {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return false;
            return Kernel32.WaitForSingleObject(stdin_handle, 100) == Kernel32.WAIT_OBJECT_0;
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            var pfd = [1]std.posix.pollfd{
                .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            return (std.posix.poll(&pfd, 100) catch return false) > 0;
        },
    }
}

fn readChar() ?u8 {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return null;

            var buf: [1]u16 = undefined;
            var nread: u32 = 0;
            if (Kernel32.ReadConsoleW(stdin_handle, &buf, 1, &nread, null) == .FALSE or nread == 0) return null;
            if (buf[0] > 0x7F) return null;

            return @as(u8, @truncate(buf[0]));
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            var ch: [1]u8 = undefined;
            return if (std.posix.read(stdin_fd, ch[0..])) |n|
                if (n > 0) ch[0] else null
            else |_|
                null;
        },
    }
}

fn waitEscapeSeq() bool {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return false;
            return Kernel32.WaitForSingleObject(stdin_handle, 10) == Kernel32.WAIT_OBJECT_0;
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            var pfd = [1]std.posix.pollfd{
                .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            return (std.posix.poll(&pfd, 10) catch return false) > 0;
        },
    }
}

fn readEscapeByte() ?u8 {
    switch (builtin.os.tag) {
        .windows => {
            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return null;

            var buf: [1]u16 = undefined;
            var nread: u32 = 0;
            if (Kernel32.ReadConsoleW(stdin_handle, &buf, 1, &nread, null) == .FALSE or nread == 0) return null;
            if (buf[0] > 0x7F) return null;

            return @as(u8, @truncate(buf[0]));
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            var b: [1]u8 = undefined;
            return if (std.posix.read(stdin_fd, b[0..])) |n|
                if (n > 0) b[0] else null
            else |_|
                null;
        },
    }
}

fn readLineCooked() ?[]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            var static_buf: [4096]u16 = undefined;

            const stdin_handle = Kernel32.GetStdHandle(Kernel32.STD_INPUT_HANDLE);
            if (stdin_handle == std.os.windows.INVALID_HANDLE_VALUE) return null;

            var nread: u32 = 0;
            if (Kernel32.ReadConsoleW(stdin_handle, &static_buf, static_buf.len, &nread, null) == .FALSE or nread == 0) return null;

            return null;
        },
        else => {
            const stdin_fd = std.posix.STDIN_FILENO;
            var static_buf: [4096]u8 = undefined;
            const n = std.posix.read(stdin_fd, &static_buf) catch return null;
            if (n <= 0) return null;
            return static_buf[0..n];
        },
    }
}
