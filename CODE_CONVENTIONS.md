Code Conventions and Shared Guidelines

Purpose
- Provide a concise, shared reference for technical architecture choices, dependencies, naming/style conventions, and operational constraints used across `box` and `boxd`.
- When in doubt, the specification in `SPECS.md` is the source of truth for protocol and behavior.

Architecture Conventions
- Components: un exécutable unique `box` qui agit en mode client par défaut et en mode serveur via `--server`/`-s`. Le service LS reste embarqué côté serveur.
- Transport: UDP over IPv6 preferred; IPv4 supported. A single configurable UDP port per node.
- Protocol: Binary framing with magic 'B', version, length, command, `request_id` (UUID), `node_id` (UUID) et `user_id` (UUID). Commands: HELLO, PUT, GET, DELETE, STATUS, SEARCH, BYE.
- Queues: Logical destinations under a user’s server (e.g., `/message`, `/photos`, `/uuid`, `/location`).
- ACLs: Default‑deny, intersection of global and queue‑level rules. Principals: owner, user UUID, node UUID, any. Capabilities: put/get/list/delete.
- Location Service data: uses `/uuid` for presence and `/location` pour la géo; les enregistrements doivent inclure `addresses[]` (IP/port/scope/source) et un bloc `connectivity` (has_global_ipv6, global_ipv6[], port_mapping.*). LS persiste et consomme via les queues (pas de base externe).

Security and Identity
- Identities: User UUID and Node UUID. Each node has a long‑term identity keypair (Ed25519).
- Crypto suite: Noise NK/IK over UDP using X25519 (ECDH), Ed25519 (signatures), and XChaCha20‑Poly1305 (AEAD). Replay protection via nonces + timestamps.
- Authorization: Servers accept requests only from peers registered in LS per user. Enforce ACLs on all commands.
- Privileges: `boxd` must not run as root (Unix) or Administrator (Windows). Refuse to start if elevated.
- Admin channel: local‑only (Unix socket `~/.box/run/boxd.sock` or Windows named pipe), same‑user access enforced by OS permissions.

Networking and NAT
- Prefer IPv6 with a firewall allow rule for the chosen UDP port. For IPv4, use manual port forwarding or opt‑in automatic mapping.
- Port mapping methods (opt‑in, gateway‑scoped only): PCP → NAT‑PMP → UPnP. Keepalive every ~25s to maintain mappings.
- Hole punching and user‑owned relays are optional fallbacks; end‑to‑end encryption applies regardless of path.

Storage and Data
- Storage root: `~/.box/queues/<queue>/timestamp-UUID.json` contenant le message sérialisé (payload base64, `node_id`, `user_id`, métadonnées facultatives). La file `INBOX` est créée automatiquement au premier démarrage.
- Index: portable binary B‑tree by default; pluggable backends allowed (BSD libdb, LMDB) behind build flags.
- Data at rest: optional encryption with a server‑managed key (future enhancement).

Configuration and Paths
- Format: PLIST (Property List) unique (`~/.box/Box.plist`) structuré en trois sections : `common` (UUID de nœud et d’utilisateur), `server` (port/log/transport/admin_channel) et `client` (adresse/port/log). Le parseur TOML historique est gelé et sera réintroduit si nécessaire pour compatibilité ascendante.
- Unix/macOS
  - Config: `~/.box/Box.plist` (section `common` + `server`/`client`), surcharge avec `--config`. Les anciens fichiers TOML restent pris en charge uniquement par l’implémentation C historique.
  - Data: `~/.box/data`
  - Keys: `~/.box/keys/identity.ed25519`, `~/.box/keys/client.ed25519` (optional)
  - Admin socket: `~/.box/run/boxd.sock`
- Windows
  - Config: `%USERPROFILE%\.box\Box.plist`
  - Data: `%USERPROFILE%\.box\data`
  - Keys: `%USERPROFILE%\.box\keys\identity.ed25519`
  - Admin pipe: `\\.\pipe\boxd`
- Permissions: directories `700`, key files `600`.

Dependencies
- Crypto: `libsodium` for Ed25519/X25519 and XChaCha20‑Poly1305 (Noise transport).
- Storage: portable B‑tree (in‑tree) with optional BSD libdb or LMDB backends.
- Build:
  - Swift rewrite: SwiftPM (Swift ≥ 6.2; la CI télécharge la release Swift 6.2 pour Ubuntu 22.04) + packages `swift-argument-parser`, `swift-log`, `swift-nio`.
  - Legacy C: Make/CMake; scripts for formatting and naming exist under `scripts/`.

Swift Coding Style
- Modules: `BoxCore`, `BoxServer`, `BoxClient`, `BoxCommandParser`, etc. Pas de préfixe `BF`; utiliser des noms explicites en `PascalCase`.
- API publique: types en `PascalCase`, méthodes/fonctions en `camelCase`. Les énumérations utilisent des cases explicites (`case server`, `case client`).
- Documentation: commenter les types, méthodes et propriétés exposés avec `///` pour faciliter la revue et la génération automatique.
- Concurrence: privilégier async/await et les primitives SwiftNIO (`EventLoopGroup`, `ChannelPipeline`). Éviter la création manuelle de threads.
- Logging: utiliser swift-log (`Logger`) et configurer la sortie via `BoxCommandParser`. Pas d’appel direct à `print` pour les logs structurés. La cible par défaut est un fichier dans `~/.box/logs/` (`box.log` côté client, `boxd.log` côté serveur).
- Tests: `XCTest` avec des cibles sous `swift/Tests`. Couvrir la logique de parsing, les services réseau et les intégrations crypto.

C Coding Style
- Standard: C11 (or C99 if required by toolchain). No compiler extensions unless guarded.
- Headers
  - Public headers under `include/box/` expose stable APIs (prefix `BF` for BoxFoundation).
  - Internal headers stay in `src/lib` or have `*Internal.h` suffix; not installed.
- Naming
  - Types and enums: `PascalCase` with `BF` prefix (e.g., `BFNetworkConnection`, `BFMessageType`).
  - Functions: `BF` prefix + `PascalCase` (e.g., `BFNetworkSend`, `BFProtocolPack`).
  - Macros/constants: `BF_SOMETHING` or `BFMaxDatagram` (follow existing style for constants).
  - Modules: files named `BF<Module>.c` / `BF<Module>.h` (e.g., `BFNetwork.c`, `BFRunloop.c`).
  - App‑specific code can use `box_`/`boxd_` prefixes for non‑library helpers.
- Variables and parameters: use fully explicit names; avoid abbreviations. Examples: `buffer` not `buf`, `variable` not `var`, `address` not `addr`, `length` not `len`, `socket` not `sock`.
  - Local variables: use fully qualified, descriptive names (no single-letter or cryptic names). Replace `i/j/k/n/t/x`-style locals with `index`, `count`, `responseSize`, `timestamp`, `coordinateX`, etc. Short or ambiguous names are not allowed.
- Formatting
  - Indentation: 4 spaces (no tabs). Brace on same line. Keep lines under ~100 columns when practical.
  - Use `scripts/format.sh` and `scripts/check_format.sh` where available; do not reformat unrelated code in functional PRs.
- Error handling
  - Return non‑negative on success (byte counts, 0/1) and negative error codes on failure where applicable.
  - Use logging helpers: `BFLog`, `BFWarn`, `BFError`, `BFFatal`. Do not print directly to stdout/stderr outside of CLI UX or fatal diagnostics.
- Memory
  - Ownership clear at API boundaries; provide `*Free` or `Close` functions for allocated/opaque types.
  - Avoid global mutable state; if unavoidable, guard with runloop or atomics.
- Concurrency
  - Prefer `BFRunloop` for eventing; avoid ad‑hoc threads. If threads are required, encapsulate and document synchronization.
- Protocol
  - Follow `SPECS.md` for framing and versioning. Do not break wire compatibility within a major version.

Testing
- Unit tests live under `test/` with file names `test_<Module>.c` mirroring the library components.
- Focus tests on serialization, storage correctness, ACL evaluation, and crypto primitives via mocks.
- For integration tests, prefer loopback/IPv6 first; add network tests behind an opt‑in flag.

Operational Conventions
- Default‑deny ACLs; explicit grants required. Public queues like `/uuid` and `/location` may allow `get/list` for `any`, but `delete` is owner‑only by default.
- NAT features are opt‑in. Mapping is attempted only against the local gateway and never persisted without user consent.
- `box check connectivity` is the standard diagnostic sequence; JSON output used for automation.

Documentation
- Protocol and behavior live in `SPECS.md`.
- Roadmap and phases in `DEVELOPMENT_STRATEGY.md`.
- Service setup guidance: `systemd/boxd.service` and platform notes in README.

Platform Notes
- Linux/macOS supported first; Windows later. Always run `boxd` under a non‑privileged user.
- Prefer IPv6; if using IPv4 under CGNAT, expect to rely on mappings or a user‑owned relay.
- Admin channel (Unix): local socket `~/.box/run/boxd.socket` (0600). A Windows named pipe will be added later.

Change Management
- Conventions evolve with the project; propose changes via PRs that update this file alongside the impacted code.

Lint Suggestions (Abbreviations)
- Goal: Catch common abbreviated identifiers in variables/parameters early.
- Suggested forbidden tokens (case‑sensitive, word‑boundary matches): `buf`, `addr`, `var`, `len`, `sock`, `cfg`, `env`, `tmp`, `ptr`, `idx`, `cnt`, `fn`, `str`, `num`, `sz`, `pkt`, `hdr`, `req`, `resp`, `msg`, `ctx`, `src`, `dst`, `cb`.
- Exceptions (temporary until full refactor): occurrences in third‑party code, tests, or system APIs. Existing code may still use a few (e.g., `ptr`, `idx`, `cfg`); treat findings as warnings initially.
- Script: `scripts/check_abbreviations.sh` scans `include/ src/ test/` and prints matches. By default exits 0 (warn‑only). Set `ENFORCE_ABBREV=1` to fail the build on findings.
- Remediation: rename to explicit forms (e.g., `pointer`, `index`, `configuration`, `environment`, `temporaryValue`, `count`, `string`, `size`).
