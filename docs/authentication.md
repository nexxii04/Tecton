# Authentication

Conduit can run in two modes, and the difference is whether it knows who a
player is:

| `online-mode` | what a login proves |
| --- | --- |
| `false` | nothing. The identity is derived from the display name the client picked |
| `true` | the account the Minecraft authorization service signed for, or a legacy chain anchored at Mojang's root key; anything else is refused |

Both modes replace the identity the login packet claimed. What changed is that
online mode now has something to replace it *with*.

## What was wrong

`server.properties` carried `online-mode=true` and the field was never read by
any code: the server behaved as an offline server while its configuration said
otherwise. Meanwhile the login chain was handed to
`Protocol.Login.Decoder.decodeLoginChain`, which base64-decodes the JWTs and
parses their JSON but **never checks a single signature**.

The practical result was that a client could choose everything about its
identity by writing JSON:

- `leguuid` put any uuid in the chain, and the server used it to load that
  player's saved location and inventory, so copying a uuid out of the player
  list was enough to take over someone else's character.
- `xid` put any xuid in the chain, and bans were checked against it, so a
  banned client evaded the ban by changing one string.
- `xname` put any name in the chain, and permissions are keyed by name, so
  claiming an operator's name granted that operator's commands.

The load bot harness in `tools/loadbot/` uses exactly that to log in without a
Microsoft account, which is how the hole was found.

## How a login is verified now

Everything lives in `src/conduit/network/auth/`. The rules follow the client
format that is actually on the wire (the modern one is the OIDC multiplayer
token; the legacy chain is the older one, which clients may still send).

### Modern: the OIDC multiplayer token (`AuthenticationType` + `Token`)

1. **Discovery.** At startup the server asks
   `https://client.discovery.minecraft-services.net/api/v1.0/discovery/MinecraftPE/builds/<version>`
   for the `auth` environment, which names the service URI and the issuer.
2. **Configuration.** It reads `<issuer>/.well-known/openid-configuration`,
   checks that the document names the same issuer, and requires `RS256` among
   the published signing algorithms — the only algorithm the service publishes
   and the only one this server checks.
3. **Keys.** It fetches `<issuer>/.well-known/keys` (the live JWKS) and keeps
   the RSA keys indexed by `kid`. Keys are refetched when a token arrives with a
   key id the cache does not know (that is what rotation looks like from here),
   at most once per minute, because the key id is chosen by the client.
4. **The token itself.** `alg` must be `RS256`, `kid` must resolve to a
   published key, and the signature (RSASSA-PKCS1-v1_5 over the SHA-256 of
   `header.payload`) must verify. Then the claims are checked:
   - `iss` is exactly the discovered issuer,
   - `aud` contains `api://auth-minecraft-services/multiplayer`,
   - `exp` is in the future, `nbf`/`iat` are not in the future (60 s of clock
     skew allowed).
5. **The identity** comes from the verified claims: `xid` (XUID), `xname`
   (display name), `tid` (PlayFab title id, kept for logs). The uuid is
   *derived* from the xuid with `md5("pocket-auth-1-xuid:" + xuid)` (version 3
   and RFC 4122 variant nibbles set), so it is stable across servers and cannot
   be chosen by the client. `leguuid` is deliberately not read: the service sets
   it for offline logins, and honouring it would let a login it did not
   authenticate choose someone else's saved data.
6. **The client data token** must be signed with the public key in the token's
   `cpk` claim. That is what binds the skin, device and language data to the
   same client that holds the token.
7. The display name is validated against the Xbox Live rules (1-15 characters,
   letters/digits and single spaces, no leading digit, no edge whitespace) and
   the xuid must parse as an integer. Anything else means the token is not one a
   real client could hold.

### Legacy: the login chain (`Certificate` + `chain[]`)

A chain is a list of JWTs where each link is signed by the key the previous link
claimed. The walk is:

- the first link is verified with its own `x5u` key (it is self-signed, which is
  exactly why a chain that only verifies against itself proves nothing),
- the second link must be signed by the key the first link claimed, and that key
  must be **Mojang's root public key**, pinned in
  `src/conduit/network/auth/mojang-root-key.zig`,
- the third link must be signed by the key the second one claimed, must carry
  the `extraData` identity, and both must be issued by `Mojang` and be in their
  validity window,
- the last link's `identityPublicKey` is the client key that the client data
  token has to be signed with.

If the chain does not trace back to the pinned root key, the login is not
authenticated, whatever it claims — the identity is then refused (or falls back
to offline, see below). Since the service authenticates Xbox Live accounts and
the chain is the older mechanism, a chain that is anchored is still required to
carry an xuid, and the xuid must agree with the anchoring.

The pinned root key is the same constant published by gophertunnel
(`mojangPublicKey`) and by PrismarineJS's `bedrock-protocol` (`PUBLIC_KEY`).
It is checked at compile time for its length and encoding, and a test parses it
as a secp384r1 point to prove it really is one.

## What happens when verification fails

- **`online-mode=false`** (default): nothing is verified, the identity is
  derived from the display name with `md5("conduit-offline:" + name)` and the
  claimed xuid is dropped. This is unchanged.
- **`online-mode=true`**: the login is refused with `FailedClient` and a
  `WARN: Rejected login: <error>` line. The rejected name is never logged: it is
  attacker-controlled bytes.
- **`online-mode=true` + `online-mode-offline-fallback=true`**: a login that
  cannot be verified is let in with the offline identity instead, and every such
  join logs `WARN: Unverified login let in as an offline identity: <error>`.
  This is the compatibility switch for a network that blocks the authorization
  service, and it deliberately gives those players no xuid, so xuid-based bans
  and any xuid-based rule do not apply to them.
- **Startup**: with `online-mode=true` the discovery, configuration and key
  fetch happen before the listener exists. If the service cannot be reached the
  server logs the error and refuses to start, rather than coming up and
  accepting logins it cannot check.
- Guests (`AuthenticationType == 1`) never authenticate anything and are only
  let in through the offline fallback.

A login that verified is reported as `Player <name> joined (verified identity).`
An offline one as `...(offline identity, not verified).`, so the log always says
which kind of session it was.

## What is still not checked

- **No encryption handshake.** The client key from `cpk` verifies the client
  data token, but the connection itself is not encrypted, because the packet
  encryption handshake is not implemented yet. Login material therefore travels
  in the clear; verification makes it unforgeable, not unreadable.
- **Permissions are still keyed by name** (`PermissionManager`). In online mode
  the name comes from a verified token, so it is no longer attacker-chosen; but
  a *new* Xbox Live account that takes an operator's display name would inherit
  that operator's group.
- **Player data is keyed by the xuid-derived uuid**, which is what other
  Bedrock servers use, so data is not portable to a server that uses a different
  derivation.
- **The PlayFab identity** (`mid`, `tid`) is logged nowhere yet.

## Migration

With `online-mode=false` the uuid of every identity is
`md5("conduit-offline:" + name)`, so saved data keyed by uuid —
`player_locations.json` and player state in the world database — belongs to
those offline identities. Switching to `online-mode=true` gives every player the
uuid derived from their xuid instead: they start at the spawn with a fresh
inventory once, and the offline entries stay behind unused. Nothing crashes, and
the next join rewrites the entries for the mode in use.

If you need to preserve existing data, the way to do it is a mapping from name
to uuid, checked before the derived uuid is used. That is deliberately not
implemented: it is a migration tool, not a security decision, and it would put a
second source of identity next to the first one.

## How this is tested

Hermetic tests, no network:

- `network/auth/signature.zig`: sec1/SPKI key parsing, points off the curve
  refused, ES384 signatures verified only over the signed bytes, RS256 length
  and modulus-size guards.
- `network/auth/jwt.zig`: the signed bytes are the original ones, unknown or
  missing `alg` refused, malformed tokens and wrong claim types refused.
- `network/auth/jwks.zig`: a real-shaped JWKS document (including the
  hex-encoded `x5t` fields Microsoft publishes) yields exactly the RSA `sig`
  keys, and a document with no usable key is an error.
- `network/auth/oidc.zig`: an RS256 token signed by a fixture key is verified
  against a fixture JWKS and yields the identity of its claims; expired tokens,
  wrong audience, wrong issuer, not-yet-valid tokens, missing xuid, a name that
  violates the Xbox Live rules and a signature from an unpublished key are each
  refused; the algorithm and key id are checked before the signature; client
  data is accepted only when signed by `cpk`.
- `network/auth/identity.zig`: the display name rules, the xuid rules, the uuid
  rules, and the xuid-derived uuid cross-checked against the derivation the
  login decoder uses.
- `network/auth/mojang-root-key.zig`: the pinned key decodes to a secp384r1
  point on the curve.
- `network/auth/legacy-chain.zig`: chains built in the test with generated P-384
  keys — anchored chains yield their identity, a chain that only verifies
  against itself is refused as not anchored, swapped links are refused, expired
  chains and wrong issuers are refused, an anchored chain without an xuid is a
  mismatch, and a single self-signed link is refused as unanchored.
- `network/auth/service.zig`: an unknown `kid` refetches the keys at most once
  per interval, and a guest login neither verifies nor touches the network.
- `network/handlers/login.zig`: a verified identity replaces every claim the
  client made, chain tokens are only read from a certificate chain, and the
  online/offline decision follows the policy rules.
- `network/player-log.zig`: verified and offline joins are distinguishable in
  the log.

End to end (`online-mode=true`, once the service is reachable):

```
INFO: Online mode enabled
WARN: Rejected login: NothingToVerify                     # forged login, no fallback
WARN: Unverified login let in as an offline identity: ... # same login with the fallback on
INFO: Player LoadBot0000 joined (offline identity, not verified).
```
