# Changelog

All notable changes to Tecton are recorded here. The format follows Keep a Changelog and the project
uses semantic versioning.

## [0.4.0] - 2026-10-28

### Changed

- The server transport is NetherNet (WebRTC/SCTP); the game tick and the connection lifecycle are
  owned by Tecton instead of the transport.
- Signaling can be served over TLS, either behind a reverse proxy or with the native POSIX front;
  `a=identity` still signs every answer.
- Configuration, metrics and `/worlds` use NetherNet vocabulary.

### Added

- `server.key` identity, ICE/STUN/TURN settings, `signaling-bind`, `max-sessions`,
  `max-message-size`, `public-candidate`, `tls-mode`, `tls-cert`, `tls-key` and `motd-port`.

### Removed

- The RakNet (ZigNet) dependency and its adapter, along with the manual MTU and slab/outbox tuning
  keys. Older `server.properties` files still load and ignore those keys with a warning.
