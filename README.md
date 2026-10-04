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

- 🌐 **Native RakNet networking.** A from-scratch RakNet implementation for low-latency, reliable UDP transport, with packet compression and batching built in.
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
