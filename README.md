# Conduit

<div align="center">

![Conduit](public/screenshot.png)

**A high-performance Minecraft Bedrock Edition server written in [Zig](https://ziglang.org).**

![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=f7a41d)
![Minecraft](https://img.shields.io/badge/Bedrock-1.26.45-44b389?logo=minecraft&logoColor=white)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20windows-66788a)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

## Why Zig?

For a Bedrock server, performance is everything: dozens of players, thousands of chunks, and a 20-ticks-per-second loop all competing for the same CPU. Zig gives Conduit manual memory control, no hidden runtime, and compiler-checked safety in debug builds — all with C-level speed. The result is a server that stays fast under load without giving up correctness.

## Roadmap

- [x] Connections, login, and player spawning
- [x] Chat and text handling
- [x] Chunk & world system with terrain generators
- [x] Multiplayer
- [x] Item system, containers, and item traits
- [x] Block placement, breaking, and drops
- [x] Entity trait system
- [x] LevelDB world storage
- [x] Command system & terminal console
- [ ] Inventory system *(in progress)*
- [ ] Entity system & entity drops *(in progress)*
- [ ] Multi-world system
- [ ] Plugin API
- [ ] Resource pack loading

## Getting started

### Requirements

- [Zig](https://ziglang.org/download/) **0.16.0**
- A C++17 compiler (LevelDB is built from source)

### Build & run

```bash
git clone https://github.com/VantStudios/Conduit.git
cd Conduit
zig build run
```

Connect from Minecraft Bedrock on port **19132** (default).

## Testing

```bash
zig build test        # Run the full test suite
zig build test-chest  # Chest regression tests only (double-chest trait serialization)
```

Tests are colocated with the source as standard Zig `test` blocks.

---

## Credits

Conduit is based on the original Conduit project by [@AnyBananaGAME](https://github.com/AnyBananaGAME).
