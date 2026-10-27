const std = @import("std");

const Raknet = @import("Raknet");

const connection_mod = @import("connection.zig");
const events_mod = @import("events.zig");
const FrameBuffers = @import("frame_buffers.zig").FrameBuffers;
const port_mod = @import("port.zig");
const SendPriority = @import("priority.zig").SendPriority;

const Connection = connection_mod.Connection;

/// Delivers through ZigNet/RakNet. Temporary: it disappears once the NetherNet adapter lands.
///
/// The port owns the backend-to-connection index, so a recycled RakNet pointer can never be
/// mistaken for a session: the game only ever sees `Connection.id`.
pub const RaknetPort = struct {
    /// What the transport reports to the game layer, from its own threads.
    pub const Sink = struct {
        ctx: *anyopaque,
        packet: *const fn (ctx: *anyopaque, conn: *Connection, payload: []const u8) void,
    };

    pub const Options = struct {
        registry: *connection_mod.ConnectionRegistry,
        sink: Sink,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *connection_mod.ConnectionRegistry,
    frame_buffers: FrameBuffers,
    sink: Sink,
    mutex: std.Io.Mutex = .init,
    by_backend: std.AutoHashMap(usize, *Connection),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*RaknetPort {
        const self = try allocator.create(RaknetPort);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .registry = options.registry,
            .frame_buffers = FrameBuffers.init(allocator),
            .sink = options.sink,
            .by_backend = std.AutoHashMap(usize, *Connection).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *RaknetPort) void {
        self.frame_buffers.deinit();
        self.by_backend.deinit();
        self.allocator.destroy(self);
    }

    pub fn port(self: *RaknetPort) port_mod.Port {
        return .{
            .ctx = self,
            .send = send,
            .close = close,
            .max_payload = maxPayload,
        };
    }

    /// RakNet connect callback. Creates the session and remembers which handle it belongs to.
    pub fn onConnect(backend: *Raknet.Connection, context: ?*anyopaque) void {
        const self: *RaknetPort = @ptrCast(@alignCast(context.?));
        const conn = self.registry.create(backend) catch {
            backend.deactivate();
            return;
        };

        self.mutex.lock(self.io) catch {
            self.registry.closeAndRelease(conn);
            backend.deactivate();
            return;
        };
        self.by_backend.put(@intFromPtr(backend), conn) catch {
            self.mutex.unlock(self.io);
            self.registry.closeAndRelease(conn);
            backend.deactivate();
            return;
        };
        self.mutex.unlock(self.io);

        backend.setGamePacketCallback(onPacket, self);
    }

    /// RakNet disconnect callback. `closed` is emitted once even if the game closed first.
    pub fn onDisconnect(backend: *Raknet.Connection, context: ?*anyopaque) void {
        const self: *RaknetPort = @ptrCast(@alignCast(context.?));
        const conn = self.forgetBackend(backend) orelse return;
        self.registry.closeAndRelease(conn);
    }

    fn onPacket(backend: *Raknet.Connection, payload: []const u8, context: ?*anyopaque) void {
        const self: *RaknetPort = @ptrCast(@alignCast(context.?));

        // The game may close this session on the tick thread while the transport still holds
        // the handle, so the session is pinned only for the duration of the delivery.
        self.mutex.lock(self.io) catch return;
        const found = self.by_backend.get(@intFromPtr(backend));
        if (found) |conn| conn.retain();
        self.mutex.unlock(self.io);

        const session = found orelse return;
        defer session.release();
        self.sink.packet(self.sink.ctx, session, payload);
    }

    /// Drops the backend index entry so a retired RakNet handle is never resolved again.
    fn forgetBackend(self: *RaknetPort, backend: *Raknet.Connection) ?*Connection {
        self.mutex.lock(self.io) catch return null;
        const removed = self.by_backend.fetchRemove(@intFromPtr(backend));
        self.mutex.unlock(self.io);
        return if (removed) |entry| entry.value else null;
    }

    fn send(ctx: *anyopaque, conn: *Connection, bytes: []const u8, priority: SendPriority) port_mod.SendError!void {
        const self: *RaknetPort = @ptrCast(@alignCast(ctx));
        if (!conn.isOpen()) return error.Closed;
        if (bytes.len == 0) return;

        const backend: *Raknet.Connection = @ptrCast(@alignCast(conn.backend));
        if (!backend.isActive()) return error.Closed;

        const backend_priority: Raknet.ServerPriority = switch (priority) {
            .normal => .Normal,
            .immediate => .Immediate,
        };

        // A frame that fits one datagram is copied into the pool; anything larger goes through
        // the transport's own split path, which frees the payload with the transport allocator.
        if (bytes.len <= maxPayload(ctx, conn) and bytes.len <= FrameBuffers.slot_size) {
            const pool = self.frame_buffers.allocator();
            const buffer = pool.alloc(u8, bytes.len) catch {
                backend.sendReliableMessage(bytes, backend_priority);
                return;
            };
            @memcpy(buffer, bytes);
            const frame = Raknet.Proto.Frame.init(null, null, null, 0, .ReliableOrdered, buffer, null, null, null, pool);
            backend.sendFrame(frame, backend_priority);
            return;
        }

        backend.sendReliableMessage(bytes, backend_priority);
    }

    fn close(ctx: *anyopaque, conn: *Connection, mode: port_mod.CloseMode) void {
        // The transport has a single teardown: the shard retires the connection once it is inactive.
        _ = mode;
        const self: *RaknetPort = @ptrCast(@alignCast(ctx));
        const backend: *Raknet.Connection = @ptrCast(@alignCast(conn.backend));
        backend.deactivate();
        _ = self.forgetBackend(backend);
        self.registry.closeAndRelease(conn);
    }

    fn maxPayload(ctx: *anyopaque, conn: *Connection) usize {
        _ = ctx;
        const backend: *Raknet.Connection = @ptrCast(@alignCast(conn.backend));
        return if (backend.mtu_size > 36) backend.mtu_size - 36 else 0;
    }
};

const testing = std.testing;

fn testTransport(allocator: std.mem.Allocator) !Raknet.Server {
    return Raknet.Server.init(testing.io, .{
        .allocator = allocator,
        .address = "127.0.0.1",
        .port = 0,
        .output_slab_slots = 8,
        .transient_slab_slots = 4,
        .outbound_queue_slots = 8,
    });
}

const Probe = struct {
    packets: usize = 0,
    last_len: usize = 0,

    fn deliver(ctx: *anyopaque, conn: *Connection, payload: []const u8) void {
        _ = conn;
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.packets += 1;
        self.last_len = payload.len;
    }
};

test "connect, packet and disconnect are routed through the port" {
    var events = events_mod.Queue.init(testing.io, testing.allocator);
    defer events.deinit();

    var registry = connection_mod.ConnectionRegistry.init(testing.allocator, testing.io, &events);
    defer registry.deinit();

    var transport = try testTransport(testing.allocator);
    defer transport.deinit();

    var probe = Probe{};
    const port = try RaknetPort.init(testing.allocator, testing.io, .{
        .registry = &registry,
        .sink = .{ .ctx = &probe, .packet = Probe.deliver },
    });
    defer port.deinit();

    const backend = try testing.allocator.create(Raknet.Connection);
    defer testing.allocator.destroy(backend);
    backend.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 1 } }, 1400, 1);
    defer backend.deinit();

    RaknetPort.onConnect(backend, port);
    try testing.expectEqual(@as(usize, 1), registry.count());

    var drained: std.ArrayList(events_mod.Event) = .empty;
    defer drained.deinit(testing.allocator);
    events.drain(&drained);
    try testing.expectEqual(@as(usize, 1), drained.items.len);
    const conn_id = drained.items[0].opened;
    const conn = registry.get(conn_id).?;
    conn.retain();
    defer conn.release();

    try port.port().sendBytes(conn, "frame-bytes", .normal);
    try testing.expectEqual(@as(usize, 1), backend.comm_data.output_frame_queue.items.len);

    backend.game_packet_callback.?(backend, "incoming", backend.game_packet_context);
    try testing.expectEqual(@as(usize, 1), probe.packets);
    try testing.expectEqual(@as(usize, 8), probe.last_len);

    port.port().closeConn(conn, .flush);
    try testing.expect(!conn.isOpen());
    try testing.expectEqual(@as(usize, 0), registry.count());

    RaknetPort.onDisconnect(backend, port);
    drained.clearRetainingCapacity();
    events.drain(&drained);
    try testing.expectEqual(@as(usize, 1), drained.items.len);
    try testing.expectEqual(conn_id, drained.items[0].closed);
}

test "a payload that cannot fit the pool is handed to the transport instead of the slab" {
    var events = events_mod.Queue.init(testing.io, testing.allocator);
    defer events.deinit();

    var registry = connection_mod.ConnectionRegistry.init(testing.allocator, testing.io, &events);
    defer registry.deinit();

    var transport = try testTransport(testing.allocator);
    defer transport.deinit();

    var probe = Probe{};
    const port = try RaknetPort.init(testing.allocator, testing.io, .{
        .registry = &registry,
        .sink = .{ .ctx = &probe, .packet = Probe.deliver },
    });
    defer port.deinit();

    const backend = try testing.allocator.create(Raknet.Connection);
    defer testing.allocator.destroy(backend);
    backend.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 2 } }, 1400, 2);
    defer backend.deinit();

    RaknetPort.onConnect(backend, port);
    const conn = registry.get(1).?;
    conn.retain();
    defer conn.release();

    var large: [3000]u8 = undefined;
    @memset(&large, 0x41);
    try port.port().sendBytes(conn, &large, .normal);
    try testing.expect(backend.comm_data.output_frame_queue.items.len > 1);
    for (backend.comm_data.output_frame_queue.items) |*frame| frame.deinit();
    backend.comm_data.output_frame_queue.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), port.frame_buffers.mappedBytes());
}

test "sending on a closed session reports Closed and never touches the transport" {
    var events = events_mod.Queue.init(testing.io, testing.allocator);
    defer events.deinit();

    var registry = connection_mod.ConnectionRegistry.init(testing.allocator, testing.io, &events);
    defer registry.deinit();

    var transport = try testTransport(testing.allocator);
    defer transport.deinit();

    var probe = Probe{};
    const port = try RaknetPort.init(testing.allocator, testing.io, .{
        .registry = &registry,
        .sink = .{ .ctx = &probe, .packet = Probe.deliver },
    });
    defer port.deinit();

    const backend = try testing.allocator.create(Raknet.Connection);
    defer testing.allocator.destroy(backend);
    backend.* = Raknet.Connection.init(&transport, .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 3 } }, 1400, 3);
    defer backend.deinit();

    RaknetPort.onConnect(backend, port);
    const conn = registry.get(1).?;
    conn.retain();
    defer conn.release();
    port.port().closeConn(conn, .abort);

    try testing.expectError(error.Closed, port.port().sendBytes(conn, "late", .normal));
    try testing.expectEqual(@as(usize, 0), backend.comm_data.output_frame_queue.items.len);
}
