Development Strategy and Milestones

Assumptions
- Codebase language: transition en cours vers Swift 6.2 (async/await) avec SwiftNIO, swift-argument-parser et swift-log. L’implémentation C historique (`sources/…`) reste disponible à titre de référence pendant la migration.
- Targets: binaire unique `box` (client ou serveur via `--server/-s`) géré par SwiftPM (`BoxCommandParser` orchestre `BoxServer` et `BoxClient`).
- Platform: Linux/macOS first; Windows later. IPv6 preferred; IPv4 supported.
- Spec reference: current `SPECS.md` (protocol v1 framing, Noise/XChaCha AEAD, embedded self‑hosted LS, queues, ACLs, NAT section).

Guiding Approach
- Prioritize a working vertical slice early: local IPv6 on LAN, minimal HELLO/PUT/GET.
- Use libsodium‑based Noise/XChaCha transport for encryption (Issue #16). No DTLS fallback.
- Small, verifiable steps with tests and demo commands per milestone.
- Réécrire progressivement les composants C en Swift tout en gardant des jalons incrémentaux et la parité fonctionnelle.

Swift Migration Track

S0 — Swift Toolchain Bootstrap
- Supprimer le projet Xcode historique, ajouter `Package.swift`, structurer `swift/Sources`/`swift/Tests`.
- Dépendances: swift-argument-parser, swift-log, swift-nio.
- Exit: `swift build --product box` produit le binaire; tests Swift (`swift test`) exécutés sur Linux/macOS CI.

S1 — Command Parser + Stubs
- Implémenter `BoxCommandParser` (swift-argument-parser, async/await) avec le mode serveur (`--server/-s`) et client par défaut.
- Créer `BoxServer`/`BoxClient` stubs, initialiser la journalisation via swift-log.
- Exit: `swift run box` (client) et `swift run box --server` (serveur) se lancent et consomment les options de base.

S2 — Networking Parity (Cleartext)
- Porter les flux UDP HELLO/STATUS/PUT/GET de l’implémentation C vers SwiftNIO.
- Implémenter un stockage mémoire temporaire (équivalent C) et conserver le protocole en clair jusqu’à stabilisation.
- Exit: échanges HELLO/PUT/GET fonctionnels en Swift avec tests d’intégration.
  Progress: `BoxCodec` fournit le framing réutilisable; `BoxServer` et `BoxClient` gèrent HELLO → STATUS → PUT/GET en SwiftNIO avec stockage mémoire.

S3 — Configuration & Admin Channel
- Lire les fichiers PLIST (`~/.box/box.plist` / `~/.box/boxd.plist`) avec `PropertyListDecoder`, conserver la priorité CLI/env.
- Recréer le socket d’administration Unix, refuser l’exécution en root et gérer les répertoires `~/.box`.
- Exit: `box --server` expose `status` sur le canal admin; non-root enforcement vérifié.
  Progress: chargement PLIST serveur avec priorité CLI/env, enforcement non-root, création des répertoires `~/.box`/`run`, socket admin `status` opérationnel, commandes `box admin status|ping|log-target|reload-config|stats` effectives (reload relit le PLIST et met à jour log level/target; stats expose un instantané runtime), bascule de la journalisation sur Puppy (stderr|stdout|file) et lecture `~/.box/box.plist` côté client (log level/target + address/port). Transport admin abstrait (Unix socket ou named pipe Windows) avec CLI/serveur alignés.

S4 — Crypto Reintegration
- Intégrer libsodium via un module Swift (bindings) et rétablir le transport Noise NK/IK.
- Couvrir XChaCha20-Poly1305, BLAKE2 et la fenêtre anti-rejeu dans les tests Swift.
- Exit: chemin chiffré par défaut avec parité fonctionnelle sur HELLO/STATUS/PUT/GET.

Legacy C Milestones (référence pendant la migration)

Milestones

> Remarque : les jalons M0–M11 décrivent l’implémentation C existante et servent de référence tant que la migration Swift n’a pas repris chaque fonctionnalité.

M0 — Build, Tests, Hygiene (Baseline)
- Ensure clean builds on Linux/macOS via `Makefile`/`CMakeLists.txt` (both if used).
- Make tests pass (`test/*`), add CI scripts (format, lint, unit tests).
- Add sanitizers presets (ASan/UBSan) and `scripts/fast_build.sh` integration.
- Exit criteria: one‑command build; unit tests green; formatting checks in place.

M1 — Protocol Framing v1 and CLI Skeleton (DTLS removed)
- Update BFBoxProtocol to support v1 framing from SPECS (magic 'B', version, length, command, request_id) behind a feature flag while preserving current simple header for interim use in tests.
- Add request/response enums for HELLO/PUT/GET/DELETE/STATUS/SEARCH/BYE.
- Remove DTLS code paths and references from build, code, CLI help, and docs.
- Scaffold CLI subcommands in `box` for `sendTo`, `getFrom`, `list`, `deleteFrom`, and `check connectivity` (stub behaviors exercising framing only) over UDP (unencrypted, temporary).
- Exit criteria: round‑trip HELLO over UDP using the new frame; unit tests for pack/unpack and request_id correlation; no DTLS symbols or build flags remain.
  Progress: UDP v1 framing and tests exist; DTLS removed; CLI skeleton in place.

M2 — Config, Identity, and Non‑Root Enforcement
- Refuse to run `boxd` as root/admin. Create `~/.box` (or `%USERPROFILE%\.box`) on first run with correct permissions.
- Parse TOML config files: `~/.box/box.toml`, `~/.box/boxd.toml` (simple embedded TOML parser).
- User/Node UUID handling and key material locations; stubs for key generation.
- Local Admin Channel scaffolding: Unix socket / Windows named pipe with same‑user enforcement.
- Exit criteria: `boxd` loads config, runs as non‑root, exposes admin channel `status` action.

M3 — Crypto Subsystem (Noise + XChaCha20‑Poly1305)
- Introduce `libsodium` and a new transport path (e.g., BFNetworkTransportNoise) implementing Noise NK/IK over UDP with X25519/Ed25519 and XChaCha20‑Poly1305 AEAD.
- Replay protection (nonces + timestamp) and session key lifecycle.
- Exit criteria: `box`/`boxd` complete HELLO + encrypted echo using the Noise path; unit tests for AEAD and transcript signing.
  Progress:
  - AEAD helpers implemented and tested; NOISE adapter added with framed packets (NZ v1 + nonce + AEAD) using a temporary preShareKey.
  - CLI smoke path implemented (`--transport noise`) with encrypted ping/pong.
  - Basic replay protection present (salt consistency + 64‑entry sliding window); unit tests cover bad header, wrong key, and replay via test hook.
  Next:
  - Add handshake scaffold (Noise NK/IK) to derive session keys (replace PSK) and sign transcripts.
  - Extend tests for out‑of‑order acceptance within the window and replay rejection; add transcript validation stubs per SPECS.

M4 — Storage and Queues (Filesystem + Index)
- Implement storage root layout `<root>/<user_uuid>/<queue>/<digest>` with metadata sidecar.
- Add portable B‑tree index (backend pluggable; start with a simple portable implementation; integrate BSD libdb/LMDB later).
- Implement PUT/GET/DELETE minimal flows in `boxd`; compute SHA‑256 digests; basic content‑type metadata.
- CLI: `sendTo`, `getFrom`, `deleteFrom` wired end‑to‑end on localhost.
- Exit criteria: e2e file/message transfer on LAN IPv6; objects retrievable by latest/digest; unit tests for queue operations.

M5 — Embedded Location Service (LS) and Presence
- Implement LS API in `boxd`: register/update node record; answer resolve queries.
- Publish presence into `/uuid` and optional geo into `/location` per SPECS; consume these queues to persist LS state.
- CLI: resolution step using bootstrap bundle; display node key fingerprint; verify during HELLO.
- Exit criteria: client discovers server via LS; presence updates visible; admission control only for registered clients.

M6 — Authorization and ACLs
- Implement ACL engine with global and per‑queue rules as per SPECS.
- Load from `boxd.toml` (example defaults included in spec) and enforce on PUT/GET/DELETE/LIST.
- Unit tests for allow/deny intersection and precedence; include evaluation examples as fixtures.
- Exit criteria: requests from unauthorized peers are rejected with proper status; ACL changes take effect without restart.

M7 — NAT Traversal and Connectivity Tools
- Implement admin‑channel actions for NAT probe, map_create/map_delete, probe_peer, and LS publish.
- Implement PCP → NAT‑PMP → UPnP mapping (opt‑in) and keepalives (configurable).
- Implement `box check connectivity` behavior and JSON output; document remediation guidance.
- Optional: hole punching with rendezvous; optional user‑owned relay path (still E2E encrypted).
- Exit criteria: connectivity tool reports IPv6 reachability; acquires IPv4 mapping where supported; publishes endpoints to LS on confirmation.

M8 — Robustness, Retries, and Chunking
- Implement chunking for large payloads, backoff/retry, and idempotency keyed by request_id and object digest.
- Add rate limiting and DoS guards per source; bounded queues and memory.
- Exit criteria: reliable transfer of multi‑MiB files over lossy links; resilience under moderate packet loss.

M9 — Packaging and Service Integration
- Systemd unit hardening (already present skeleton at `systemd/boxd.service`): restrict capabilities, set `User=` to non‑privileged account, sandboxing.
- macOS launchd and Windows service scaffolding.
- Install scripts that create `~/.box` and set permissions.
- Exit criteria: packaged binaries start on boot under non‑root with correct data dirs.

M10 — Observability and Hardening
- Structured logging with levels; optional file logging with rotation.
- Metrics (basic counters; optional Prometheus text endpoint on localhost only).
- Fuzz BFBoxProtocol pack/unpack and parsing paths; enable ASan/UBSan CI jobs.
- Threat model pass; crypto parameters review; key handling audit.
- Exit criteria: fuzzers run clean for N cpu‑hours; sanitizer builds green; logging usable for diagnostics.

M11 — v0.1 Cut and Docs
- Pin protocol version; tag release; publish minimal docs: quickstart, bootstrap guide, connectivity guide, ACL examples.
- Record known limitations (no STUN/ICE; relay optional; limited backends).
- Exit criteria: reproducible build artifacts; end‑to‑end demos validated; SPECS.md tagged to release.

Cross‑Cutting Tasks
- Test Matrix: Linux (x86_64, arm64), macOS (arm64), later Windows.
- Code Style and Checks: keep using `scripts/check_format.sh`, `scripts/check_naming.sh`; add pre‑commit hooks.
- Security Posture: default deny ACLs; explicit user opt‑in for any port mapping; never run as root.

Risks and Mitigations
- Crypto path: ensure robust libsodium integration and test coverage for AEAD and key handling.
- NAT variability: clearly message fallbacks; provide actionable remediation; maintain IPv6‑first guidance.
- Storage backend portability: start with a simple portable B‑tree; gate optional backends (BSD libdb/LMDB) behind build flags.

Demo Checkpoints (per Milestone)
- M1: HELLO over UDP using v1 frame; unit test for framing.
- M3: HELLO + encrypted echo over Noise; request_id correlation.
- M4: PUT/GET small text and a photo file on localhost.
- M5: Client resolves server via LS; presence visible in `/uuid`.
- M6: Unauthorized PUT denied; authorized PUT succeeds per ACL.
- M7: `box check connectivity` shows IPv6 reachable; acquires IPv4 mapping on a supported gateway.

Next Steps
- Align with architecture details in `SPECS.md` and `DEVELOPMENT_STRATEGY.md` for the Noise transport module boundaries (e.g., where BFNetworkNoise lives), storage interfaces, and ACL engine API before progressing M2–M3.
