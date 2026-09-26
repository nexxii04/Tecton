# Load testing with bots

`ConduitLoadBot` is a pile of fake Bedrock clients that log in, spawn, walk and
stream chunks against a running server. It exists because the player ceiling
cannot be measured with real clients: nobody can drive 300 phones, and the
tier 1 work (entry, exit and repetition) needs numbers that can be repeated
after every change.

The harness lives in `tools/loadbot/` and is deliberately **not** part of the
`conduit` module: it speaks the wire protocol with `Raknet`, `protocol` and
`BinaryStream`, exactly like a real client, and never touches server internals.

## Build and run

```bash
zig build loadbot                                  # builds zig-out/bin/ConduitLoadBot
zig build loadtest -- --bots 50 --walk --hold 60   # convenience wrapper
```

Run the server as a separate process so it can be profiled on its own:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/Conduit > /tmp/server.log 2>&1 &
./zig-out/bin/ConduitLoadBot --bots 200 --walk --hold 120 --ramp 50
```

Bots and server compete for CPU when they share a machine. For absolute
numbers run the bots from another host with `--host <server-ip>`; for
before/after comparisons the same box is fine as long as both runs use the
same arrangement.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--host`, `--port` | `127.0.0.1`, `19132` | where to connect |
| `--bots` | `10` | how many fake clients |
| `--ramp` | `20` | bots started per second (`0` = all at once) |
| `--hold` | `60` | seconds to stay connected after the ramp |
| `--name-prefix` | `LoadBot` | display name prefix; names are `LoadBot0000`, `LoadBot0001`… |
| `--chunk-radius` | `8` | view distance each bot requests |
| `--walk` | off | bots patrol instead of standing still |
| `--speed` | `4.3` | walking speed in blocks per second |
| `--layout cluster\|grid` | `grid` | `cluster` puts every bot inside one chunk (worst-case movement fan-out), `grid` spreads them one `--spacing` apart |
| `--spacing` | `16` | grid spacing and patrol length |
| `--no-compress` | off | send uncompressed datagrams, which costs the bot less CPU but skips the server's inflate path |
| `--report` | `5` | seconds between progress lines |
| `--mtu` | `1492` | MTU offered in the RakNet handshake |
| `--verbose` | off | log every bot event and every received packet id |

## Reading the output

```
t=  20s conn=50 spawn=50 fail=0 dead=0 | out 999/s 94.5 KB/s | in 1188/s 804.3 KB/s | move 44766/s (895.3/bot) chunk 224/s
```

- `conn` completed the RakNet handshake, `spawn` reached `PlayerSpawn` and sent
  `SetLocalPlayerAsInitialized`, `fail` never got that far, `dead` were
  disconnected by the server.
- `out` is what the bots send: 20 packets per bot per second once spawned, plus
  the join burst. If `out` is not `20 × spawn`, the bots are not keeping up.
- `in` is everything the server sent back, chunks included.
- `move` counts `MovePlayer` / `MoveActorDelta` / `MoveActorAbsolute`, and
  `(x/bot)` is that rate per bot. In `cluster` layout every walking bot is
  visible to every other one, so the ceiling is `(bots - 1) × 20` per bot;
  falling short of it means the server is not sending every update it could.
- `chunk` counts `LevelChunk` packets, which is the streaming load.

The harness only describes its own traffic. The other half of the picture is
the server: `dump/tick-profile.txt` (phase timings), the server's TPS line, and
`strace -c -f -e trace=sendto,recvfrom,mmap,write` plus RSS from
`/proc/<pid>/status`.

## Finding the ceiling

1. Warm up the world with a short run so chunk generation is not part of the
   measurement.
2. Ramp until `spawn` stops following `conn`, or `conn` stops following
   `started`, or the server's TPS line drops below 20.
3. Note where it broke and re-run the same parameters after the change. Same
   `--bots --layout --spacing --walk --ramp` and the same build mode.
4. For a per-point reading of the tier 1 SDDs, run once in `cluster` (worst
   case for the distance broadcasts) and once in `grid --spacing 64` (realistic
   spreading), and compare `move (x/bot)` and `KB/s` between them.

## What the bots are not

- **No Microsoft account.** The harness declares itself a guest
  (`AuthenticationType: 1`) and mints its own chain, so it only logs in against
  a server running `online-mode=false`: with online mode on, the login proves
  nothing and is refused (or let in as an offline identity if the operator
  turned on `online-mode-offline-fallback`, which is the one way to load test an
  online-mode server). In offline mode the server throws away what the chain
  claims and derives the uuid from the display name (see
  [authentication](authentication.md)), so **the names have to be unique across
  every concurrent harness run**: two bots called `LoadBot0000` are the same
  player. Use a different `--name-prefix` per run.
- **No skins.** The client data token carries no skin data, so a real client
  looking at a bot falls back to its default skin. Nothing on the server path
  rejects the entry: the player-list serializer writes empty geometry and a nil
  UUID instead of failing.
- **No client-side cache.** Bots never send `ClientCacheStatus`, so the server
  streams chunks the way it does for a brand new client.
- **No xuid and no real identity.** With `online-mode=false` the server
  discards both the claimed xuid and the claimed uuid, so bots appear in the
  player list with an empty xuid. A bot can never reach `online-mode=true` as a
  verified player: nothing it can sign is trusted there.
- **No inventory or world interaction.** Only login, join, chunk radius,
  `SetLocalPlayerInitialized` and `PlayerAuthInput` are sent.
- **One game packet per datagram** (plus the RakNet frame header), which is
  slightly more datagrams than a real client produces for movement.

## Things the harness had to work around

These are real incompatibilities in the current dependency set, and the reason
the tool is written the way it is:

1. `LoginPacket.serialize` in the pinned `protocol` revision does not compile:
   it passes `identity.len + client.len + 8` (a `usize`) to
   `BinaryStream.writeVarInt`, which takes `u32`. Only the server direction was
   ever built, so nobody noticed. The bot writes the Login packet by hand.
2. Packet deserializers in `protocol` expect the stream to be positioned at the
   packet id, and the server's dispatcher rewinds the stream after reading the
   id for exactly that reason. A client that reads the id and then calls
   `deserialize` on the same stream must rewind too, or every body is read one
   byte off.
3. A datagram with compression disabled is `0xfe` + length varint + packet,
   with **no** method byte. Only `0x00` (zlib), `0x01` (snappy) and `0xFF` (none)
   are followed by a method byte; anything else means the second byte is
   already the frame.
4. `PlayerAuthInputData` is not exported from `protocol`'s root, so the flag
   bitfield type is taken from the packet struct that carries it.

## If no bot connects

Check that the server is actually bound (`ss -lunp | grep 19132`) before
suspecting the harness. In one session a server process that had logged
`Starting server on 0.0.0.0:19132` answered no offline packets at all — not
even ZigNet's own `zig build bench` could connect to it — while a fresh
instance of the same binary served 50 clients without a failure. That was never
reproduced and no other run since has shown it.
