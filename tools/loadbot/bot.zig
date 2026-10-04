const std = @import("std");

const Raknet = @import("Raknet");
const Protocol = @import("protocol");
const BinaryStream = @import("BinaryStream").BinaryStream;

const framing = @import("framing.zig");
const identity = @import("identity.zig");

/// Not re-exported by protocol, so taken from the packet that carries it.
const InputDataBits = @TypeOf(@as(Protocol.PlayerAuthInputPacket, undefined).input_data);

pub const Stage = enum(u8) {
    connecting,
    requesting_settings,
    authenticating,
    joining,
    active,
    closed,
};

pub const Layout = enum {
    /// Every bot in one chunk: worst-case movement fan-out.
    cluster,
    /// One bot per `spacing` blocks: realistic streaming.
    grid,
};

pub const Config = struct {
    io: std.Io,
    host: []const u8,
    port: u16,
    mtu_size: u16 = 1492,
    chunk_radius: i32 = 8,
    walk: bool = false,
    speed: f32 = 4.3,
    layout: Layout = .grid,
    spacing: f32 = 16.0,
    // A bot never falls, so this is the height it stays at.
    spawn_y: f32 = 100.0,
    frame_options: framing.Options = .{},
    server_address: []const u8,
    game_version: []const u8,
    inventory: bool = false,
    inventory_hz: u32 = 10,
    give_items: bool = false,
    enchant_items: bool = false,
    curse_binding: bool = false,
    duel: bool = false,
    duel_pieces: u8 = 4,
    duel_enchant: []const u8 = "protection",
    duel_level: u8 = 4,
    duel_thorns: u8 = 0,
    duel_swings: u32 = 20,
    duel_weapon: []const u8 = "diamond_sword",
    verbose: bool = false,
    stop: *const std.atomic.Value(bool),
};

pub const INVENTORY_SLOT_A: u8 = 0;
pub const INVENTORY_SLOT_B: u8 = 1;

pub const SETUP_SLOTS: usize = 9;
pub const SETUP_ITEM: []const u8 = "diamond_sword";
pub const SETUP_ENCHANTMENTS = [_]struct { name: []const u8, level: u8 }{
    .{ .name = "sharpness", .level = 5 },
    .{ .name = "unbreaking", .level = 3 },
    .{ .name = "looting", .level = 3 },
    .{ .name = "fire_aspect", .level = 2 },
    .{ .name = "knockback", .level = 2 },
    .{ .name = "mending", .level = 1 },
};

const SETUP_STEPS_PER_SLOT = 1 + SETUP_ENCHANTMENTS.len;

pub fn setupSteps(enchant_items: bool) usize {
    if (!enchant_items) return SETUP_SLOTS;
    return SETUP_SLOTS + SETUP_SLOTS * SETUP_STEPS_PER_SLOT;
}

pub const CURSE_STEPS: usize = 6;
pub const CURSE_ITEM: []const u8 = "diamond_boots";
pub const CURSE_ENCHANTMENT: []const u8 = "curse_of_binding";
/// `/give` fills the first empty slot, which is slot 0 in a fresh inventory.
pub const CURSE_HOTBAR_SLOT: u8 = 0;
/// Armor slots are ordered helmet, chestplate, leggings, boots on the wire.
pub const CURSE_ARMOR_SLOT: u8 = 3;
/// The control slot is known-empty: a refusal there says nothing about the curse.
pub const CURSE_CONTROL_SLOT: u8 = 0;

pub const CurseStep = enum { give, select, enchant, wear, control, remove };

pub fn curseStep(step: usize) ?CurseStep {
    return switch (step) {
        0 => .give,
        1 => .select,
        2 => .enchant,
        3 => .wear,
        4 => .control,
        5 => .remove,
        else => null,
    };
}

/// One end of a stack request action; the two ends may name different containers.
pub const SlotRef = struct {
    container: Protocol.ContainerName,
    slot: u8,
};

pub const CurseSwap = struct { source: SlotRef, destination: SlotRef };

pub const DUEL_ATTACKER_INDEX: usize = 0;
pub const DUEL_VICTIM_INDEX: usize = 1;
/// Helmet, chestplate, leggings, boots: the order of the armor container.
pub const DUEL_ARMOR = [_][]const u8{
    "diamond_helmet",
    "diamond_chestplate",
    "diamond_leggings",
    "diamond_boots",
};
pub const DUEL_THORNS_LEVEL: u8 = 3;
/// Four swings a second: every health update is read before the next hit lands.
pub const DUEL_SWING_PERIOD_NS: i96 = 250 * std.time.ns_per_ms;
/// Wait after the victim's last set-up packet so the armor applies first.
pub const DUEL_READY_GRACE_NS: i96 = 2 * std.time.ns_per_s;
/// Wait after the last swing so in-flight health updates are counted.
pub const DUEL_SUMMARY_DELAY_NS: i96 = std.time.ns_per_s;

pub const DuelRole = enum { none, attacker, victim };

pub fn duelRole(config: *const Config, index: usize) DuelRole {
    if (!config.duel) return .none;
    return switch (index) {
        DUEL_ATTACKER_INDEX => .attacker,
        DUEL_VICTIM_INDEX => .victim,
        else => .none,
    };
}

pub fn duelHasWeapon(config: *const Config) bool {
    return !std.mem.eql(u8, config.duel_weapon, "none");
}

pub fn duelEnchants(config: *const Config) bool {
    return !std.mem.eql(u8, config.duel_enchant, "none");
}

pub fn duelSetupSteps(config: *const Config, role: DuelRole) usize {
    return switch (role) {
        .attacker => if (duelHasWeapon(config)) 3 else 1,
        .victim => blk: {
            var steps: usize = 1; // the gamemode command
            steps += config.duel_pieces;
            for (0..config.duel_pieces) |piece| {
                steps += 2; // select and equip
                if (duelEnchants(config)) steps += 1;
                if (piece < config.duel_thorns) steps += 1;
            }
            break :blk steps;
        },
        .none => 0,
    };
}

pub const DuelVictimStep = union(enum) {
    gamemode,
    give: u8,
    select: u8,
    enchant: u8,
    thorns: u8,
    equip: u8,
};

pub fn duelVictimStep(config: *const Config, step: usize) ?DuelVictimStep {
    if (step == 0) return .gamemode;

    var cursor: usize = 1;
    for (0..config.duel_pieces) |piece| {
        if (step == cursor) return .{ .give = @intCast(piece) };
        cursor += 1;
    }
    for (0..config.duel_pieces) |piece| {
        if (step == cursor) return .{ .select = @intCast(piece) };
        cursor += 1;
        if (duelEnchants(config)) {
            if (step == cursor) return .{ .enchant = @intCast(piece) };
            cursor += 1;
        }
        if (piece < config.duel_thorns) {
            if (step == cursor) return .{ .thorns = @intCast(piece) };
            cursor += 1;
        }
        if (step == cursor) return .{ .equip = @intCast(piece) };
        cursor += 1;
    }
    return null;
}

pub const DuelAttackerStep = enum { gamemode, give_weapon, select_weapon };

pub fn duelAttackerStep(config: *const Config, step: usize) ?DuelAttackerStep {
    if (step == 0) return .gamemode;
    if (!duelHasWeapon(config)) return null;
    return switch (step) {
        1 => .give_weapon,
        2 => .select_weapon,
        else => null,
    };
}

/// Per-direction set-up: fixed containers would take the boots out of the hotbar.
pub fn curseSwap(step: CurseStep) ?CurseSwap {
    return switch (step) {
        .wear => .{
            .source = .{ .container = .HotbarAndInventory, .slot = CURSE_HOTBAR_SLOT },
            .destination = .{ .container = .Armor, .slot = CURSE_ARMOR_SLOT },
        },
        .control => .{
            .source = .{ .container = .Armor, .slot = CURSE_CONTROL_SLOT },
            .destination = .{ .container = .HotbarAndInventory, .slot = CURSE_HOTBAR_SLOT + 1 },
        },
        .remove => .{
            .source = .{ .container = .Armor, .slot = CURSE_ARMOR_SLOT },
            .destination = .{ .container = .HotbarAndInventory, .slot = CURSE_HOTBAR_SLOT },
        },
        else => null,
    };
}

pub const Counters = struct {
    started: std.atomic.Value(u64) = .init(0),
    connected: std.atomic.Value(u64) = .init(0),
    spawned: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    dead: std.atomic.Value(u64) = .init(0),
    packets_sent: std.atomic.Value(u64) = .init(0),
    bytes_sent: std.atomic.Value(u64) = .init(0),
    packets_received: std.atomic.Value(u64) = .init(0),
    bytes_received: std.atomic.Value(u64) = .init(0),
    move_packets: std.atomic.Value(u64) = .init(0),
    chunk_packets: std.atomic.Value(u64) = .init(0),
    kicked: std.atomic.Value(u64) = .init(0),
    inv_requests: std.atomic.Value(u64) = .init(0),
    inv_responses: std.atomic.Value(u64) = .init(0),
    inv_errors: std.atomic.Value(u64) = .init(0),
    inv_content_packets: std.atomic.Value(u64) = .init(0),
    inv_content_bytes: std.atomic.Value(u64) = .init(0),
    inv_slot_packets: std.atomic.Value(u64) = .init(0),
    inv_slot_bytes: std.atomic.Value(u64) = .init(0),
    commands_sent: std.atomic.Value(u64) = .init(0),
    command_outputs: std.atomic.Value(u64) = .init(0),
    command_failures: std.atomic.Value(u64) = .init(0),
    curse_held: std.atomic.Value(u64) = .init(0),
    curse_leaks: std.atomic.Value(u64) = .init(0),
    curse_control: std.atomic.Value(u64) = .init(0),
    duel_ready: std.atomic.Value(u64) = .init(0),
    duel_swings: std.atomic.Value(u64) = .init(0),
};

pub const Bot = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    counters: *Counters,
    index: usize,
    name: []const u8,
    credentials: identity.Credentials,
    client: Raknet.Client = undefined,
    stage: std.atomic.Value(u8) = .init(@intFromEnum(Stage.connecting)),
    origin: Protocol.Vector3f,
    position: Protocol.Vector3f,
    input_tick: u64 = 0,
    walk_offset: f32 = 0,
    walk_direction: f32 = 1,
    inv_request_id: i32 = 0,
    inv_flip: bool = false,
    inv_period_ns: i96 = 0,
    inv_last: std.Io.Timestamp = undefined,
    inv_armed: bool = false,
    setup_step: usize = 0,
    setup_period_ns: i96 = 0,
    setup_last: std.Io.Timestamp = undefined,
    setup_armed: bool = false,
    setup_buf: [192]u8 = undefined,
    curse_wear_request: i32 = 0,
    curse_control_request: i32 = 0,
    curse_remove_request: i32 = 0,
    duel_self_runtime_id: ?i64 = null,
    duel_target_runtime_id: ?u64 = null,
    duel_health: ?f32 = null,
    duel_hits: u32 = 0,
    duel_first_damage: f32 = 0,
    duel_reflections: u32 = 0,
    duel_reflection_total: f32 = 0,
    duel_swings_sent: u32 = 0,
    duel_swing_armed: bool = false,
    duel_swing_last: std.Io.Timestamp = undefined,
    duel_ready_sent: bool = false,
    duel_ready_armed: bool = false,
    duel_ready_at: std.Io.Timestamp = undefined,
    duel_summary_armed: bool = false,
    duel_summary_at: std.Io.Timestamp = undefined,
    duel_summary_done: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const Config,
        counters: *Counters,
        index: usize,
        name: []const u8,
    ) !*Bot {
        const bot = try allocator.create(Bot);
        errdefer allocator.destroy(bot);

        const credentials = try identity.forge(allocator, name, index, .{
            .server_address = config.server_address,
            .game_version = config.game_version,
        });
        errdefer credentials.deinit();

        bot.* = .{
            .allocator = allocator,
            .config = config,
            .counters = counters,
            .index = index,
            .name = name,
            .credentials = credentials,
            .origin = spawnPoint(config, index),
            .position = undefined,
            .inv_period_ns = if (config.inventory_hz == 0)
                0
            else
                @divTrunc(@as(i96, std.time.ns_per_s), @as(i96, config.inventory_hz)),
            .setup_period_ns = SETUP_PERIOD_NS,
        };
        bot.position = bot.origin;
        return bot;
    }

    pub fn deinit(self: *Bot) void {
        self.credentials.deinit();
        self.allocator.destroy(self);
    }

    /// Owns the RakNet client and drives the 20 Hz input loop.
    pub fn run(self: *Bot) void {
        self.client = Raknet.Client.init(.{
            .io = self.config.io,
            .allocator = self.allocator,
            .address = self.config.host,
            .port = self.config.port,
            .mtu_size = self.config.mtu_size,
        }) catch {
            _ = self.counters.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer self.client.deinit();

        self.client.setConnectionCallback(onConnect, self);
        self.client.setGamePacketCallback(onGamePacket, self);
        self.client.setDisconnectionCallback(onDisconnect, self);

        self.client.connect() catch {
            _ = self.counters.failed.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.counters.started.fetchAdd(1, .monotonic);

        const period_ns: i96 = std.time.ns_per_s / 20;
        while (!self.config.stop.load(.acquire)) {
            const start = std.Io.Timestamp.now(self.config.io, .awake);

            if (self.stage.load(.acquire) == @intFromEnum(Stage.active)) {
                self.sendAuthInput();
                self.pumpSetup(start);
                self.pumpInventory(start);
                self.pumpDuel(start);
            }

            const elapsed = start.untilNow(self.config.io, .awake).toNanoseconds();
            if (elapsed < period_ns) {
                const remaining: i96 = period_ns - elapsed;
                self.config.io.sleep(std.Io.Duration.fromNanoseconds(remaining), .awake) catch break;
            }
        }

        if (self.stage.load(.acquire) != @intFromEnum(Stage.closed)) self.client.disconnect();
    }

    fn setStage(self: *Bot, stage: Stage) void {
        self.stage.store(@intFromEnum(stage), .release);
    }

    fn log(self: *Bot, comptime format: []const u8, args: anytype) void {
        if (!self.config.verbose) return;
        self.verdict(format, args);
    }

    /// Printed even without `--verbose`.
    fn verdict(self: *Bot, comptime format: []const u8, args: anytype) void {
        std.debug.print("[bot {d}] " ++ format ++ "\n", .{self.index} ++ args);
    }

    fn onConnect(client: *Raknet.Client, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);
        _ = self.counters.connected.fetchAdd(1, .monotonic);
        self.setStage(.requesting_settings);
        self.log("raknet handshake complete", .{});
        self.sendRequestNetworkSettings();
    }

    fn onDisconnect(client: *Raknet.Client, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);
        _ = self.counters.dead.fetchAdd(1, .monotonic);
        self.setStage(.closed);
        self.log("connection closed by the server", .{});
    }

    fn onGamePacket(client: *Raknet.Client, payload: []const u8, context: ?*anyopaque) void {
        _ = client;
        const self = fromContext(context);

        _ = self.counters.packets_received.fetchAdd(1, .monotonic);
        _ = self.counters.bytes_received.fetchAdd(payload.len, .monotonic);

        const decoded = framing.decode(payload, self.allocator) catch return;
        defer decoded.deinit();

        for (decoded.packets) |packet| {
            if (packet.len == 0) continue;

            var stream = BinaryStream.init(self.allocator, packet, null);
            defer stream.deinit();

            const id = stream.readVarInt() catch continue;
            // Deserializers expect the stream at the packet id, so rewind.
            stream.offset = 0;
            self.log("recv 0x{x:0>2} ({d} bytes)", .{ id, packet.len });
            // Container bytes: only in-harness proof that the stack carries enchant NBT.
            if (id == Protocol.Packet.InventoryContent) {
                _ = self.counters.inv_content_bytes.fetchAdd(packet.len, .monotonic);
            } else if (id == Protocol.Packet.InventorySlot) {
                _ = self.counters.inv_slot_bytes.fetchAdd(packet.len, .monotonic);
            }
            self.handlePacket(&stream, id);
        }
    }

    fn handlePacket(self: *Bot, stream: *BinaryStream, id: u32) void {
        switch (id) {
            Protocol.Packet.NetworkSettings => self.sendLogin(),
            Protocol.Packet.PlayStatus => self.handlePlayStatus(stream),
            Protocol.Packet.ResourcePackInfo => self.sendResourcePackResponse(.HaveAllPacks),
            Protocol.Packet.ResourcePackStack => self.sendResourcePackResponse(.Completed),
            Protocol.Packet.StartGame => self.sendRequestChunkRadius(),
            Protocol.Packet.LevelChunk => _ = self.counters.chunk_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.MovePlayer,
            Protocol.Packet.MoveActorDelta,
            Protocol.Packet.MoveActorAbsolute,
            => _ = self.counters.move_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.ItemStackResponse => self.handleItemStackResponse(stream),
            Protocol.Packet.InventoryContent => _ = self.counters.inv_content_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.InventorySlot => _ = self.counters.inv_slot_packets.fetchAdd(1, .monotonic),
            Protocol.Packet.AddActor => self.handleAddPlayer(stream),
            Protocol.Packet.UpdateAttributes => self.handleUpdateAttributes(stream),
            Protocol.Packet.CommandOutput => self.handleCommandOutput(stream),
            Protocol.Packet.Disconnect => self.handleDisconnect(stream),
            else => {},
        }
    }

    fn handlePlayStatus(self: *Bot, stream: *BinaryStream) void {
        const status = Protocol.PlayStatusPacket.deserialize(stream) catch return;
        switch (status.status) {
            .LoginSuccess => self.log("login accepted", .{}),
            .PlayerSpawn => self.spawn(),
            else => {
                _ = self.counters.kicked.fetchAdd(1, .monotonic);
                self.setStage(.closed);
                self.log("play status {s} ended the session", .{@tagName(status.status)});
            },
        }
    }

    /// One request, one response: status is the byte after the response count.
    fn handleItemStackResponse(self: *Bot, stream: *BinaryStream) void {
        _ = stream.readVarInt() catch return;
        const count = stream.readVarInt() catch return;
        if (count == 0) return;

        const status = stream.readUint8() catch return;
        const request_id = stream.readZigZag() catch return;

        _ = self.counters.inv_responses.fetchAdd(1, .monotonic);
        const success = status == @intFromEnum(Protocol.ItemStackResponseStatus.Success);
        if (!success) _ = self.counters.inv_errors.fetchAdd(1, .monotonic);
        if (self.config.curse_binding) self.reportCurseResponse(request_id, success);
    }

    /// Armor verdict: green only if the requests reached the server.
    fn reportCurseResponse(self: *Bot, request_id: i32, success: bool) void {
        if (self.curse_wear_request != 0 and request_id == self.curse_wear_request) {
            if (!success) self.verdict("the cursed boots never went on, the scenario removes nothing", .{});
            return;
        }

        if (request_id == self.curse_control_request) {
            if (success) return;
            _ = self.counters.curse_control.fetchAdd(1, .monotonic);
            self.verdict("control refused: the server blocks armor swaps outright, so the removal proves nothing", .{});
            return;
        }

        if (request_id != self.curse_remove_request) return;

        if (success) {
            _ = self.counters.curse_leaks.fetchAdd(1, .monotonic);
            self.verdict("LEAKED: the server took the cursed boots off", .{});
            return;
        }

        _ = self.counters.curse_held.fetchAdd(1, .monotonic);
        self.verdict("held: the server refused to take the cursed boots off", .{});
    }

    /// No `CommandOutput` means the command never answered.
    fn handleCommandOutput(self: *Bot, stream: *BinaryStream) void {
        _ = stream.readVarInt() catch return;
        _ = stream.readVarString() catch return;
        _ = stream.read(16);
        _ = stream.readVarString() catch return;
        _ = stream.readInt64(.Little) catch return;
        _ = stream.readVarString() catch return;
        _ = stream.readUint32(.Little) catch return;

        const count = stream.readVarInt() catch return;
        if (count == 0) return;

        const message = stream.readVarString() catch return;
        const success = stream.readBool() catch return;

        _ = self.counters.command_outputs.fetchAdd(1, .monotonic);
        if (success) {
            self.log("command ok: {s}", .{message});
            return;
        }

        _ = self.counters.command_failures.fetchAdd(1, .monotonic);
        self.log("command failed: {s}", .{message});
    }

    /// Fills the hotbar through the real command channel, one command per `SETUP_PERIOD_NS`.
    fn pumpSetup(self: *Bot, now: std.Io.Timestamp) void {
        const total = if (self.config.curse_binding)
            CURSE_STEPS
        else if (self.config.duel)
            duelSetupSteps(self.config, duelRole(self.config, self.index))
        else if (self.config.give_items)
            setupSteps(self.config.enchant_items)
        else
            return;
        if (self.setup_step >= total) {
            self.pumpDuelReady(now);
            return;
        }

        if (!self.setup_armed) {
            self.setup_armed = true;
            self.setup_last = now;
            return;
        }

        const elapsed = self.setup_last.untilNow(self.config.io, .awake).toNanoseconds();
        const due = @divTrunc(elapsed, self.setup_period_ns);
        if (due <= 0) return;
        self.setup_last = now;

        const commands: usize = @intCast(@min(due, 16));
        for (0..commands) |_| {
            if (self.setup_step >= total) break;
            self.sendSetupCommand();
            self.setup_step += 1;
        }
    }

    fn sendSetupCommand(self: *Bot) void {
        const step = self.setup_step;

        if (self.config.duel) {
            self.sendDuelStep(step);
            return;
        }

        if (self.config.curse_binding) {
            self.sendCurseStep(step);
            return;
        }

        if (step < SETUP_SLOTS) {
            const command = std.fmt.bufPrint(&self.setup_buf, "give {s} {s}", .{ self.name, SETUP_ITEM }) catch return;
            self.sendCommand(command);
            return;
        }
        if (!self.config.enchant_items) return;

        const offset = step - SETUP_SLOTS;
        const slot = offset / SETUP_STEPS_PER_SLOT;
        const sub_step = offset % SETUP_STEPS_PER_SLOT;
        if (slot >= SETUP_SLOTS) return;

        if (sub_step == 0) {
            self.sendMobEquipment(@intCast(slot));
            return;
        }

        const enchantment = SETUP_ENCHANTMENTS[sub_step - 1];
        const command = std.fmt.bufPrint(
            &self.setup_buf,
            "enchant {s} {s} {d}",
            .{ self.name, enchantment.name, enchantment.level },
        ) catch return;
        self.sendCommand(command);
    }

    /// Armor scenario: the packet order is the point.
    fn sendCurseStep(self: *Bot, step: usize) void {
        const curse_step = curseStep(step) orelse return;
        switch (curse_step) {
            .give => {
                const command = std.fmt.bufPrint(&self.setup_buf, "give {s} {s}", .{ self.name, CURSE_ITEM }) catch return;
                self.sendCommand(command);
            },
            .select => self.sendMobEquipment(CURSE_HOTBAR_SLOT),
            .enchant => {
                const command = std.fmt.bufPrint(&self.setup_buf, "enchant {s} {s} 1", .{ self.name, CURSE_ENCHANTMENT }) catch return;
                self.sendCommand(command);
            },
            .wear, .control, .remove => {
                const swap = curseSwap(curse_step).?;
                const request_id = self.sendSwap(swap.source, swap.destination);
                switch (curse_step) {
                    .wear => {
                        self.curse_wear_request = request_id;
                        self.verdict("putting the {s} on in armor slot {d}", .{ CURSE_ITEM, CURSE_ARMOR_SLOT });
                    },
                    .control => {
                        self.curse_control_request = request_id;
                        self.verdict("control: taking the empty armor slot {d} off has to be allowed", .{CURSE_CONTROL_SLOT});
                    },
                    else => {
                        self.curse_remove_request = request_id;
                        self.verdict("asking the server to take the {s} off", .{CURSE_ITEM});
                    },
                }
            },
        }
    }

    /// The duel set-up: `/give` each piece, enchant it while selected, then equip it.
    fn sendDuelStep(self: *Bot, step: usize) void {
        switch (duelRole(self.config, self.index)) {
            .attacker => switch (duelAttackerStep(self.config, step) orelse return) {
                .gamemode => self.sendDuelGamemode(),
                .give_weapon => self.sendDuelGive(self.config.duel_weapon),
                .select_weapon => self.sendMobEquipment(0),
            },
            .victim => switch (duelVictimStep(self.config, step) orelse return) {
                .gamemode => self.sendDuelGamemode(),
                .give => |piece| self.sendDuelGive(DUEL_ARMOR[piece]),
                .select => |piece| self.sendMobEquipment(piece),
                .enchant => self.sendDuelEnchant(self.config.duel_enchant, self.config.duel_level),
                .thorns => self.sendDuelEnchant("thorns", DUEL_THORNS_LEVEL),
                .equip => |piece| {
                    _ = self.sendSwap(
                        .{ .container = .HotbarAndInventory, .slot = piece },
                        .{ .container = .Armor, .slot = piece },
                    );
                },
            },
            .none => {},
        }
    }

    fn sendDuelGamemode(self: *Bot) void {
        const command = std.fmt.bufPrint(&self.setup_buf, "gamemode survival {s}", .{self.name}) catch return;
        self.sendCommand(command);
    }

    fn sendDuelGive(self: *Bot, item: []const u8) void {
        const command = std.fmt.bufPrint(&self.setup_buf, "give {s} {s}", .{ self.name, item }) catch return;
        self.sendCommand(command);
    }

    fn sendDuelEnchant(self: *Bot, enchantment: []const u8, level: u8) void {
        const command = std.fmt.bufPrint(&self.setup_buf, "enchant {s} {s} {d}", .{ self.name, enchantment, level }) catch return;
        self.sendCommand(command);
    }

    fn pumpDuel(self: *Bot, now: std.Io.Timestamp) void {
        if (!self.config.duel) return;
        switch (duelRole(self.config, self.index)) {
            .attacker => self.pumpDuelSwings(now),
            .victim => self.pumpDuelSummary(now),
            .none => {},
        }
    }

    /// Attacker waits for this before swinging, so no rung measures a half set.
    fn pumpDuelReady(self: *Bot, now: std.Io.Timestamp) void {
        if (duelRole(self.config, self.index) != .victim or self.duel_ready_sent) return;
        if (!self.duel_ready_armed) {
            self.duel_ready_armed = true;
            self.duel_ready_at = now;
            return;
        }
        if (self.duel_ready_at.untilNow(self.config.io, .awake).toNanoseconds() < DUEL_READY_GRACE_NS) return;

        self.duel_ready_sent = true;
        self.counters.duel_ready.store(1, .release);
        self.verdict("duel: {d} piece(s) of {s} {d} on, {d} thorns piece(s), ready for swings", .{
            self.config.duel_pieces,
            self.config.duel_enchant,
            self.config.duel_level,
            self.config.duel_thorns,
        });
    }

    fn pumpDuelSwings(self: *Bot, now: std.Io.Timestamp) void {
        if (self.duel_swings_sent >= self.config.duel_swings) {
            self.pumpDuelAttackerSummary();
            return;
        }
        if (self.counters.duel_ready.load(.acquire) == 0) return;
        const target = self.duel_target_runtime_id orelse return;

        if (!self.duel_swing_armed) {
            self.duel_swing_armed = true;
            self.duel_swing_last = now;
            return;
        }
        if (self.duel_swing_last.untilNow(self.config.io, .awake).toNanoseconds() < DUEL_SWING_PERIOD_NS) return;
        self.duel_swing_last = now;

        self.sendAttack(target);
        self.duel_swings_sent += 1;
        _ = self.counters.duel_swings.fetchAdd(1, .monotonic);
        if (self.duel_swings_sent == self.config.duel_swings) {
            self.duel_summary_armed = true;
            self.duel_summary_at = now;
        }
    }

    fn pumpDuelAttackerSummary(self: *Bot) void {
        if (self.duel_summary_done or !self.duel_summary_armed) return;
        if (self.duel_summary_at.untilNow(self.config.io, .awake).toNanoseconds() < DUEL_SUMMARY_DELAY_NS) return;
        self.duel_summary_done = true;

        self.verdict("duel: {d} swings thrown, {d} reflection(s) for {d:.2} damage", .{
            self.duel_swings_sent,
            self.duel_reflections,
            self.duel_reflection_total,
        });
    }

    fn pumpDuelSummary(self: *Bot, now: std.Io.Timestamp) void {
        if (self.duel_summary_done) return;
        if (self.counters.duel_swings.load(.acquire) < self.config.duel_swings) return;

        if (!self.duel_summary_armed) {
            self.duel_summary_armed = true;
            self.duel_summary_at = now;
            return;
        }
        if (self.duel_summary_at.untilNow(self.config.io, .awake).toNanoseconds() < DUEL_SUMMARY_DELAY_NS) return;
        self.duel_summary_done = true;

        const health = self.duel_health orelse 20.0;
        self.verdict("duel: took {d} hit(s), health now {d:.2}, first hit {d:.2} ({d:.2} hearts)", .{
            self.duel_hits,
            health,
            self.duel_first_damage,
            self.duel_first_damage / 2.0,
        });
    }

    fn sendAttack(self: *Bot, target_runtime_id: u64) void {
        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        writeAttack(&stream, target_runtime_id, 0, self.position) catch return;
        self.send(stream.getBuffer());
    }

    /// Moves a stack between containers the drag scenario cannot reach.
    fn sendSwap(self: *Bot, source: SlotRef, destination: SlotRef) i32 {
        self.inv_request_id +%= 1;

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        writeInventoryRequest(&stream, self.inv_request_id, source, destination) catch return self.inv_request_id;
        self.send(stream.getBuffer());
        _ = self.counters.inv_requests.fetchAdd(1, .monotonic);
        return self.inv_request_id;
    }

    fn sendCommand(self: *Bot, command: []const u8) void {
        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        writeCommandRequest(&stream, command) catch return;
        self.send(stream.getBuffer());
        _ = self.counters.commands_sent.fetchAdd(1, .monotonic);
    }

    fn sendMobEquipment(self: *Bot, slot: u8) void {
        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        stream.writeVarInt(Protocol.Packet.MobEquipment) catch return;
        stream.writeVarLong(@intCast(self.index + 1)) catch return;
        Protocol.NetworkItemStackDescriptor.writeShort(&stream, .{
            .network = 0,
            .stack_size = null,
            .metadata = null,
            .item_stack_id = null,
            .network_block_id = null,
            .extras = null,
        }, self.allocator) catch return;
        stream.writeUint8(slot) catch return;
        stream.writeUint8(slot) catch return;
        stream.writeInt8(@intFromEnum(Protocol.ContainerId.Inventory)) catch return;

        self.send(stream.getBuffer());
    }

    /// Drags slot A onto slot B and back, one `ItemStackRequest` at a time at `--inventory-hz`.
    fn pumpInventory(self: *Bot, now: std.Io.Timestamp) void {
        if (!self.config.inventory or self.inv_period_ns <= 0) return;
        if (!self.inv_armed) {
            self.inv_armed = true;
            self.inv_last = now;
            return;
        }

        const elapsed = self.inv_last.untilNow(self.config.io, .awake).toNanoseconds();
        const due = @divTrunc(elapsed, self.inv_period_ns);
        if (due <= 0) return;
        self.inv_last = now;

        const count: usize = @intCast(@min(due, 64));
        for (0..count) |_| self.sendInventoryRequest();
    }

    fn sendInventoryRequest(self: *Bot) void {
        self.inv_request_id +%= 1;
        const source: u8 = if (self.inv_flip) INVENTORY_SLOT_B else INVENTORY_SLOT_A;
        const destination: u8 = if (self.inv_flip) INVENTORY_SLOT_A else INVENTORY_SLOT_B;
        self.inv_flip = !self.inv_flip;

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        writeInventoryRequest(
            &stream,
            self.inv_request_id,
            .{ .container = .HotbarAndInventory, .slot = source },
            .{ .container = .HotbarAndInventory, .slot = destination },
        ) catch return;
        self.send(stream.getBuffer());
        _ = self.counters.inv_requests.fetchAdd(1, .monotonic);
    }

    /// The attacker learns its target from the announce packet.
    fn handleAddPlayer(self: *Bot, stream: *BinaryStream) void {
        if (duelRole(self.config, self.index) != .attacker) return;
        if (self.duel_target_runtime_id != null) return;

        _ = stream.readVarInt() catch return;
        _ = stream.read(16); // uuid
        const username = stream.readVarString() catch return;
        const runtime_id = stream.readVarLong() catch return;
        if (std.mem.eql(u8, username, self.name)) return;

        self.duel_target_runtime_id = runtime_id;
        self.verdict("duel: target {s} is runtime id {d}", .{ username, runtime_id });
    }

    /// Victim health reads the mitigation ladder; attacker health, the Thorns dice.
    fn handleUpdateAttributes(self: *Bot, stream: *BinaryStream) void {
        const role = duelRole(self.config, self.index);
        if (role == .none) return;

        _ = stream.readVarInt() catch return;
        const update = readHealthUpdate(stream) orelse return;
        const value = update.health;

        if (self.duel_self_runtime_id == null) {
            self.duel_self_runtime_id = update.runtime_actor_id;
            self.duel_health = value;
            return;
        }
        if (update.runtime_actor_id != self.duel_self_runtime_id.?) return;

        const previous = self.duel_health orelse value;
        self.duel_health = value;
        if (value >= previous) return;

        switch (role) {
            .victim => {
                self.duel_hits += 1;
                if (self.duel_first_damage == 0) self.duel_first_damage = previous - value;
                self.verdict("duel hit {d}: {d:.2} -> {d:.2} ({d:.2} hearts)", .{
                    self.duel_hits,
                    previous,
                    value,
                    (previous - value) / 2.0,
                });
            },
            .attacker => {
                self.duel_reflections += 1;
                self.duel_reflection_total += previous - value;
                self.verdict("duel reflection {d}: {d:.2} -> {d:.2} ({d:.2} damage)", .{
                    self.duel_reflections,
                    previous,
                    value,
                    previous - value,
                });
            },
            .none => {},
        }
    }

    fn handleDisconnect(self: *Bot, stream: *BinaryStream) void {
        const packet = Protocol.DisconnectPacket.deserialize(stream) catch return;
        const message = if (packet.messages) |messages| messages.message else "";
        self.log("kicked: {s} {s}", .{ @tagName(packet.reason), message });
        _ = self.counters.kicked.fetchAdd(1, .monotonic);
        self.setStage(.closed);
    }

    fn spawn(self: *Bot) void {
        if (self.stage.load(.acquire) == @intFromEnum(Stage.active)) return;

        _ = self.counters.spawned.fetchAdd(1, .monotonic);
        self.sendSetLocalPlayerAsInitialized();
        self.setStage(.active);
        self.log("spawned at {d:.1},{d:.1},{d:.1}", .{ self.position.x, self.position.y, self.position.z });
    }

    fn sendRequestNetworkSettings(self: *Bot) void {
        var packet = Protocol.RequestNetworkSettingsPacket{ .protocol = Protocol.PROTOCOL };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    fn sendLogin(self: *Bot) void {
        if (self.stage.load(.acquire) != @intFromEnum(Stage.requesting_settings)) return;
        self.setStage(.authenticating);

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        // Hand-written: `LoginPacket.serialize` does not compile in the pinned protocol revision.
        const identity_bytes = self.credentials.identity;
        const client_bytes = self.credentials.client;
        const body_len: u32 = @intCast(identity_bytes.len + client_bytes.len + 8);

        stream.writeVarInt(Protocol.Packet.Login) catch return;
        stream.writeInt32(Protocol.PROTOCOL, .Big) catch return;
        stream.writeVarInt(body_len) catch return;
        stream.writeString32(identity_bytes, .Little) catch return;
        stream.writeString32(client_bytes, .Little) catch return;

        self.send(stream.getBuffer());
        self.log("login chain sent", .{});
    }

    fn sendResourcePackResponse(self: *Bot, response: Protocol.ResourcePackResponse) void {
        var packet = Protocol.ResourcePackResponsePacket{ .response = response };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    fn sendRequestChunkRadius(self: *Bot) void {
        var packet = Protocol.RequestChunkRadiusPacket{
            .radius = self.config.chunk_radius,
            .max_radius = @intCast(@min(self.config.chunk_radius, 255)),
        };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
        self.setStage(.joining);
    }

    fn sendSetLocalPlayerAsInitialized(self: *Bot) void {
        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        stream.writeVarInt(Protocol.Packet.SetLocalPlayerAsInitialized) catch return;
        stream.writeVarInt(0) catch return;
        self.send(stream.getBuffer());
    }

    fn sendAuthInput(self: *Bot) void {
        self.input_tick += 1;

        const delta = self.advance();
        const input_data = InputDataBits.init(inputFlags(self.config));

        var packet = Protocol.PlayerAuthInputPacket{
            .rotation = Protocol.Vector3f.init(0, self.walkYaw(), self.walkYaw()),
            .position = self.position,
            .motion = Protocol.Vector2f.init(delta.x * 20, delta.z * 20),
            .input_data = input_data,
            .input_mode = .Mouse,
            .play_mode = .Normal,
            .interaction_mode = .Crosshair,
            .interact_rotation = Protocol.Vector2f.zero(),
            .input_tick = self.input_tick,
            .position_delta = delta,
        };

        var stream = BinaryStream.init(self.allocator, null, null);
        defer stream.deinit();

        const serialized = packet.serialize(&stream) catch return;
        self.send(serialized);
    }

    /// Patrols `--spacing` blocks along +x and back, crossing chunk borders.
    fn advance(self: *Bot) Protocol.Vector3f {
        if (!self.config.walk) return Protocol.Vector3f.init(0, 0, 0);

        const step = self.config.speed / 20.0;
        self.walk_offset += step * self.walk_direction;

        if (self.walk_offset >= self.config.spacing) {
            self.walk_offset = self.config.spacing;
            self.walk_direction = -1;
        } else if (self.walk_offset <= 0) {
            self.walk_offset = 0;
            self.walk_direction = 1;
        }

        const previous = self.position;
        self.position.x = self.origin.x + self.walk_offset;

        return Protocol.Vector3f.init(
            self.position.x - previous.x,
            0,
            self.position.z - previous.z,
        );
    }

    fn walkYaw(self: *Bot) f32 {
        if (!self.config.walk) return 0;
        return if (self.walk_direction > 0) 90.0 else 270.0;
    }

    fn send(self: *Bot, packet: []const u8) void {
        const packets = [_][]const u8{packet};
        const encoded = framing.encode(&packets, self.config.frame_options, self.allocator) catch return;
        defer self.allocator.free(encoded);

        self.client.sendReliableMessage(encoded, .Normal);
        _ = self.counters.packets_sent.fetchAdd(1, .monotonic);
        _ = self.counters.bytes_sent.fetchAdd(encoded.len, .monotonic);
    }
};

fn fromContext(context: ?*anyopaque) *Bot {
    return @ptrCast(@alignCast(context.?));
}

/// Hand-written: pinned protocol only deserializes the request; one per packet.
fn writeInventoryRequest(stream: *BinaryStream, request_id: i32, source: SlotRef, destination: SlotRef) !void {
    try stream.writeVarInt(Protocol.Packet.ItemStackRequest);
    try stream.writeVarInt(1);
    try stream.writeZigZag(request_id);
    try stream.writeVarInt(1);
    try stream.writeVarInt(@intFromEnum(Protocol.StackRequestActionType.Swap));
    // The wire repeats the action type as a single byte before the payload.
    try stream.writeUint8(@intFromEnum(Protocol.StackRequestActionType.Swap));
    try writeSlotInfo(stream, source);
    try writeSlotInfo(stream, destination);
    try stream.writeVarInt(0);
    try stream.writeInt32(0, .Little);
}

/// Hand-written: `CommandRequestPacket` also only deserializes in the pinned revision.
fn writeCommandRequest(stream: *BinaryStream, command: []const u8) !void {
    try stream.writeVarInt(Protocol.Packet.CommandRequest);
    try stream.writeVarString(command);
    try stream.writeVarString("player");
    try stream.write(&([_]u8{0} ** 16));
    try stream.writeVarString("1");
    try stream.writeInt64(0, .Little);
    try stream.writeBool(false);
    try stream.writeInt32(0, .Little);
}

fn writeSlotInfo(stream: *BinaryStream, ref: SlotRef) !void {
    try stream.writeUint8(@intFromEnum(ref.container));
    try stream.writeBool(false);
    try stream.writeUint8(ref.slot);
    // The server only reads the network stack id for `mine_block`.
    try stream.writeInt32(0, .Little);
}

/// Hand-written: pinned `UpdateAttributesPacket.deserialize` does not compile.
const HealthUpdate = struct { runtime_actor_id: i64, health: f32 };

fn readHealthUpdate(stream: *BinaryStream) ?HealthUpdate {
    const runtime_actor_id = stream.readVarLong() catch return null;
    const count = stream.readVarInt() catch return null;

    var health: ?f32 = null;
    for (0..count) |_| {
        _ = stream.readFloat32(.Little) catch return null; // min
        _ = stream.readFloat32(.Little) catch return null; // max
        const current = stream.readFloat32(.Little) catch return null;
        _ = stream.readFloat32(.Little) catch return null; // default min
        _ = stream.readFloat32(.Little) catch return null; // default max
        _ = stream.readFloat32(.Little) catch return null; // default

        const name = stream.readVarString() catch return null;
        if (std.mem.eql(u8, name, "minecraft:health")) health = current;

        const modifier_count = stream.readVarInt() catch return null;
        for (0..modifier_count) |_| {
            _ = stream.readVarString() catch return null; // id
            _ = stream.readVarString() catch return null; // name
            _ = stream.readFloat32(.Little) catch return null; // amount
            _ = stream.readInt32(.Little) catch return null; // operation
            _ = stream.readInt32(.Little) catch return null; // operand
            _ = stream.readBool() catch return null; // serializable
        }
    }

    const value = health orelse return null;
    return .{ .runtime_actor_id = @bitCast(runtime_actor_id), .health = value };
}

/// Hand-written: pinned protocol only deserializes `InventoryTransaction`.
fn writeAttack(stream: *BinaryStream, target_runtime_id: u64, hotbar_slot: i32, position: Protocol.Vector3f) !void {
    try stream.writeVarInt(Protocol.Packet.InventoryTransaction);
    try stream.writeZigZag(0); // legacy request id
    try stream.writeBool(false); // no legacy slots
    try stream.writeVarInt(@intFromEnum(Protocol.TransactionType.UseItemOnEntity));
    try stream.writeVarInt(0); // action count: the payload is the transaction
    try stream.writeVarLong(target_runtime_id);
    try stream.writeZigZag(1); // action_type 1 = attack
    try stream.writeZigZag(hotbar_slot);
    try Protocol.NetworkItemStackDescriptor.writeShort(stream, .{
        .network = 0,
        .stack_size = null,
        .metadata = null,
        .item_stack_id = null,
        .network_block_id = null,
        .extras = null,
    }, stream.allocator);
    try Protocol.Vector3f.write(stream, position);
    try Protocol.Vector3f.write(stream, position);
}

fn inputFlags(config: *const Config) u64 {
    var flags: u64 = 0;
    if (!config.walk) return flags;

    flags |= @as(u64, 1) << @intFromEnum(Protocol.InputData.Up);
    if (config.speed > 5.0) flags |= @as(u64, 1) << @intFromEnum(Protocol.InputData.SprintDown);
    return flags;
}

fn spawnPoint(config: *const Config, index: usize) Protocol.Vector3f {
    const y: f32 = config.spawn_y;
    switch (config.layout) {
        .cluster => {
            const per_side: usize = 15;
            const column: f32 = @floatFromInt(index % per_side);
            const row: f32 = @floatFromInt((index / per_side) % per_side);
            const layer: f32 = @floatFromInt(index / (per_side * per_side));
            return Protocol.Vector3f.init(column + 0.5 + layer * 0.01, y, row + 0.5 + layer * 0.01);
        },
        .grid => {
            const columns: usize = 16;
            const column: f32 = @floatFromInt(index % columns);
            const row: f32 = @floatFromInt(index / columns);
            return Protocol.Vector3f.init(column * config.spacing, y, row * config.spacing);
        },
    }
}

/// One command per bot per period: setup must not DoS the server.
const SETUP_PERIOD_NS: i96 = 30 * std.time.ns_per_ms;

const testing = std.testing;

test "the hand written command request decodes with the fields the server reads" {
    const allocator = testing.allocator;

    var wire = BinaryStream.init(allocator, null, null);
    defer wire.deinit();
    try writeCommandRequest(&wire, "enchant LoadBot0000 sharpness 5");

    var in = BinaryStream.init(allocator, wire.getBuffer(), 0);
    defer in.deinit();

    const request = try Protocol.CommandRequestPacket.deserialize(&in);
    try testing.expectEqualStrings("enchant LoadBot0000 sharpness 5", request.command_line);
    try testing.expectEqual(Protocol.CommandOriginType.Player, request.origin_type);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &request.uuid);
    try testing.expectEqual(@as(i64, 0), request.player_unique_id);
    try testing.expect(!request.internal);
}

test "the setup fills the hotbar and enchants each slot in turn" {
    try testing.expectEqual(SETUP_SLOTS, setupSteps(false));
    try testing.expectEqual(
        SETUP_SLOTS * (1 + SETUP_ENCHANTMENTS.len) + SETUP_SLOTS,
        setupSteps(true),
    );

    for (SETUP_ENCHANTMENTS) |enchantment| {
        try testing.expect(enchantment.level >= 1);
        try testing.expect(enchantment.name.len > 0);
    }
}

test "the hand written inventory request decodes as the swap it claims to be" {
    const allocator = testing.allocator;

    var wire = BinaryStream.init(allocator, null, null);
    defer wire.deinit();
    try writeInventoryRequest(
        &wire,
        7,
        .{ .container = .HotbarAndInventory, .slot = INVENTORY_SLOT_A },
        .{ .container = .HotbarAndInventory, .slot = INVENTORY_SLOT_B },
    );

    var in = BinaryStream.init(allocator, wire.getBuffer(), 0);
    defer in.deinit();

    var packet = try Protocol.ItemStackRequestPacket.deserialize(&in);
    defer packet.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), packet.requests.len);

    const request = packet.requests[0];
    try testing.expectEqual(@as(i32, 7), request.request_id);
    try testing.expectEqual(@as(usize, 1), request.actions.len);
    try testing.expectEqual(@as(usize, 0), request.filter_strings.len);

    const swap = switch (request.actions[0]) {
        .swap => |s| s,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, swap.source.container.identifier);
    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, swap.destination.container.identifier);
    try testing.expect(swap.source.container.dynamic_identifier == null);
    try testing.expectEqual(INVENTORY_SLOT_A, swap.source.slot);
    try testing.expectEqual(INVENTORY_SLOT_B, swap.destination.slot);
}

test "the armor request names the armor container at one end" {
    const allocator = testing.allocator;

    var wire = BinaryStream.init(allocator, null, null);
    defer wire.deinit();
    try writeInventoryRequest(
        &wire,
        9,
        .{ .container = .HotbarAndInventory, .slot = CURSE_HOTBAR_SLOT },
        .{ .container = .Armor, .slot = CURSE_ARMOR_SLOT },
    );

    var in = BinaryStream.init(allocator, wire.getBuffer(), 0);
    defer in.deinit();

    var packet = try Protocol.ItemStackRequestPacket.deserialize(&in);
    defer packet.deinit(allocator);

    const swap = switch (packet.requests[0].actions[0]) {
        .swap => |s| s,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqual(@as(i32, 9), packet.requests[0].request_id);
    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, swap.source.container.identifier);
    try testing.expectEqual(Protocol.ContainerName.Armor, swap.destination.container.identifier);
    try testing.expectEqual(CURSE_HOTBAR_SLOT, swap.source.slot);
    try testing.expectEqual(CURSE_ARMOR_SLOT, swap.destination.slot);
    try testing.expect(CURSE_ARMOR_SLOT < 4);
}

test "the curse scenario gives, selects, enchants, wears, controls and removes" {
    try testing.expectEqual(CURSE_STEPS, 6);
    try testing.expectEqual(CurseStep.give, curseStep(0).?);
    try testing.expectEqual(CurseStep.select, curseStep(1).?);
    try testing.expectEqual(CurseStep.enchant, curseStep(2).?);
    try testing.expectEqual(CurseStep.wear, curseStep(3).?);
    try testing.expectEqual(CurseStep.control, curseStep(4).?);
    try testing.expectEqual(CurseStep.remove, curseStep(CURSE_STEPS - 1).?);
    try testing.expect(curseStep(CURSE_STEPS) == null);
    try testing.expect(CURSE_HOTBAR_SLOT != CURSE_ARMOR_SLOT);
    try testing.expect(CURSE_CONTROL_SLOT != CURSE_ARMOR_SLOT);
}

// Pins the bug: a fixed source container made the removal an empty-slot equip.
test "the equip and the two removals are mirror images, not one request" {
    const wear = curseSwap(.wear).?;
    const control = curseSwap(.control).?;
    const remove = curseSwap(.remove).?;

    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, wear.source.container);
    try testing.expectEqual(Protocol.ContainerName.Armor, wear.destination.container);
    try testing.expectEqual(CURSE_HOTBAR_SLOT, wear.source.slot);
    try testing.expectEqual(CURSE_ARMOR_SLOT, wear.destination.slot);

    try testing.expectEqual(Protocol.ContainerName.Armor, control.source.container);
    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, control.destination.container);
    try testing.expectEqual(CURSE_CONTROL_SLOT, control.source.slot);

    try testing.expectEqual(Protocol.ContainerName.Armor, remove.source.container);
    try testing.expectEqual(Protocol.ContainerName.HotbarAndInventory, remove.destination.container);
    try testing.expectEqual(CURSE_ARMOR_SLOT, remove.source.slot);
    try testing.expectEqual(CURSE_HOTBAR_SLOT, remove.destination.slot);
    try testing.expect(control.source.slot != remove.source.slot);

    try testing.expect(curseSwap(.give) == null);
    try testing.expect(curseSwap(.select) == null);
    try testing.expect(curseSwap(.enchant) == null);
}

test "grid layout spreads bots one spacing apart" {
    const config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .layout = .grid,
        .spacing = 16.0,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
    };

    const first = spawnPoint(&config, 0);
    const second = spawnPoint(&config, 1);
    const seventeenth = spawnPoint(&config, 16);

    try testing.expectEqual(@as(f32, 0), first.x);
    try testing.expectEqual(@as(f32, 16), second.x);
    try testing.expectEqual(@as(f32, 16), seventeenth.z);
}

test "cluster layout keeps every bot inside one chunk" {
    const config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .layout = .cluster,
        .spacing = 16.0,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
    };

    for (0..500) |index| {
        const point = spawnPoint(&config, index);
        try testing.expect(point.x >= 0 and point.x < 16);
        try testing.expect(point.z >= 0 and point.z < 16);
    }
}

// Hand-written hit transaction: the handler reads only the runtime id and the action type.
test "the hand written attack decodes as the strike it claims to be" {
    const allocator = testing.allocator;

    var wire = BinaryStream.init(allocator, null, null);
    defer wire.deinit();
    try writeAttack(&wire, 4242, 0, Protocol.Vector3f.init(1.5, 100, 2.5));

    var in = BinaryStream.init(allocator, wire.getBuffer(), 0);
    defer in.deinit();

    const packet = try Protocol.InventoryTransactionPacket.deserialize(&in);
    try testing.expectEqual(Protocol.TransactionType.UseItemOnEntity, packet.transaction_type);
    try testing.expectEqual(@as(u32, 0), packet.action_count);

    const data = packet.transaction_data.use_item_on_entity;
    try testing.expectEqual(@as(u64, 4242), data.target_entity_runtime_id);
    try testing.expectEqual(@as(i32, 1), data.action_type);
    try testing.expectEqual(@as(i32, 0), data.hot_bar_slot);
    try testing.expectEqual(@as(f32, 1.5), data.position.x);
    try testing.expectEqual(@as(f32, 2.5), data.clicked_position.z);
}

// Pinned against `Attribute.write`: the bot cannot borrow the server's decoder.
test "the hand written health reader decodes what the server writes" {
    const allocator = testing.allocator;

    var attributes = [_]Protocol.Attribute{
        Protocol.Attribute.init(allocator, 0, 3.4e38, 0.1, 0.1, 3.4e38, 0.1, .Movement),
        Protocol.Attribute.init(allocator, 0, 20, 13.5, 0, 20, 20, .Health),
    };
    defer {
        for (&attributes) |*attribute| attribute.deinit();
    }

    var wire = BinaryStream.init(allocator, null, null);
    defer wire.deinit();
    try wire.writeVarLong(@bitCast(@as(i64, -77)));
    try Protocol.Attribute.write(&attributes, &wire);

    var in = BinaryStream.init(allocator, wire.getBuffer(), 0);
    defer in.deinit();

    const update = readHealthUpdate(&in) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, -77), update.runtime_actor_id);
    try testing.expectEqual(@as(f32, 13.5), update.health);
}

test "the duel gives the victim every piece and then enchant, thorns and equip" {
    var config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
        .duel = true,
    };

    // gamemode + four gives + (select + enchant + equip) x 4
    try testing.expectEqual(@as(usize, 17), duelSetupSteps(&config, .victim));
    try testing.expectEqual(@as(usize, 3), duelSetupSteps(&config, .attacker));

    var gives: usize = 0;
    var selects: usize = 0;
    var enchants: usize = 0;
    var equips: usize = 0;
    for (0..duelSetupSteps(&config, .victim)) |step| {
        switch (duelVictimStep(&config, step).?) {
            .gamemode => {},
            .give => gives += 1,
            .select => selects += 1,
            .enchant => enchants += 1,
            .thorns => return error.TestUnexpectedResult,
            .equip => equips += 1,
        }
    }
    try testing.expectEqual(@as(usize, 4), gives);
    try testing.expectEqual(@as(usize, 4), selects);
    try testing.expectEqual(@as(usize, 4), enchants);
    try testing.expectEqual(@as(usize, 4), equips);
    try testing.expect(duelVictimStep(&config, duelSetupSteps(&config, .victim)) == null);

    // The two ladder controls: unenchanted diamond ("none") and a typed protection.
    config.duel_enchant = "none";
    try testing.expectEqual(@as(usize, 13), duelSetupSteps(&config, .victim));
    config.duel_enchant = "fire_protection";
    try testing.expectEqual(@as(usize, 17), duelSetupSteps(&config, .victim));

    // Thorns rides on top of the protection pieces: two more commands, never a different slot.
    config.duel_thorns = 2;
    try testing.expectEqual(@as(usize, 19), duelSetupSteps(&config, .victim));
    var thorns: usize = 0;
    for (0..19) |step| {
        switch (duelVictimStep(&config, step).?) {
            .thorns => thorns += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 2), thorns);

    // The fist run: the attacker gives itself nothing.
    config.duel_weapon = "none";
    try testing.expectEqual(@as(usize, 1), duelSetupSteps(&config, .attacker));
    try testing.expect(duelAttackerStep(&config, 1) == null);
}

test "only the first two bots have a role in the duel" {
    const config = Config{
        .io = undefined,
        .host = "127.0.0.1",
        .port = 19132,
        .server_address = "127.0.0.1:19132",
        .game_version = "1.26.50",
        .stop = undefined,
        .duel = true,
    };

    try testing.expectEqual(DuelRole.attacker, duelRole(&config, 0));
    try testing.expectEqual(DuelRole.victim, duelRole(&config, 1));
    try testing.expectEqual(DuelRole.none, duelRole(&config, 2));
    try testing.expectEqual(@as(usize, 0), duelSetupSteps(&config, .none));
}
