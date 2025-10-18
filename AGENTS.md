Agents Guide for This Repository

Scope
- This file guides coding agents working on the Box project. Follow these conventions for all changes within this repo.

Authoritative Docs
- Protocol/architecture: SPECS.md
- Development plan: DEVELOPMENT_STRATEGY.md (updated: DTLS removed; Noise/libsodium path)
- Coding standards: CODE_CONVENTIONS.md (naming, non‑root policy, admin channel notes)
- Dependencies and setup: DEPENDENCIES.md (libsodium via pkg‑config; no OpenSSL/DTLS)
- Android notes: ANDROID.md

Build and Test
- Configure: `make configure BUILD_TYPE=Debug`
- Build: `make build`
- Tests: `make test`
- Format check: `make format-check`
- Naming + abbreviation checks (warn-only): `make check`
- Strict abbreviation check: `make check-strict`

Docker Dev Shell
- `make docker-shell` (builds `Dockerfile.dev` if needed, mounts repo, runs as host uid/gid)

CI Summary (GitHub Actions)
- Native build: configure/build, format check, naming+abbrev check, tests
- Dockerized build: container build + strict abbreviation check + tests
- Android: cross-build minimal core and JNI wrapper

Coding Conventions (highlights)
- C11 with Clang toolchain preferred. Keep changes minimal and focused.
- Public APIs live under `include/box/`; library sources under `sources/lib/`.
- Executables: `sources/box/` (client), `sources/boxd/` (daemon). Do not run `boxd` as root/admin.
- Naming: `BF` prefix for library symbols; explicit variable/parameter names (avoid abbreviations like `buffer`, `address`, `pointer`, `index`, etc. are required; abbreviations like `buf`, `addr`, `ptr`, `idx` are forbidden). See CODE_CONVENTIONS.md.
- Security posture: default‑deny ACLs, adhere to Noise + XChaCha crypto roadmap, and follow non‑root policy.
- Admin channel (Unix/Windows): socket `~/.box/run/boxd.socket` ou named pipe `\\.\pipe\boxd-admin`, commandes `status|ping|log-target|reload-config|stats` via `box admin …`.
- Config PLIST defaults: un fichier unique `~/.box/Box.plist` est généré avec les sections `common` (UUID de nœud et d’utilisateur partagés), `server` et `client`. Ne supprimez jamais ce fichier côté agent.
- Logging: par défaut les journaux sont écrits dans `~/.box/logs/` (`box.log` pour le client, `boxd.log` pour le serveur). Utilisez `--log-target` ou `Box.plist` pour modifier la destination.
- Réseau: privilégiez l’IPv6 global. Vérifiez que la machine hôte obtient une adresse IPv6 routable ; sinon, indiquez dans `Box.plist` les adresses publiques ou guides de port forwarding pour l’IPv4. L’option `--enable-port-mapping` (ou `port_mapping = true` dans `Box.plist`) activera prochainement une ouverture PCP/NAT-PMP/UPnP côté routeur (scaffolding présent). Les champs `hasGlobalIPv6`, `globalIPv6Addresses`, `ipv6ProbeError`, `portMappingEnabled` et `portMappingOrigin` doivent rester cohérents entre les réponses `box admin`, la structure Location Service (`addresses[]`, `connectivity`) et la documentation.
- Stockage: les files résident dans `~/.box/queues/`; assurez-vous que `INBOX/` reste présent (les tests/implémentations doivent échouer si la création échoue).

Platform Notes
- Linux/macOS/Windows are primary; Android and AOSP supported via NDK; STM32 targeted later (reason to keep core lean C).
- For Android builds, use `-DBOX_BUILD_MINIMAL=ON` initially; see ANDROID.md.

Where to Put Things
- New protocol code: extend BFBoxProtocol and adjacent modules under `sources/lib/` with tests in `test/`.
- Storage interfaces and ACL engine: new files under `sources/lib/` with headers in `include/box/`.
- CLI subcommands: extend `sources/box/client.c` (temporary) or add small command dispatcher module.
- Server behavior: extend `sources/boxd/server.c` incrementally toward the design in DEVELOPMENT_STRATEGY.md.

Do/Don’t
- Do: write small, testable patches; update docs when behavior changes.
- Don’t: reformat unrelated code; introduce new heavy dependencies without alignment; run `boxd` with elevated privileges.
