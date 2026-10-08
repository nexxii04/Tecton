const std = @import("std");

const BinaryStream = @import("BinaryStream").BinaryStream;
const protocol = @import("protocol");
const Packet = protocol.Packet;
const Raknet = @import("Raknet");

const Tecton = @import("../tecton.zig").Tecton;
const NetworkHandler = @import("./network_handler.zig").NetworkHandler;
const TickProfilerPhase = @import("../tick_profiler.zig").Phase;

const handleAnimate = @import("./handlers/animate.zig").handleAnimate;
const handleBlockPickRequest = @import("./handlers/block_pick_request.zig").handleBlockPickRequest;
const handleClientCacheStatus = @import("./handlers/client_cache_status.zig").handleClientCacheStatus;
const handleCommandRequest = @import("./handlers/command_request.zig").handleCommandRequest;
const handleContainerClose = @import("./handlers/container_close.zig").handleContainerClose;
const handleInteract = @import("./handlers/interact.zig").handleInteract;
const handleInventoryTransaction = @import("./handlers/inventory_transaction.zig").handleInventoryTransaction;
const handleItemStackRequest = @import("./handlers/item_stack_request.zig").handleItemStackRequest;
const handleLogin = @import("./handlers/login.zig").handleLogin;
const handleMobEquipment = @import("./handlers/mob_equipment.zig").handleMobEquipment;
const handlePlayerHotbar = @import("./handlers/player_hotbar.zig").handlePlayerHotbar;
const handlePacketViolationWarning = @import("./handlers/packet_violation_warning.zig").handlePacketViolationWarning;
const handlePlayerAction = @import("./handlers/player_action.zig").handlePlayerAction;
const handlePlayerAuthInput = @import("./handlers/player_auth_input.zig").handlePlayerAuthInput;
const handleRequestChunkRadius = @import("./handlers/request_chunk_radius.zig").handleRequestChunkRadius;
const handleRespawn = @import("./handlers/respawn.zig").handleRespawn;
const handleNetworkSettings = @import("./handlers/request_network_settings.zig").handleNetworkSettings;
const handleResourcePack = @import("./handlers/resource_packs_response.zig").handleResourcePack;
const handleSetLocalPlayerAsInitialized = @import("./handlers/set_local_player_as_initialized.zig").handleSetLocalPlayerAsInitialized;
const handleTextPacket = @import("./handlers/text.zig").handleTextPacket;

const Route = struct {
    id: u32,
    handler: *const fn (*Tecton, *NetworkHandler, *Raknet.Connection, *BinaryStream) anyerror!void,
    phase: TickProfilerPhase,
    label: []const u8,
};

const routes = [_]Route{
    .{ .id = Packet.RequestNetworkSettings, .handler = handleNetworkSettings, .phase = .handler_other, .label = "RequestNetworkSettings" },
    .{ .id = Packet.Login, .handler = handleLogin, .phase = .handler_other, .label = "Login" },
    .{ .id = Packet.ResourcePackResponse, .handler = handleResourcePack, .phase = .handler_other, .label = "ResourcePackResponse" },
    .{ .id = Packet.Text, .handler = handleTextPacket, .phase = .handler_other, .label = "Text" },
    .{ .id = Packet.RequestChunkRadius, .handler = handleRequestChunkRadius, .phase = .handler_chunk_request, .label = "RequestChunkRadius" },
    .{ .id = Packet.SetLocalPlayerAsInitialized, .handler = handleSetLocalPlayerAsInitialized, .phase = .handler_other, .label = "SetLocalPlayerAsInitialized" },
    .{ .id = Packet.PlayerAuthInput, .handler = handlePlayerAuthInput, .phase = .handler_player_auth, .label = "PlayerAuthInput" },
    .{ .id = Packet.Animate, .handler = handleAnimate, .phase = .handler_other, .label = "Animate" },
    .{ .id = Packet.ClientCacheStatus, .handler = handleClientCacheStatus, .phase = .handler_other, .label = "ClientCacheStatus" },
    .{ .id = Packet.Interact, .handler = handleInteract, .phase = .handler_other, .label = "Interact" },
    .{ .id = Packet.MobEquipment, .handler = handleMobEquipment, .phase = .handler_other, .label = "MobEquipment" },
    .{ .id = Packet.PlayerHotbar, .handler = handlePlayerHotbar, .phase = .handler_other, .label = "PlayerHotbar" },
    .{ .id = Packet.ContainerClose, .handler = handleContainerClose, .phase = .handler_other, .label = "ContainerClose" },
    .{ .id = Packet.InventoryTransaction, .handler = handleInventoryTransaction, .phase = .handler_inventory, .label = "InventoryTransaction" },
    .{ .id = Packet.ItemStackRequest, .handler = handleItemStackRequest, .phase = .handler_inventory, .label = "ItemStackRequest" },
    .{ .id = Packet.PlayerAction, .handler = handlePlayerAction, .phase = .handler_other, .label = "PlayerAction" },
    .{ .id = Packet.Respawn, .handler = handleRespawn, .phase = .handler_other, .label = "Respawn" },
    .{ .id = Packet.CommandRequest, .handler = handleCommandRequest, .phase = .handler_other, .label = "CommandRequest" },
    .{ .id = Packet.PacketViolationWarning, .handler = handlePacketViolationWarning, .phase = .handler_other, .label = "PacketViolationWarning" },
    .{ .id = Packet.BlockPickRequest, .handler = handleBlockPickRequest, .phase = .handler_other, .label = "BlockPickRequest" },
};

const ignored_packets = [_]u32{
    Packet.EmoteList,
    Packet.ServerboundLoadingScreenPacket,
    Packet.SetPlayerInventoryOptions,
};

pub fn dispatchFromHost(ctx: *anyopaque, conn: *Raknet.Connection, packets: []const []const u8) void {
    const tecton: *Tecton = @ptrCast(@alignCast(ctx));
    dispatch(tecton, tecton.network, conn, packets);
}

pub fn dispatch(tecton: *Tecton, network: *NetworkHandler, conn: *Raknet.Connection, packets: []const []const u8) void {
    const io = tecton.io;
    const started = std.Io.Timestamp.now(io, .awake);
    defer {
        const elapsed = started.durationTo(.now(io, .awake));
        tecton.profiler.record(.packet_dispatch, @intCast(@max(0, elapsed.nanoseconds)));
    }

    for (packets) |packet| {
        if (packet.len == 0) continue;

        var stream = BinaryStream.init(network.allocator, packet, null);
        defer stream.deinit();

        const raw_id = stream.readVarInt() catch continue;
        stream.offset = 0;

        if (raw_id < 0) continue;
        dispatchOne(tecton, network, conn, @intCast(raw_id), &stream, packet.len);
    }
}

fn dispatchOne(
    tecton: *Tecton,
    network: *NetworkHandler,
    conn: *Raknet.Connection,
    id: u32,
    stream: *BinaryStream,
    payload_len: usize,
) void {
    for (routes) |route| {
        if (route.id != id) continue;
        const started = std.Io.Timestamp.now(tecton.io, .awake);
        route.handler(tecton, network, conn, stream) catch |err| {
            Raknet.Logger.ERROR("{s} error: {any}", .{ route.label, err });
        };
        const elapsed = started.durationTo(.now(tecton.io, .awake));
        tecton.profiler.record(route.phase, @intCast(@max(0, elapsed.nanoseconds)));
        return;
    }

    for (ignored_packets) |ignored| {
        if (ignored != id) continue;
        std.debug.print("[net-dispatch] id=0x{x:0>2} explicitly ignored (no handler)\n", .{id});
        return;
    }

    std.debug.print("[net-dispatch] id=0x{x:0>2} UNHANDLED -> falling through payload_len={d}\n", .{ id, payload_len });
    Raknet.Logger.INFO("Unhandled packet 0x{x}", .{id});
}

test "the route table has no duplicate ids" {
    for (routes, 0..) |route, i| {
        for (routes[i + 1 ..]) |other| {
            if (route.id != other.id) continue;
            std.debug.print(
                "net/dispatch.zig: {s} and {s} share id 0x{x}\n",
                .{ route.label, other.label, route.id },
            );
            return error.TestUnexpectedResult;
        }
    }
}
