<div align="center">

# ⚡ Tecton

### High-performance Minecraft Bedrock server engine, written in Zig.

**Zero GC. Manual memory control. Deterministic 20 TPS.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org/)
[![MCBE](https://img.shields.io/badge/Minecraft-Bedrock%201.26.50-62B47A?style=for-the-badge&logo=minecraft&logoColor=white)](https://www.minecraft.net/)
[![Platforms](https://img.shields.io/badge/Platforms-Linux%20%7C%20Windows%20%7C%20macOS-4C566A?style=for-the-badge)](#-quick-start)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](./LICENSE)

[![GitHub stars](https://img.shields.io/github/stars/nexxii04/Tecton?style=flat-square&logo=github)](https://github.com/nexxii04/Tecton/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/nexxii04/Tecton?style=flat-square)](https://github.com/nexxii04/Tecton/issues)
[![Last commit](https://img.shields.io/github/last-commit/nexxii04/Tecton?style=flat-square)](https://github.com/nexxii04/Tecton/commits)

<br />

<!-- 📸 Replace with a real screenshot or demo GIF of Tecton running -->
<img src="./public/screenshot.png" alt="Tecton server console" width="800" />

<br />

[Why Tecton?](#-why-tecton) · [Features](#-core-features) · [Quick Start](#-quick-start) · [Plugins](#-native-plugin-engine-c-abi) · [Credits](#-credits--acknowledgments)

</div>

---

## 🎯 Why Tecton?

A game server lives and dies by its **tick loop**. At 20 TPS you have exactly **50 ms** per tick, and a single unexpected pause means rubber-banding, desync, and angry players.

Tecton is built in **Zig** because the problems of Bedrock server software are problems of *predictability*, not just raw speed.

- 🧠 **No GC pauses.** Memory is allocated and freed when *you* decide, so the 50 ms tick budget isn't stolen by a collector.
- 📉 **Tiny footprint.** No VM, no runtime, no warm-up. A single static binary.
- 🔍 **Explicit allocators.** Every allocation is visible, arena-scoped per tick or per session, and leak-checkable in tests.
- 🛡️ **Compile-time safety.** Comptime, error unions, optionals, and safety-checked builds catch whole bug classes before they ship.
- 🔌 **Zero-cost C interop.** The plugin boundary is a plain C ABI, with no marshalling layer and no bridge runtime.

---

## ✨ Core Features

- 🌐 **NetherNet (WebRTC) transport.** Bedrock clients join through the same signaling, ICE and SCTP path the vanilla game uses, with packet compression and batching built in.
- 💾 **LevelDB world storage.** Bedrock-compatible world persistence, with chunks managed, saved, and loaded by the engine.
- 🧱 **Complete block system.** Placement, breaking, drops, and interaction.
- 🎒 **Items & containers.** Item system with traits, containers (including double chests), inventory, and crafting.
- 🔌 **C ABI plugin system.** Versioned C ABI for `.so`, `.dll`, and `.dylib` plugins written in C, Zig, Rust, or anything that exports C symbols, with no scripting VM in between.
- 📡 **Plugin event system.** Subscribe to server events, read stable event views, and cancel dispatch during cancellable phases.
- 🌍 **Multi-world support.** Run and manage multiple worlds from a single server instance, each with its own generator.
- ⚔️ **Gameplay systems.** Combat and damage, fully functional.
- 🧟 **Entity system.** Entity trait system; spawn any entity type, with vanilla behaviors implementable through plugins.
- ⌨️ **Interactive console & commands.** An executable console that resolves registered commands, extensible by plugins.
- ⏱️ **Fixed 20 TPS loop.** A GC-free, deterministic tick loop designed around a stable 50 ms budget.
- 📦 **Single binary.** Cross-compile and ship, with no runtime to install.

---

## 🗺️ Roadmap

> Status reflects the current state of the `main` branch. Contributions are welcome.

**Networking & Session**
- [x] NetherNet (WebRTC) transport and signaling
- [x] Connections, login, and player spawning
- [x] Multiplayer
- [x] Chat and text handling
- [x] Packet compression & batching
- [ ] Encryption hardening and audit

**World**
- [x] LevelDB world integration
- [x] Chunk management (loading, streaming, saving)
- [x] Multi-world system
- [x] Block placement, breaking, and drops
- [x] World generators (Flat)
- [ ] Additional generators (vanilla-like terrain)
- [ ] Resource pack loading

**Gameplay**
- [x] Item system, containers, and item traits
- [x] Inventory
- [x] Crafting
- [x] Combat & damage system
- [x] Entity trait system
- [x] Entity spawning (all entity types)
- [x] Command system (registry-based, console + in-game)
- [ ] Vanilla entity behaviors (AI), implementable via plugins
- [ ] Entity drops

**Extensibility**
- [x] C ABI plugin loader (`.so` / `.dll` / `.dylib`)
- [x] Plugin event subscription system
- [x] Executable console
- [ ] Plugin hot-reload
- [ ] Official plugin SDK & templates (C / Zig / Rust)

---

## 🚀 Quick Start

### Prerequisites

| Requirement | Version |
|---|---|
| [Zig](https://ziglang.org/download/) | **0.16.0** |
| C++ toolchain | **C++17** compatible compiler (LevelDB is built from source) |
| Git | any recent version |

### Clone, build and run

```bash
# 1. Clone the repository
git clone https://github.com/nexxii04/Tecton.git
cd Tecton

# 2. Build and run the server
zig build run
```

For an optimized production binary:

```bash
zig build -Doptimize=ReleaseFast
```

> 💡 **Tip:** Connect from Minecraft Bedrock Edition by adding the server's IP and the default Bedrock port (`19132`) in the *Servers* tab.

---

## 🌐 Networking

Tecton joins clients over **NetherNet**, the WebRTC-based transport Bedrock uses. The signaling
listener is TCP; the rest of the path is UDP, so both must be reachable.

| Port | Protocol | Purpose |
|---|---|---|
| `19132` | TCP | Partner signaling: `GET /v1/join`, `POST /v1/join/{networkId}` |
| `19132` | UDP | Server-list ping / MOTD |
| `7551` | UDP | LAN discovery (`lan-discovery=false` turns it off) |
| `443` (`tls-port`) | TCP | HTTPS signaling with `tls-mode=native` |

`port` is the plain signaling port. `address` is the default host for the signaling and MOTD
listeners, and `signaling-bind` overrides only the signaling host: that is how the plain listener
stays on loopback while the MOTD remains reachable.

### Signaling TLS

HTTPS signaling removes the trust prompt the client shows for plain HTTP. `tls-mode` picks how the
HTTPS endpoint is provided:

| `tls-mode` | Behavior |
|---|---|
| `off` (default) | Signaling stays plain HTTP; every player sees the trust prompt once. |
| `proxy` | A reverse proxy in front terminates TLS; Tecton only serves plain HTTP on loopback. |
| `native` | Tecton terminates TLS itself and forwards plain HTTP to the signaling listener. |

With `proxy` or `native`, `signaling-bind` must be a loopback address (`127.0.0.1`, `::1`, or any
`127.0.0.0/8`). The server refuses to start otherwise, so the plain port can never be reached from
the network. `tls-mode` does not replace `a=identity`: the operator key keeps signing every answer.

#### Mode A — reverse proxy (any platform)

Point `signaling-bind` at loopback and give the proxy enough room for an SDP offer. nginx:

```nginx
server {
    listen 443 ssl;
    server_name bedrock.example.com;

    ssl_certificate     /etc/letsencrypt/live/bedrock.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bedrock.example.com/privkey.pem;

    client_max_body_size 512k;      # SDP offers are capped at 256 KiB
    proxy_request_buffering off;    # the offer is written while the client is still sending
    proxy_read_timeout 60s;         # ICE gathering can take several seconds
    proxy_send_timeout 60s;

    location / {
        proxy_pass http://127.0.0.1:19132;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
    }
}
```

Caddy has no request-body limit by default and keeps connections open long enough for ICE; the
minimal block is:

```caddyfile
bedrock.example.com {
    reverse_proxy 127.0.0.1:19132
}
```

If you add `request_body { max_size ... }`, keep the limit at 512 KB or more.

#### Mode B — native TLS (POSIX)

```properties
address=0.0.0.0
signaling-bind=127.0.0.1
tls-mode=native
tls-cert=/etc/tecton/fullchain.pem
tls-key=/etc/tecton/privkey.pem
tls-port=443
```

The front accepts TLS on `address:tls-port`, speaks only HTTP/1.1 (ALPN), and forwards the plain
text to `signaling-bind:port`. It uses TLS 1.2, which is the protocol set enabled by the mbedTLS
build in the dependency tree; the certificate replaces the client's trust prompt.

Clients reach HTTPS at `address:tls-port` (443 by default), while the server-list ping and MOTD
stay on `port` over UDP. The ping does not advertise `tls-port`: a value other than 443 is not
discoverable and its behavior with retail clients is unverified, so keep 443 until that is tested.

- The front is built on POSIX sockets and verified on Linux. On Windows it refuses to start:
  Zig 0.16's Windows sockets cannot be polled for a byte relay. Use Mode A there.
- A handshake has one 15 s deadline measured from the accept, idle keep-alives close after 60 s,
  each write to a peer that stopped reading is abandoned after 30 s and the TLS close notification
  gets 1 s more, so a stalled client never pins a relay thread.
- The loopback connect to the plain listener is not timed: Zig 0.16 panics when `netConnectIp`
  receives a timeout, and the listener is local and started with the server.
- The front serves at most `min(max-sessions, 256)` TLS connections at once; connections over that
  limit are closed as soon as they are accepted.
- `tls-cert` is a PEM chain, `tls-key` its PEM private key. Make the key `0600` and never commit
  it. Startup fails with a clear error when either is unreadable, unparsable or does not match.
  `tests/tls/` holds a throwaway self-signed pair that only the test suite uses.

#### Certificate renewal

- Renew with your ACME client (Certbot, Caddy, acme.sh) and keep the private key at `0600`, out of
  the repository.
- The front reads `tls-cert` and `tls-key` once at startup: there is no hot reload. Restart Tecton
  after renewing (in Mode A, reload the proxy instead).
- Verify the renewal with
  `openssl s_client -connect host:tls-port -servername host -alpn http/1.1` (check the new dates)
  and run the smoke test below; it must still answer 200.

Smoke test either mode from another machine (pass the CA file when the certificate is not publicly
trusted):

```bash
tests/tls/signaling-smoke.sh https://bedrock.example.com
tests/tls/signaling-smoke.sh https://203.0.113.7:8443 /path/to/ca.pem
```

### Identity and trust

`identity-key` (default `server.key`) is the operator's P-384 key. It signs every signaling answer,
and its fingerprint is what clients pin: back it up, keep it private, and rotate it deliberately —
rotating it makes every client prompt again.

- Plain HTTP signaling is trust-on-first-use: the player sees a prompt once, then the client pins the key.
- HTTPS signaling needs no prompt when the token chains to a key the client already trusts.
- Answers always carry `a=identity`.
- `online-mode=true` verifies player tokens against `jwks-uri`; `require-client-identity` (implied by
  online mode) also refuses tokens that do not chain to the operator or a JWKS key.

### NAT and ICE

- `public-candidate=203.0.113.7:19132` (or `[2001:db8::1]:19132`) advertises the public address of a
  server behind NAT. Empty uses the address the client reached.
- `ice-servers` is empty by default. Add `stun:host:port` or `turn:host:port@user:pass` entries only
  when the server host can reach them; a relay helps clients whose NAT blocks direct UDP.
- Signaling alone is not enough: WebRTC needs the server's UDP reachable. There is no “P2P without
  opening ports”.

### LAN discovery

A client running on the same machine may already hold UDP `7551`. Start Tecton first, or set
`lan-discovery=false` when the port is taken.

### Tuning and memory

- `movement-channel=reliable` (default) keeps movement ordered with every other frame.
  `unreliable` sends movement without retransmits; a batch cannot be fragmented, so it must fit the
  negotiated message size on its own. Login and chunks always travel reliable. If loss produces
  rubber-banding, switch back: the flag needs no code change.
- The transport runs one tick thread (`tick_shards = 1`) because the inbound ring has a single
  producer. More shards would need an MPSC publish path first.
- Each NetherNet session reserves the outbox descriptor array at open (512 slots, 24 B each, about
  12 KiB) and allocates its byte slab on the first send, sized to `max(max-message-size, 64 KiB)`.
  At the default cap that is 256 KiB per busy session: 152 sessions per listener are bounded at
  about 39.8 MiB, and HTTP plus LAN (152 each) at about 79.6 MiB, within an 80 MiB budget. Lower
  `max-message-size` to shrink the worst case.
- `/worlds <world>` reports `net_io`/`net_dispatch` and the transport counters: active and total
  sessions, reconnects, inbound drops, and outbound backpressure/drops.

### Migrating an existing `server.properties`

`max-mtu`, `output-slab-slots`, `transient-slab-slots`, `outbound-queue-slots` and `transport` no
longer exist. An older `server.properties` still loads: each removed key logs `Unknown or invalid property`
and the server starts with the remaining values.

`tls-cert`, `tls-key` and `tls-port` are optional; without them signaling stays plain. `proxy` and
`native` require a loopback `signaling-bind`, or startup fails.

- `max-mtu` has no replacement: NetherNet negotiates the MTU inside SCTP.
- `outbound-queue-slots`/`outbox-bytes` are gone too; each session's outbox is bounded by
  `max(max-message-size, 64 KiB)` bytes and 512 messages. `max-sessions` is per listener, so budget
  `2 × max-sessions × (max(max-message-size, 64 KiB) + 12 KiB)` when HTTP and LAN run.
- `gamemode=spectator` is accepted and advertised as adventure, because NetherNet exposes three game
  modes.

---

## 🧩 Embedding Tecton

Tecton is also a library. A host process builds a `ServerOptions` struct and passes it to the single
`Server.init` constructor: nothing is passed as a loose parameter, and `composition` is a mandatory
field. `defaultOptions` builds the default options with the vanilla composition already wired:

```zig
const std = @import("std");
const tecton = @import("tecton");

pub fn main(init: std.process.Init) !void {
    var server = try tecton.Server.init(tecton.defaultOptions(init.io, std.heap.smp_allocator));
    defer server.deinit();

    try server.prepare();
    try server.start();
    defer server.shutdown() catch {};
    try server.run();
}
```

To run with your own composition (or any other option), replace the field before constructing:

```zig
var opts = tecton.defaultOptions(init.io, allocator);
opts.composition = .{ .prepare = myPrepare, .dispatch = myDispatch };
var server = try tecton.Server.init(opts);
```

Only `io`, `allocator`, and `composition` are mandatory; every other field has a default.
`properties: ?ServerProperties = null` loads `server.properties` (created with defaults when
missing), or you can pass your own loaded `ServerProperties`.

---

## 🔌 Native Plugin Engine (C ABI)

Tecton exposes a **versioned C ABI** through `include/tecton_plugin.h`. Any language that can produce a shared library with C-compatible exports can build a plugin.

**Supported formats**

| Platform | Extension |
|---|---|
| Linux | `.so` |
| Windows | `.dll` |
| macOS | `.dylib` |

**How it works**

1. At startup, the server discovers plugins in the flat `plugins/` directory.
2. Each plugin exports `tecton_plugin_get_descriptor`, providing metadata and lifecycle callbacks.
3. The loader validates the ABI, descriptor size, API version, protocol version, and callback presence before invoking anything.
4. Plugins receive a bounded **host service table** for logging, memory, world lookup, and block updates.
5. Plugins can subscribe to and unsubscribe from server events, read the marshaled tick payload, and cancel dispatch during cancellable phases.
6. Libraries are unloaded cleanly on server shutdown.

There is no interpreter, no VM, and no serialization layer between the server and your code.

> ⚠️ Build plugins for the same target ABI as the Tecton process (e.g. `zig build plugin-example` on Linux). The plugin API is still evolving, so pin to a specific Tecton commit/release if you distribute plugins.

---

## 🧪 Testing & Verification

```bash
zig build test            # Full test suite + native C plugin lifecycle test
zig build test-chest      # Chest regression tests only (double-chest trait serialization)
zig build plugin-example  # Build the example native plugin
```

Tests live next to the source as standard Zig `test` blocks. Zig's safety-checked build modes (Debug / ReleaseSafe) help surface undefined behavior, out-of-bounds access, and integer overflow, and tests using `std.testing.allocator` also detect memory leaks.

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome.

1. Fork the repository
2. Create your branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m "feat: add my feature"`
4. Make sure the tests pass: `zig build test`
5. Push and open a Pull Request

---

## 📜 License

Distributed under the **MIT License**. See [`LICENSE`](./LICENSE) for details.

---

## 🙌 Credits & Acknowledgments

Tecton is built upon the solid foundation laid by the original **Conduit** project.

* 🏛️ **Original Author & Architecture:** Conduit by [@AnyBananaGAME](https://github.com/AnyBananaGAME).
* 🛠️ **Active Maintenance & Evolution:** Developed and maintained by [@nexxii04](https://github.com/nexxii04).

Huge thanks to [@AnyBananaGAME](https://github.com/AnyBananaGAME) for designing and creating the original codebase this engine is built on. 💚

---

<div align="center">

**Tecton Core Engine** · Built for extreme performance with ⚡ Zig · Licensed under MIT

</div>
