# Conduit C-ABI Plugin API

## Runtime layout

```text
include/conduit_plugin.h
src/conduit/plugins/abi.zig
src/conduit/plugins/dynamic_loader.zig
src/conduit/plugins/runtime.zig
plugins/
```

The public header is the only contract a native plugin needs. Zig implementation details are private to Conduit.

## Loading

Conduit scans `plugins/` at startup, filters the platform library suffix, sorts names bytewise, and loads each library in deterministic order. A library exports `conduit_plugin_get_descriptor` and returns a descriptor accepted for the host ABI and protocol.

A failed plugin is isolated and logged. Other plugins continue loading.

## ABI stability

The ABI uses fixed-width integers, `extern struct`, opaque handles, explicit byte lengths, function tables, and descriptor sizes. New fields are appended to tables and structures. Existing fields are never reordered or removed. A plugin must check `struct_size` before reading optional host fields.

The host advertises optional capabilities through `features`. Plugins can require a capability before registering behavior and can remain compatible with older hosts by checking the advertised structure size. The root host table exposes `get_interface` for independently versioned interfaces such as core, scheduling, events, worlds, entities, items, blocks, inventories, registries, and network. Interface tables begin with `conduit_interface_header`; new fields are appended and must be guarded by `struct_size`.

The plugin ABI minor version describes host additions. The current host minor is `4`. Descriptor and payload fields are append-only. A plugin must request descriptor information using the query minor it understands, and the host validates only the minimum prefix required by that descriptor version.

## Lifecycle

The loader invokes callbacks in this order:

```text
get_descriptor
on_load
on_start
on_shutdown
on_unload
```

A callback failure prevents activation and closes the library without leaving a live registration behind.

## Core interface

The core interface is available when `CONDUIT_PLUGIN_FEATURE_CORE` is advertised and is requested with `CONDUIT_INTERFACE_CORE`. Its current operations are read-only:

```c
uint64_t tick;
uint32_t state;
core->get_tick(host_userdata, &tick);
core->get_state(host_userdata, &state);
```

Server states are `STARTING`, `RUNNING`, `STOPPING`, and `STOPPED`. Values are process-local and the interface returns a result code for unavailable data.

## Scheduler interface

The scheduler is available through `CONDUIT_INTERFACE_SCHEDULER`. Scheduled callbacks execute on Conduit's main tick queue and return a task handle. A task callback must be short and must not retain ABI views after returning. Tasks are owned by the plugin id supplied at scheduling time; the runtime cancels an owner's pending tasks before unloading its native library.

```c
scheduler->schedule(userdata, plugin_id, callback, callback_userdata, &task);
scheduler->cancel(userdata, task);
scheduler->cancel_owner(userdata, plugin_id);
```

Scheduler callbacks are one-shot. They are intentionally separate from the threaded worker queue so plugins have an explicit main-thread boundary before future world, entity, inventory, or registry mutations are added.

## Read-only world, player, and entity interfaces

The host exposes independent snapshot interfaces for stable read-only access. They are requested with `CONDUIT_INTERFACE_WORLD`, `CONDUIT_INTERFACE_PLAYERS`, and `CONDUIT_INTERFACE_ENTITIES` when the corresponding features are advertised. Snapshot structures contain borrowed string views and opaque generational handles; they are valid only for the call that filled the structure, while handles must be revalidated by each operation.

The world interface resolves a world name and returns its stable identifier. The players interface enumerates active players and returns names, UUIDs, world and dimension identifiers, runtime ids, and positions. The entities interface enumerates entities in a world dimension and returns their type, location, runtime id, and opaque handle. These interfaces do not mutate Conduit state and are suitable for callbacks and main-thread plugin tasks.

```c
world->find(userdata, name, &world_handle);
world->get_snapshot(userdata, world_handle, &world_snapshot, sizeof(world_snapshot));
players->count(userdata, &count);
players->get_snapshot(userdata, index, &player_snapshot, sizeof(player_snapshot));
entities->count(userdata, world_handle, dimension, &count);
entities->get_snapshot(userdata, world_handle, dimension, index, &entity_snapshot, sizeof(entity_snapshot));
```

All snapshot calls return `CONDUIT_RESULT_NOT_FOUND` for an invalid index or missing resource and `CONDUIT_RESULT_INVALID_HANDLE` for stale handles. Plugins must not retain string pointers or snapshots after the host call returns.

## Read-only items, blocks, and inventories interfaces

The items interface exposes registry snapshots with stable identifiers, network ids, stack limits, and stackability. The blocks interface reads a block permutation at a world, dimension, and coordinate. The inventories interface reads a player's inventory size and individual slots through a player handle. All three interfaces are read-only and return borrowed string views.

```c
items->count(userdata, &count);
items->get_snapshot(userdata, index, &item, sizeof(item));
blocks->get_snapshot(userdata, world, dimension, x, y, z, &block, sizeof(block));
inventories->get_size(userdata, player, &size);
inventories->get_item(userdata, player, slot, &item, sizeof(item));
```

An empty inventory slot returns `present == 0`. Invalid coordinates, handles, slots, and unavailable resources return a result code instead of exposing internal objects. These APIs do not allocate plugin-owned memory and their views must not be retained after the host call.

## Network interface

The network interface is available when `CONDUIT_PLUGIN_FEATURE_NETWORK` is advertised and is requested with `CONDUIT_INTERFACE_NETWORK`. It sends raw Bedrock packet bytes to one player or to every spawned player.

```c
network->send(userdata, player_handle, packet, CONDUIT_PACKET_PRIORITY_NORMAL);
network->broadcast(userdata, packet, CONDUIT_PACKET_PRIORITY_IMMEDIATE);
```

The packet is a `conduit_string_view` of bytes, not text: it must be a complete Bedrock packet beginning with its varint packet id, because the host forwards it as a RakNet reliable-ordered payload without inspecting it. The host copies the payload during the call and the plugin keeps ownership of its own buffer. Payloads larger than 1 MiB are rejected: they are fragmented into hundreds of frames and flood the client.

`CONDUIT_PACKET_PRIORITY_NORMAL` queues the packet for the next connection tick. `CONDUIT_PACKET_PRIORITY_IMMEDIATE` flushes the whole outgoing queue of that connection before returning, so it belongs to packets whose delay is visible (spawn, teleport, disconnect, kick) — that queue also holds chunk streaming, and a slow client absorbs tick time while it drains.

Sends are accepted only from the server tick thread, which is where event callbacks, scheduled tasks, and player callbacks run. A call from a plugin-owned thread returns `CONDUIT_RESULT_WRONG_THREAD` instead of racing the connection's outgoing queue. Invalid priorities, empty or oversized payloads, stale player handles, and an unavailable server return their matching result codes, and `broadcast` skips players that are still joining.

A plugin that sends packets owns the correctness of what it sends: the host cannot validate that the bytes form a legal packet, and a malformed payload reaches the client as-is.

## Logging

The host exposes four versioned logging callbacks after the original host table fields:

```c
log_debug(userdata, plugin_id, message);
log_info(userdata, plugin_id, message);
log_warn(userdata, plugin_id, message);
log_error(userdata, plugin_id, message);
```

Messages are borrowed for the duration of the call. The runtime forwards plugin logs through ZigNet's logger, preserving timestamps, colors, filtering, and level formatting. The plugin metadata name is added to the message, producing output such as `<18:34:02> INFO: [plugin:conduit-zig-example] message`. Plugins should use the logging callbacks instead of writing directly to process streams. Older hosts remain compatible when a plugin checks `struct_size` before reading these optional fields.

## Handles

Object values crossing the ABI are opaque handles. They are validated by kind, slot, and generation; native pointers are not part of the public contract. A handle is valid only for the lifetime documented by its interface and must be treated as invalid after a resource is destroyed or a callback ends.

## Events

Plugins subscribe through the host table with an event id, phase, priority, callback, userdata, and opaque subscription id. Conduit removes host-owned event bridges before unloading native libraries.

An event view is valid only during the callback. The original event view prefix remains stable; its appended `struct_size`, `flags`, and `payload_schema` fields are optional. Payloads use versioned external wrappers. `ServerTick` and player join/disconnect payloads are currently defined. Other events can be subscribed to safely and receive their stable id and phase until their payload wrapper is added.

Callbacks can set the event result to cancel a cancellable dispatch. Subscription mutation during dispatch is rejected to preserve iterator and callback safety.

## Ownership

Plugin-owned memory must use the host allocator when it crosses the ABI. Event views and payloads are borrowed and must not be retained. Native libraries are released only after shutdown and unload callbacks complete.
