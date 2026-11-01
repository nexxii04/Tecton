const std = @import("std");
const builtin = @import("builtin");

const mbedtls = @import("mbedtls");
const log = @import("../core/log.zig");

const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;

const poll_slice_ms: i32 = 500;

/// Polling before accept is what makes closing the listener on stop safe.
const accept_poll_ms: i32 = 20;

pub const Options = struct {
    bind: IpAddress,
    backend: IpAddress,
    cert_path: []const u8,
    key_path: []const u8,
    max_connections: u32 = 64,
    handshake_timeout_ms: u32 = 15_000,
    idle_timeout_ms: u32 = 60_000,
    write_timeout_ms: u32 = 30_000,
    close_timeout_ms: u32 = 1_000,
};

/// Signaling front: one accept thread holds the public port and each connection gets
/// one relay thread. It sniffs the first record so the same port serves TLS and plain
/// HTTP; the relay uses `poll`, so `native` is POSIX only.
pub const Front = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    crt: mbedtls.mbedtls_x509_crt,
    key: mbedtls.mbedtls_pk_context,
    entropy: mbedtls.mbedtls_entropy_context,
    drbg: mbedtls.mbedtls_ctr_drbg_context,
    conf: mbedtls.mbedtls_ssl_config,
    /// mbedTLS calls the DRBG from every handshake thread; serialize it.
    rng_mutex: std.Io.Mutex = .init,
    alpn: [2][*c]const u8 = .{ "http/1.1", null },
    server: ?std.Io.net.Server = null,
    group: std.Io.Group = .init,
    running: std.atomic.Value(bool) = .init(false),
    connections: std.ArrayList(*Connection) = .empty,
    connections_mutex: std.Io.Mutex = .init,
    open_connections: std.atomic.Value(u32) = .init(0),
    bound_port: u16 = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !*Front {
        if (comptime builtin.os.tag == .windows) {
            log.err("tls-mode=native needs a POSIX host: Zig 0.16 exposes no pollable handle for Windows sockets", .{});
            return error.TlsNativeUnsupported;
        }

        const self = try allocator.create(Front);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .options = options,
            .crt = undefined,
            .key = undefined,
            .entropy = undefined,
            .drbg = undefined,
            .conf = undefined,
        };
        mbedtls.mbedtls_x509_crt_init(&self.crt);
        mbedtls.mbedtls_pk_init(&self.key);
        mbedtls.mbedtls_entropy_init(&self.entropy);
        mbedtls.mbedtls_ctr_drbg_init(&self.drbg);
        mbedtls.mbedtls_ssl_config_init(&self.conf);
        errdefer {
            self.releaseResources();
            allocator.destroy(self);
        }

        const cert_pem = try readPem(io, allocator, options.cert_path, "certificate");
        defer allocator.free(cert_pem);
        if (mbedtls.mbedtls_x509_crt_parse(&self.crt, cert_pem.ptr, cert_pem.len + 1) != 0) {
            reportConfigError("tls-cert {s} is not a PEM certificate chain", .{options.cert_path});
            return error.TlsCertificateInvalid;
        }

        const personal = "tecton-signaling";
        if (mbedtls.mbedtls_ctr_drbg_seed(&self.drbg, mbedtls.mbedtls_entropy_func, &self.entropy, personal.ptr, personal.len) != 0) {
            return error.TlsEntropyUnavailable;
        }

        const key_pem = try readPem(io, allocator, options.key_path, "private key");
        defer allocator.free(key_pem);
        if (mbedtls.mbedtls_pk_parse_key(&self.key, key_pem.ptr, key_pem.len + 1, null, 0, mbedtls.mbedtls_ctr_drbg_random, &self.drbg) != 0) {
            reportConfigError("tls-key {s} is not a PEM private key", .{options.key_path});
            return error.TlsKeyInvalid;
        }

        if (mbedtls.mbedtls_ssl_config_defaults(
            &self.conf,
            mbedtls.MBEDTLS_SSL_IS_SERVER,
            mbedtls.MBEDTLS_SSL_TRANSPORT_STREAM,
            mbedtls.MBEDTLS_SSL_PRESET_DEFAULT,
        ) != 0) {
            return error.TlsConfigFailed;
        }
        mbedtls.mbedtls_ssl_conf_authmode(&self.conf, mbedtls.MBEDTLS_SSL_VERIFY_NONE);
        mbedtls.mbedtls_ssl_conf_rng(&self.conf, rngCallback, self);
        if (mbedtls.mbedtls_ssl_conf_own_cert(&self.conf, &self.crt, &self.key) != 0) {
            reportConfigError("tls-key {s} does not match tls-cert {s}", .{ options.key_path, options.cert_path });
            return error.TlsKeyMismatch;
        }
        if (mbedtls.mbedtls_ssl_conf_alpn_protocols(&self.conf, @ptrCast(@constCast(&self.alpn))) != 0) {
            return error.TlsConfigFailed;
        }
        return self;
    }

    pub fn start(self: *Front) !void {
        if (self.server != null) return;
        self.server = self.options.bind.listen(self.io, .{ .reuse_address = true }) catch |err| {
            log.err("TLS front cannot bind {f}: {s}", .{ self.options.bind, @errorName(err) });
            return err;
        };
        self.bound_port = self.server.?.socket.address.getPort();
        self.running.store(true, .release);
        self.group.concurrent(self.io, acceptLoop, .{self}) catch |err| {
            self.running.store(false, .release);
            self.server.?.deinit(self.io);
            self.server = null;
            return err;
        };
        log.info("Signaling front: TLS and plain HTTP on {f}, forwarding to {f}", .{
            self.server.?.socket.address,
            self.options.backend,
        });
    }

    /// Stops accepting, unblocks relays and joins threads. Idempotent.
    pub fn stop(self: *Front) void {
        if (self.server == null) return;
        self.running.store(false, .release);
        self.shutdownConnections();
        // Join the accept thread before closing the listener.
        self.group.await(self.io) catch {};
        self.server.?.deinit(self.io);
        self.server = null;
    }

    pub fn deinit(self: *Front) void {
        self.stop();
        self.connections.deinit(self.allocator);
        self.releaseResources();
        self.allocator.destroy(self);
    }

    pub fn boundPort(self: *const Front) u16 {
        return self.bound_port;
    }

    fn releaseResources(self: *Front) void {
        mbedtls.mbedtls_ssl_config_free(&self.conf);
        mbedtls.mbedtls_ctr_drbg_free(&self.drbg);
        mbedtls.mbedtls_entropy_free(&self.entropy);
        mbedtls.mbedtls_pk_free(&self.key);
        mbedtls.mbedtls_x509_crt_free(&self.crt);
    }

    fn acceptLoop(self: *Front) void {
        if (comptime builtin.os.tag == .windows) return;
        while (self.running.load(.acquire)) {
            const server = if (self.server) |*live| live else return;
            var fds = [1]std.posix.pollfd{
                .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const pending = std.posix.poll(&fds, accept_poll_ms) catch {
                self.io.sleep(.fromMilliseconds(10), .awake) catch return;
                continue;
            };
            if (pending == 0) continue;
            const client = server.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) return;
                log.warn("TLS front accept failed: {s}", .{@errorName(err)});
                self.io.sleep(.fromMilliseconds(10), .awake) catch return;
                continue;
            };
            if (!self.running.load(.acquire)) {
                client.close(self.io);
                return;
            }
            if (self.open_connections.load(.acquire) >= self.options.max_connections) {
                log.warn("TLS front closed a new connection: {d} of {d} already open", .{
                    self.open_connections.load(.acquire),
                    self.options.max_connections,
                });
                client.close(self.io);
                continue;
            }
            self.group.concurrent(self.io, serve, .{ self, client }) catch {
                client.close(self.io);
                continue;
            };
        }
    }

    fn serve(self: *Front, client: Stream) void {
        const conn = self.allocator.create(Connection) catch {
            client.close(self.io);
            return;
        };
        conn.* = .{
            .front = self,
            .client = client,
            .backend = undefined,
            .backend_connected = .init(false),
            .ssl = undefined,
            .handshake_deadline = std.Io.Timestamp.now(self.io, .awake)
                .addDuration(.fromMilliseconds(@max(1, self.options.handshake_timeout_ms))),
            .write_deadline_override = null,
            .read_timeout_ms = @max(500, self.options.handshake_timeout_ms),
        };
        preventSigPipe(client.socket.handle);
        setNoDelay(client.socket.handle);
        // Unregister before closing: stop shuts down whatever is still listed.
        defer self.allocator.destroy(conn);
        defer {
            if (conn.backend_connected.load(.acquire)) conn.backend.close(self.io);
            client.close(self.io);
        }
        defer self.unregister(conn);
        if (!self.register(conn)) {
            log.warn("TLS front dropped a connection: out of memory", .{});
            return;
        }
        conn.run();
    }

    fn register(self: *Front, conn: *Connection) bool {
        self.connections_mutex.lockUncancelable(self.io);
        defer self.connections_mutex.unlock(self.io);
        self.connections.append(self.allocator, conn) catch return false;
        _ = self.open_connections.fetchAdd(1, .monotonic);
        return true;
    }

    fn unregister(self: *Front, conn: *Connection) void {
        self.connections_mutex.lockUncancelable(self.io);
        defer self.connections_mutex.unlock(self.io);
        for (self.connections.items, 0..) |item, index| {
            if (item != conn) continue;
            _ = self.connections.swapRemove(index);
            _ = self.open_connections.fetchSub(1, .monotonic);
            return;
        }
    }

    fn openConnectionCount(self: *const Front) u32 {
        return self.open_connections.load(.acquire);
    }

    fn shutdownConnections(self: *Front) void {
        self.connections_mutex.lockUncancelable(self.io);
        defer self.connections_mutex.unlock(self.io);
        for (self.connections.items) |conn| conn.shutdownStreams();
    }

    fn rngCallback(raw: ?*anyopaque, out: [*c]u8, len: usize) callconv(.c) c_int {
        const self: *Front = @ptrCast(@alignCast(raw.?));
        self.rng_mutex.lockUncancelable(self.io);
        defer self.rng_mutex.unlock(self.io);
        return mbedtls.mbedtls_ctr_drbg_random(&self.drbg, out, len);
    }
};

const PeerKind = enum { tls, http };

const Connection = struct {
    front: *Front,
    client: Stream,
    backend: Stream,
    backend_connected: std.atomic.Value(bool),
    ssl: mbedtls.mbedtls_ssl_context,
    /// Absolute handshake deadline; cleared after success.
    handshake_deadline: ?std.Io.Timestamp,
    /// Short deadline for `close_notify`.
    write_deadline_override: ?std.Io.Timestamp,
    read_timeout_ms: u32,

    fn run(self: *Connection) void {
        const kind = self.classify() catch return;
        switch (kind) {
            .tls => self.runTls(),
            .http => self.runPlain(),
        }
    }

    /// A TLS ClientHello starts with a handshake record; anything else is worth handing to
    /// the HTTP listener. `peek` leaves the bytes for whichever path takes over.
    fn classify(self: *Connection) !PeerKind {
        if (comptime builtin.os.tag == .windows) return error.TlsNativeUnsupported;
        const io = self.front.io;
        var waited_ms: u32 = 0;
        while (self.front.running.load(.acquire)) {
            const slice_ms = self.readSliceMs(io, waited_ms) orelse return error.Timeout;
            var fds = [1]std.posix.pollfd{
                .{ .fd = self.client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, slice_ms) catch return error.ConnectionClosed;
            if (ready == 0) {
                waited_ms += @intCast(slice_ms);
                continue;
            }

            var first: [3]u8 = undefined;
            const count = peek(self.client.socket.handle, &first) catch |err| switch (err) {
                error.Interrupted => continue,
                error.WouldBlock => {
                    waited_ms += @intCast(@min(slice_ms, poll_slice_ms));
                    continue;
                },
                error.ConnectionClosed => return error.ConnectionClosed,
            };
            if (count >= 3 and first[0] == 0x16 and first[1] == 0x03) return .tls;
            return .http;
        }
        return error.ConnectionClosed;
    }

    fn connectBackend(self: *Connection) bool {
        self.backend = self.front.options.backend.connect(self.front.io, .{ .mode = .stream }) catch |err| {
            log.warn("signaling front could not reach the loopback listener at {f}: {s}", .{
                self.front.options.backend,
                @errorName(err),
            });
            return false;
        };
        preventSigPipe(self.backend.socket.handle);
        setNoDelay(self.backend.socket.handle);
        self.backend_connected.store(true, .release);
        return true;
    }

    fn runTls(self: *Connection) void {
        const io = self.front.io;
        mbedtls.mbedtls_ssl_init(&self.ssl);
        defer mbedtls.mbedtls_ssl_free(&self.ssl);
        if (mbedtls.mbedtls_ssl_setup(&self.ssl, &self.front.conf) != 0) {
            log.warn("TLS front could not start a session", .{});
            return;
        }
        mbedtls.mbedtls_ssl_set_bio(&self.ssl, self, bioSend, bioRecv, null);

        const handshake = mbedtls.mbedtls_ssl_handshake(&self.ssl);
        if (handshake != 0) {
            log.debug("TLS handshake failed: {d}", .{handshake});
            return;
        }
        self.handshake_deadline = null;
        if (!self.connectBackend()) return;

        self.read_timeout_ms = @max(500, self.front.options.idle_timeout_ms);
        self.relay();
        self.write_deadline_override = std.Io.Timestamp.now(io, .awake)
            .addDuration(.fromMilliseconds(@max(1, self.front.options.close_timeout_ms)));
        _ = mbedtls.mbedtls_ssl_close_notify(&self.ssl);
        self.write_deadline_override = null;
    }

    fn runPlain(self: *Connection) void {
        self.handshake_deadline = null;
        if (!self.connectBackend()) return;
        self.read_timeout_ms = @max(500, self.front.options.idle_timeout_ms);
        self.relayPlain();
    }

    fn relay(self: *Connection) void {
        if (comptime builtin.os.tag == .windows) return;
        self.relayPolled();
    }

    fn relayPlain(self: *Connection) void {
        if (comptime builtin.os.tag == .windows) return;
        const io = self.front.io;
        var buffer: [16 * 1024]u8 = undefined;
        var idle_ms: u32 = 0;
        const events: i16 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;

        while (self.front.running.load(.acquire)) {
            var fds = [2]std.posix.pollfd{
                .{ .fd = self.client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.backend.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, poll_slice_ms) catch return;
            if (ready == 0) {
                idle_ms += @intCast(poll_slice_ms);
                if (idle_ms >= self.front.options.idle_timeout_ms) return;
                continue;
            }
            idle_ms = 0;

            if (fds[0].revents & events != 0) {
                const read = readStream(io, self.client.socket.handle, &buffer) catch return;
                if (read == 0) return;
                writeAllBounded(
                    io,
                    self.backend.socket.handle,
                    buffer[0..read],
                    self.writeDeadline(),
                    &self.front.running,
                ) catch return;
            }
            if (fds[1].revents & events != 0) {
                const read = readStream(io, self.backend.socket.handle, &buffer) catch return;
                if (read == 0) return;
                writeAllBounded(
                    io,
                    self.client.socket.handle,
                    buffer[0..read],
                    self.writeDeadline(),
                    &self.front.running,
                ) catch return;
            }
        }
    }

    /// Both directions run on this thread; only it touches `ssl`.
    fn relayPolled(self: *Connection) void {
        const io = self.front.io;
        var buffer: [16 * 1024]u8 = undefined;
        var idle_ms: u32 = 0;
        const events: i16 = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR;

        while (self.front.running.load(.acquire)) {
            if (mbedtls.mbedtls_ssl_get_bytes_avail(&self.ssl) > 0) {
                if (!self.pumpClient(&buffer)) return;
                continue;
            }

            var fds = [2]std.posix.pollfd{
                .{ .fd = self.client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.backend.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, poll_slice_ms) catch return;
            if (ready == 0) {
                idle_ms += @intCast(poll_slice_ms);
                if (idle_ms >= self.front.options.idle_timeout_ms) return;
                continue;
            }
            idle_ms = 0;

            if (fds[1].revents & events != 0) {
                const read = readStream(io, self.backend.socket.handle, &buffer) catch return;
                if (read == 0) return;
                if (!self.writeTls(buffer[0..read])) return;
            }
            if (fds[0].revents & events != 0) {
                if (!self.pumpClient(&buffer)) return;
            }
        }
    }

    fn pumpClient(self: *Connection, buffer: []u8) bool {
        const read = mbedtls.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);
        if (read <= 0) return false;
        writeAllBounded(
            self.front.io,
            self.backend.socket.handle,
            buffer[0..@intCast(read)],
            self.writeDeadline(),
            &self.front.running,
        ) catch return false;
        return true;
    }

    fn writeDeadline(self: *Connection) std.Io.Timestamp {
        if (self.write_deadline_override) |deadline| return deadline;
        if (self.handshake_deadline) |deadline| return deadline;
        const timeout = @max(1, self.front.options.write_timeout_ms);
        return std.Io.Timestamp.now(self.front.io, .awake)
            .addDuration(.fromMilliseconds(timeout));
    }

    fn writeTls(self: *Connection, bytes: []const u8) bool {
        var written: usize = 0;
        while (written < bytes.len) {
            const count = mbedtls.mbedtls_ssl_write(&self.ssl, bytes.ptr + written, bytes.len - written);
            if (count <= 0) return false;
            written += @intCast(count);
        }
        return true;
    }

    /// Called from stop on another thread; the owner closes the descriptors.
    fn shutdownStreams(self: *Connection) void {
        self.client.shutdown(self.front.io, .both) catch {};
        if (self.backend_connected.load(.acquire)) self.backend.shutdown(self.front.io, .both) catch {};
    }

    fn bioSend(raw: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
        const self: *Connection = @ptrCast(@alignCast(raw.?));
        if (len == 0) return 0;
        writeAllBounded(
            self.front.io,
            self.client.socket.handle,
            buf[0..len],
            self.writeDeadline(),
            &self.front.running,
        ) catch return mbedtls.MBEDTLS_ERR_NET_SEND_FAILED;
        return @intCast(len);
    }

    fn bioRecv(raw: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
        const self: *Connection = @ptrCast(@alignCast(raw.?));
        if (comptime builtin.os.tag == .windows) return mbedtls.MBEDTLS_ERR_NET_RECV_FAILED;
        return self.recvClient(buf, len);
    }

    fn recvClient(self: *Connection, buf: [*c]u8, len: usize) c_int {
        if (len == 0) return 0;
        const io = self.front.io;
        var waited_ms: u32 = 0;

        while (self.front.running.load(.acquire)) {
            const slice_ms = self.readSliceMs(io, waited_ms) orelse return mbedtls.MBEDTLS_ERR_SSL_TIMEOUT;
            var fds = [1]std.posix.pollfd{
                .{ .fd = self.client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, slice_ms) catch return mbedtls.MBEDTLS_ERR_NET_RECV_FAILED;
            if (ready == 0) {
                waited_ms += @intCast(slice_ms);
                continue;
            }
            var slices = [1][]u8{buf[0..len]};
            const read = io.vtable.netRead(io.userdata, self.client.socket.handle, &slices) catch
                return mbedtls.MBEDTLS_ERR_NET_RECV_FAILED;
            return @intCast(read);
        }
        return mbedtls.MBEDTLS_ERR_NET_CONN_RESET;
    }

    /// Absolute handshake deadline first, then the idle timeout.
    fn readSliceMs(self: *Connection, io: std.Io, waited_ms: u32) ?i32 {
        if (self.handshake_deadline) |deadline| {
            const remaining = remainingMs(io, deadline);
            return if (remaining > 0) @min(remaining, poll_slice_ms) else null;
        }
        if (waited_ms >= self.read_timeout_ms) return null;
        const remaining = @min(self.read_timeout_ms - waited_ms, @as(u32, @intCast(poll_slice_ms)));
        return @intCast(remaining);
    }
};

/// Tests get only the error; production also logs it.
fn reportConfigError(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.err(fmt, args);
}

fn readPem(io: std.Io, allocator: std.mem.Allocator, path: []const u8, what: []const u8) ![:0]u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        reportConfigError("tls-mode=native needs a readable {s} at {s}: {s}", .{ what, path, @errorName(err) });
        return error.TlsFileUnreadable;
    };
    defer allocator.free(raw);

    // mbedTLS reads PEM with the terminating NUL included in the length.
    const terminated = try allocator.allocSentinel(u8, raw.len, 0);
    @memcpy(terminated, raw);
    return terminated;
}

fn writeStreamAll(io: std.Io, handle: std.Io.net.Socket.Handle, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const data = [1][]const u8{remaining};
        const written = try io.vtable.netWrite(io.userdata, handle, "", &data, 1);
        if (written == 0) return error.ConnectionClosed;
        remaining = remaining[written..];
    }
}

fn readStream(io: std.Io, handle: std.Io.net.Socket.Handle, buffer: []u8) !usize {
    var slices = [1][]u8{buffer};
    return io.vtable.netRead(io.userdata, handle, &slices);
}

const PeekError = error{ Interrupted, WouldBlock, ConnectionClosed };

fn peek(handle: std.Io.net.Socket.Handle, buffer: []u8) PeekError!usize {
    if (comptime builtin.os.tag == .windows) return error.ConnectionClosed;
    const rc = std.c.recvfrom(handle, buffer.ptr, buffer.len, std.posix.MSG.PEEK, null, null);
    if (rc >= 0) return @intCast(rc);
    return switch (std.posix.errno(rc)) {
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        else => error.ConnectionClosed,
    };
}

fn remainingMs(io: std.Io, deadline: std.Io.Timestamp) i32 {
    const left = std.Io.Timestamp.now(io, .awake).durationTo(deadline).nanoseconds;
    if (left <= 0) return 0;
    return @intCast(@min(@divTrunc(left, std.time.ns_per_ms), std.math.maxInt(i32)));
}

const SendError = error{ Interrupted, WouldBlock, ConnectionClosed, SendFailed };

/// Non-blocking writes with poll; std.Io treats a full buffer as a bug.
fn writeAllBounded(
    io: std.Io,
    handle: std.Io.net.Socket.Handle,
    bytes: []const u8,
    deadline: std.Io.Timestamp,
    running: *const std.atomic.Value(bool),
) !void {
    if (comptime builtin.os.tag == .windows) return error.WriteFailed;
    var remaining = bytes;
    while (remaining.len > 0) {
        if (!running.load(.acquire)) return error.ConnectionClosed;
        const written = sendOnce(handle, remaining) catch |err| switch (err) {
            error.Interrupted => continue,
            error.WouldBlock => {
                const wait_ms = remainingMs(io, deadline);
                if (wait_ms <= 0) return error.WriteTimeout;
                var fds = [1]std.posix.pollfd{
                    .{ .fd = handle, .events = std.posix.POLL.OUT, .revents = 0 },
                };
                _ = std.posix.poll(&fds, @min(wait_ms, poll_slice_ms)) catch return error.WriteFailed;
                continue;
            },
            error.ConnectionClosed => return error.ConnectionClosed,
            error.SendFailed => return error.WriteFailed,
        };
        if (written == 0) return error.ConnectionClosed;
        remaining = remaining[written..];
    }
}

fn sendOnce(handle: std.Io.net.Socket.Handle, bytes: []const u8) SendError!usize {
    if (comptime builtin.os.tag == .windows) return error.SendFailed;
    if (comptime builtin.os.tag == .linux) {
        const flags = std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL;
        const rc = std.os.linux.sendto(handle, bytes.ptr, bytes.len, flags, null, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => return error.Interrupted,
            .AGAIN => return error.WouldBlock,
            .CONNRESET, .PIPE, .NOTCONN => return error.ConnectionClosed,
            else => return error.SendFailed,
        }
    } else {
        const flags: u32 = std.c.MSG.DONTWAIT |
            (if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0);
        const rc = std.c.send(handle, bytes.ptr, bytes.len, flags);
        if (rc >= 0) return @intCast(rc);
        switch (std.c.errno(rc)) {
            .INTR => return error.Interrupted,
            .AGAIN => return error.WouldBlock,
            .CONNRESET, .PIPE, .NOTCONN => return error.ConnectionClosed,
            else => return error.SendFailed,
        }
    }
}

/// Darwin and the BSDs have no `MSG_NOSIGNAL`; their sockets need `SO_NOSIGPIPE` instead.
fn preventSigPipe(handle: std.Io.net.Socket.Handle) void {
    if (comptime builtin.os.tag == .windows) return;
    if (comptime @hasDecl(std.c.SO, "NOSIGPIPE")) {
        var enabled: c_int = 1;
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.c.SO.NOSIGPIPE, std.mem.asBytes(&enabled)) catch |err| {
            log.warn("TLS front cannot set SO_NOSIGPIPE: {s}", .{@errorName(err)});
        };
    }
}

/// Small TLS and HTTP writes must not wait on Nagle.
fn setNoDelay(handle: std.Io.net.Socket.Handle) void {
    if (comptime builtin.os.tag == .windows) return;
    var enabled: c_int = 1;
    std.posix.setsockopt(handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&enabled)) catch {};
}

const testing = std.testing;
const test_cert = "tests/tls/test-cert.pem";
const test_key = "tests/tls/test-key.pem";

const TestClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: Stream,
    entropy: mbedtls.mbedtls_entropy_context,
    drbg: mbedtls.mbedtls_ctr_drbg_context,
    conf: mbedtls.mbedtls_ssl_config,
    ssl: mbedtls.mbedtls_ssl_context,
    alpn: [2][*c]const u8 = .{ "http/1.1", null },

    fn connect(allocator: std.mem.Allocator, io: std.Io, address: IpAddress) !*TestClient {
        const self = try allocator.create(TestClient);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = try address.connect(io, .{ .mode = .stream }),
            .entropy = undefined,
            .drbg = undefined,
            .conf = undefined,
            .ssl = undefined,
        };
        errdefer {
            self.stream.close(io);
            allocator.destroy(self);
        }

        mbedtls.mbedtls_entropy_init(&self.entropy);
        mbedtls.mbedtls_ctr_drbg_init(&self.drbg);
        mbedtls.mbedtls_ssl_config_init(&self.conf);
        mbedtls.mbedtls_ssl_init(&self.ssl);

        const personal = "tecton-tls-test";
        if (mbedtls.mbedtls_ctr_drbg_seed(&self.drbg, mbedtls.mbedtls_entropy_func, &self.entropy, personal.ptr, personal.len) != 0) return error.SeedFailed;
        if (mbedtls.mbedtls_ssl_config_defaults(
            &self.conf,
            mbedtls.MBEDTLS_SSL_IS_CLIENT,
            mbedtls.MBEDTLS_SSL_TRANSPORT_STREAM,
            mbedtls.MBEDTLS_SSL_PRESET_DEFAULT,
        ) != 0) return error.ConfigFailed;
        mbedtls.mbedtls_ssl_conf_authmode(&self.conf, mbedtls.MBEDTLS_SSL_VERIFY_NONE);
        mbedtls.mbedtls_ssl_conf_rng(&self.conf, mbedtls.mbedtls_ctr_drbg_random, &self.drbg);
        _ = mbedtls.mbedtls_ssl_conf_alpn_protocols(&self.conf, @ptrCast(@constCast(&self.alpn)));
        if (mbedtls.mbedtls_ssl_setup(&self.ssl, &self.conf) != 0) return error.SetupFailed;
        _ = mbedtls.mbedtls_ssl_set_hostname(&self.ssl, "localhost");
        mbedtls.mbedtls_ssl_set_bio(&self.ssl, self, clientSend, clientRecv, null);
        if (mbedtls.mbedtls_ssl_handshake(&self.ssl) != 0) return error.HandshakeFailed;
        return self;
    }

    fn deinit(self: *TestClient) void {
        _ = mbedtls.mbedtls_ssl_close_notify(&self.ssl);
        mbedtls.mbedtls_ssl_free(&self.ssl);
        mbedtls.mbedtls_ssl_config_free(&self.conf);
        mbedtls.mbedtls_ctr_drbg_free(&self.drbg);
        mbedtls.mbedtls_entropy_free(&self.entropy);
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn write(self: *TestClient, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const count = mbedtls.mbedtls_ssl_write(&self.ssl, bytes.ptr + written, bytes.len - written);
            if (count <= 0) return error.WriteFailed;
            written += @intCast(count);
        }
    }

    fn read(self: *TestClient, buffer: []u8) !usize {
        const count = mbedtls.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);
        if (count < 0) return error.ReadFailed;
        return @intCast(count);
    }

    fn clientSend(raw: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(raw.?));
        writeStreamAll(self.io, self.stream.socket.handle, buf[0..len]) catch
            return mbedtls.MBEDTLS_ERR_NET_SEND_FAILED;
        return @intCast(len);
    }

    fn clientRecv(raw: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(raw.?));
        var slices = [1][]u8{buf[0..len]};
        const count = self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &slices) catch
            return mbedtls.MBEDTLS_ERR_NET_RECV_FAILED;
        return @intCast(count);
    }
};

const FakeBackend = struct {
    io: std.Io,
    server: std.Io.net.Server,

    fn run(self: *FakeBackend) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);

        var buffer: [4096]u8 = undefined;
        _ = readStream(self.io, stream.socket.handle, &buffer) catch return;
        writeStreamAll(self.io, stream.socket.handle, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\ntlsok") catch return;
    }
};

const FloodBackend = struct {
    io: std.Io,
    server: std.Io.net.Server,
    flooding: std.atomic.Value(bool) = .init(false),

    fn run(self: *FloodBackend) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var buffer: [4096]u8 = undefined;
        _ = readStream(self.io, stream.socket.handle, &buffer) catch return;

        self.flooding.store(true, .release);
        const chunk = [_]u8{'x'} ** (16 * 1024);
        var sent: usize = 0;
        while (sent < 8 * 1024 * 1024) : (sent += chunk.len) {
            writeStreamAll(self.io, stream.socket.handle, &chunk) catch return;
        }
        var sink: [256]u8 = undefined;
        while (true) {
            const read = readStream(self.io, stream.socket.handle, &sink) catch return;
            if (read == 0) return;
        }
    }
};

const HoldingBackend = struct {
    io: std.Io,
    server: std.Io.net.Server,
    relayed: std.atomic.Value(bool) = .init(false),

    fn run(self: *HoldingBackend) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var buffer: [4096]u8 = undefined;
        const read = readStream(self.io, stream.socket.handle, &buffer) catch return;
        if (read == 0) return;
        self.relayed.store(true, .release);
        writeStreamAll(self.io, stream.socket.handle, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\ntlsok") catch return;

        var sink: [256]u8 = undefined;
        while (true) {
            const next = readStream(self.io, stream.socket.handle, &sink) catch return;
            if (next == 0) return;
        }
    }
};

test "the native front proxies a TLS request to the plain signaling listener" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    var backend = FakeBackend{
        .io = io,
        .server = try (try IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{ .reuse_address = true }),
    };
    defer backend.server.deinit(io);
    var backend_future = try io.concurrent(FakeBackend.run, .{&backend});
    defer backend_future.await(io);

    const front = try Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", backend.server.socket.address.getPort()),
        .cert_path = test_cert,
        .key_path = test_key,
    });
    defer front.deinit();
    try front.start();
    try testing.expect(front.boundPort() != 0);

    const client = try TestClient.connect(allocator, io, try IpAddress.parseIp4("127.0.0.1", front.boundPort()));
    defer client.deinit();

    const negotiated = mbedtls.mbedtls_ssl_get_alpn_protocol(&client.ssl);
    try testing.expectEqualStrings("http/1.1", if (negotiated) |value| std.mem.span(value) else "");
    try client.write("GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var response: [256]u8 = undefined;
    const read = try client.read(&response);
    try testing.expect(read > 0);
    try testing.expect(std.mem.indexOf(u8, response[0..read], "tlsok") != null);
}

test "the same port forwards a plain HTTP request to the plain signaling listener" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    var backend = FakeBackend{
        .io = io,
        .server = try (try IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{ .reuse_address = true }),
    };
    defer backend.server.deinit(io);
    var backend_future = try io.concurrent(FakeBackend.run, .{&backend});
    defer backend_future.await(io);

    const front = try Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", backend.server.socket.address.getPort()),
        .cert_path = test_cert,
        .key_path = test_key,
    });
    defer front.deinit();
    try front.start();

    const stream = try (try IpAddress.parseIp4("127.0.0.1", front.boundPort())).connect(io, .{ .mode = .stream });
    defer stream.close(io);
    try writeStreamAll(io, stream.socket.handle, "GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var response: [256]u8 = undefined;
    var received: usize = 0;
    while (received == 0) {
        var fds = [1]std.posix.pollfd{
            .{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        if (try std.posix.poll(&fds, 2_000) == 0) return error.ResponseTimeout;
        received = try readStream(io, stream.socket.handle, &response);
    }
    try testing.expect(std.mem.indexOf(u8, response[0..received], "tlsok") != null);
}

test "native TLS refuses to start without usable certificate material" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const garbage_path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/garbage.pem", .{tmp.sub_path});
    {
        const file = try std.Io.Dir.cwd().createFile(io, garbage_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "not a certificate\n");
    }

    try testing.expectError(error.TlsFileUnreadable, Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", 19132),
        .cert_path = ".zig-cache/missing-cert.pem",
        .key_path = test_key,
    }));
    try testing.expectError(error.TlsCertificateInvalid, Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", 19132),
        .cert_path = garbage_path,
        .key_path = test_key,
    }));
    try testing.expectError(error.TlsKeyInvalid, Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", 19132),
        .cert_path = test_cert,
        .key_path = garbage_path,
    }));
}

test "stopping the front unblocks a relay that is still open" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    var backend = HoldingBackend{
        .io = io,
        .server = try (try IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{ .reuse_address = true }),
    };
    defer backend.server.deinit(io);
    var backend_future = try io.concurrent(HoldingBackend.run, .{&backend});
    defer backend_future.await(io);

    const front = try Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", backend.server.socket.address.getPort()),
        .cert_path = test_cert,
        .key_path = test_key,
    });
    defer front.deinit();
    try front.start();

    const client = try TestClient.connect(allocator, io, try IpAddress.parseIp4("127.0.0.1", front.boundPort()));
    defer client.deinit();
    try client.write("GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var response: [256]u8 = undefined;
    const read = try client.read(&response);
    try testing.expect(read > 0);
    try testing.expect(std.mem.indexOf(u8, response[0..read], "tlsok") != null);
    try testing.expect(backend.relayed.load(.acquire));
    try testing.expectEqual(@as(u32, 1), front.openConnectionCount());

    const started = std.Io.Timestamp.now(io, .awake);
    front.stop();
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    try testing.expect(elapsed.nanoseconds < std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 0), front.openConnectionCount());
}

test "a slow handshake is cut at the handshake deadline, not per read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    const front = try Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", 19132),
        .cert_path = test_cert,
        .key_path = test_key,
        .handshake_timeout_ms = 500,
    });
    defer front.deinit();
    try front.start();

    const stream = try (try IpAddress.parseIp4("127.0.0.1", front.boundPort())).connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // Drip a ClientHello; only an absolute deadline cuts it.
    const header = [_]u8{ 0x16, 0x03, 0x01, 0x00, 0x40 };
    writeStreamAll(io, stream.socket.handle, &header) catch return error.HandshakeClosedTooSoon;

    const started = std.Io.Timestamp.now(io, .awake);
    var closed = false;
    const body = [1]u8{0};
    for (0..20) |_| {
        writeStreamAll(io, stream.socket.handle, &body) catch {
            closed = true;
            break;
        };
        var fds = [1]std.posix.pollfd{
            .{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        if (try std.posix.poll(&fds, 40) > 0) {
            closed = true;
            break;
        }
    }
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    try testing.expect(closed);
    try testing.expect(elapsed >= 300 * std.time.ns_per_ms);
    try testing.expect(elapsed < 2 * std.time.ns_per_s);
}

test "a client that stops reading is dropped at the write deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    const allocator = testing.allocator;

    var backend = FloodBackend{
        .io = io,
        .server = try (try IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{ .reuse_address = true }),
    };
    defer backend.server.deinit(io);
    var backend_future = try io.concurrent(FloodBackend.run, .{&backend});
    defer backend_future.await(io);

    const front = try Front.init(io, allocator, .{
        .bind = try IpAddress.parseIp4("127.0.0.1", 0),
        .backend = try IpAddress.parseIp4("127.0.0.1", backend.server.socket.address.getPort()),
        .cert_path = test_cert,
        .key_path = test_key,
        .write_timeout_ms = 300,
        .close_timeout_ms = 1_000,
    });
    defer front.deinit();
    try front.start();

    const client = try TestClient.connect(allocator, io, try IpAddress.parseIp4("127.0.0.1", front.boundPort()));
    defer client.deinit();
    var receive_buffer: c_int = 4096;
    try std.posix.setsockopt(
        client.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&receive_buffer),
    );

    const started = std.Io.Timestamp.now(io, .awake);
    try client.write("GET /v1/join HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var waited_ms: u32 = 0;
    while ((front.openConnectionCount() != 1 or !backend.flooding.load(.acquire)) and waited_ms < 2_000) {
        try io.sleep(.fromMilliseconds(20), .awake);
        waited_ms += 20;
    }
    try testing.expectEqual(@as(u32, 1), front.openConnectionCount());
    try testing.expect(backend.flooding.load(.acquire));

    waited_ms = 0;
    while (front.openConnectionCount() != 0 and waited_ms < 5_000) {
        try io.sleep(.fromMilliseconds(20), .awake);
        waited_ms += 20;
    }
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    try testing.expectEqual(@as(u32, 0), front.openConnectionCount());
    try testing.expect(elapsed >= 250 * std.time.ns_per_ms);
    // 300 ms of write deadline + 1 s of close deadline, plus 200 ms of scheduling slack.
    try testing.expect(elapsed < 1_500 * std.time.ns_per_ms);
}
