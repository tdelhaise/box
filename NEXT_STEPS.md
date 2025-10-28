Next Steps and Status

Status (high level)
- [x] SwiftPM bootstrap: `Package.swift`, modules (`BoxCommandParser`, `BoxServer`, `BoxClient`, `BoxCore`) et tests initiaux.
- [x] CLI Swift: `BoxCommandParser` bascule entre client et serveur (`--server`/`-s`), journalisation configurée.
- [x] Swift UDP parity: porter HELLO/STATUS/PUT/GET en clair avec SwiftNIO et un stockage mémoire temporaire (tests d’intégration à ajouter).
- [x] Swift configuration/admin: lecture PLIST (client), canal d’administration multiplateforme (`status|ping|log-target|reload-config|stats`) et tests d’intégration CLI↔️serveur (`BoxCLIIntegrationTests`) couvrant `box admin status|ping|locate|nat-probe` et `box --locate` avec un garde-fou de 30 s par scénario (les requêtes `nat-probe` retournent `disabled/skipped` tant que le port mapping reste désactivé durant les tests).
- [ ] Swift crypto: réintégrer Noise/XChaCha via libsodium une fois le chemin clair stabilisé.
- [x] Spec v0.1, dépendances et CI historique restent disponibles; l’implémentation C est gelée comme référence.

Immediate TODOs (Swift track)
1) Swift S2 — Parité réseau clair (Issue #25)
   - [x] Implémenter le serveur UDP SwiftNIO pour HELLO/STATUS/PUT/GET.
   - [x] Implémenter le client UDP SwiftNIO équivalent et tests unitaires du codec.
   - [x] Resynchroniser README/DEVELOPMENT_STRATEGY après validation.
   - [x] Ajouter des tests d’intégration end-to-end (Swift) automatisés (`BoxClientServerIntegrationTests`).

2) Swift S3 — Configuration + canal admin (Issue #14)
   - [x] Charger `~/.box/box.plist` (PropertyListDecoder) avec priorité CLI/env.
   - [x] Recréer le socket Unix `~/.box/run/boxd.socket` et la commande `status`.
   - [x] Renforcer la politique non-root + permissions des répertoires.
   - [x] Brancher Puppy comme backend swift-log (`--log-target`, `log_target`).
   - [x] Étendre l’arbre de commandes `box admin` :
     - [x] Enregistrer `status|ping|log-target|reload-config|stats` dans `CommandConfiguration` (payload JSON pour les paramètres).
     - [x] Mettre à jour l’aide CLI et la validation (payload JSON, alias `--configuration` et réponses utilisateur).
     - [x] Ajouter `locate <uuid>` côté CLI/admin (résolution Location Service) avec contrôle d’autorisation nœud/utilisateur.
   - [x] Factoriser le handler admin côté serveur :
     - [x] Créer un répartiteur structuré pour `status`/`ping`/`log-target` (+ analyse JSON optionnelle).
     - [x] Implémenter `reload-config` (relecture PLIST, état runtime) et `stats` (instantané runtime JSON).
     - [x] Harmoniser les erreurs (`unknown-command`, `invalid-log-target`, payload JSON mal formé).
   - [x] Parité Windows :
     - [x] Abstraire le transport admin (Unix socket vs named pipe) dans BoxCore.
     - [x] Exposer `--socket` compatible Windows (chemin `\\.\pipe\boxd-admin` par défaut) et documenter le comportement.
     - [x] Vérifier/renforcer les permissions (ACL) côté Windows.
   - [ ] Tests et observabilité :
     - [x] Ajouter des tests unitaires pour les commandes admin (mock de transport) couvrant `ping`, `log-target`, `reload-config`, `stats`.
   - [x] Stabiliser les tests d’intégration `BoxAdminIntegrationTests` (transport Swift) et les exécuter en CI; l’orchestration CLI de `box admin`/`box --locate` est couverte par `BoxCLIIntegrationTests` (timeout 30 s).
     - [ ] Couvrir la génération automatique des PLIST de configuration côté CLI (vérifier la présence du `node_uuid`).
   - [x] Adapter la Location Service à l’instantané de connectivité (`addresses[]`, `connectivity.has_global_ipv6`, `port_mapping.*`) et livrer un prototype Swift + documentation consommable par les clients mobiles.
   - [x] Ajout de tests end-to-end UDP (`BoxClientServerIntegrationTests`) couvrant PUT/GET et LOCATE (succès + client non autorisé).
   - [x] Implémenter la hiérarchie de stockage `~/.box/queues/` avec la file `INBOX` obligatoire et exposer `queueCount`/`freeSpace` via `box admin status`.
     - [x] Mettre à jour README, DEVELOPMENT_STRATEGY et SPECS pour refléter les nouvelles commandes et matrices de plateformes.

3) Swift S4 — Crypto / libsodium (Issue #21)
   - [ ] Introduire un module libsodium Swift (bindings légers).
   - [ ] Rebrancher Noise NK/IK, AEAD XChaCha20-Poly1305, fenêtre anti-rejeu.
   - [ ] Ajouter les tests de transport chiffré et documenter le framing mis à jour.

Legacy backlog (C – référence)
1) Protocol framing v1 en C (Issue #25)
   - [x] Add v1 header (magic 'B', version, length, command, request_id) alongside current simple header.
   - [x] Gate via feature flag; update tests in `test/test_BFBoxProtocol.c`.
   - [x] Exit: round‑trip HELLO over UDP (unencrypted, temporary) using the new frame; tests green (cli/server `--protocol v1` validés, doc mise à jour).

2) Config + Non‑root enforcement + Admin channel (skeleton) (Issue #14)
   - [x] Enforce non‑root startup on Unix/macOS; parse `~/.box/boxd.toml` for port/log settings; expose `box admin status` over the Unix socket.
   - [ ] Extend config keys (logging, transports, storage) and persist round-trip tests.
   - [ ] Add Windows named pipe admin endpoint + parity commands.
   - [ ] Add additional admin actions (ping, config reload, connectivity probes).
   - [ ] Exit: `boxd` exposes status and basic controls via admin channel; config round‑trip in tests for Unix and Windows.

3) Remove DTLS (legacy) and references (Issue #21)
   - [x] DTLS code, headers, OpenSSL wiring, tests and docs removed; builds/tests green.

4) Storage and Queues (filesystem + index) (Issue #15)
   - [ ] Implement storage root layout and portable B‑tree index.
   - [ ] Implement PUT/GET/DELETE in `boxd`; compute SHA‑256 digests.
   - [ ] Wire `box` CLI for `sendTo`, `getFrom`, `deleteFrom` on localhost.
   - [ ] Exit: e2e object transfer locally; tests for store/retrieve by digest.

5) Crypto (Noise + XChaCha) groundwork (Issue #16)
   - [x] Auto-detect libsodium via pkg-config and link when available.
   - [x] Implement and test AEAD helpers (XChaCha20-Poly1305).
   - [x] Implement Noise adapter framing (`NZ v1` + nonce + ciphertext) using a temporary preShareKey.
   - [x] Add unit tests for send/recv, bad header, wrong key; expose debug resend hook for replay testing.
   - [x] Implement per-peer replay protection (salt + 64-entry sliding window).
   - [ ] Document framing header and nonce construction (SPECS.md); enumerate error codes and limits.
   - [ ] Extend tests for out-of-order acceptance within the sliding window and explicit replay rejection.
   - [ ] Add explicit runtime/CLI toggle for clear vs noise per operation.
   - [ ] Prepare handshake scaffolding (Noise NK/IK) to derive session keys and replace the temporary preShareKey.
   - [ ] Exit: encrypted echo using Noise; framing documented; frame/AEAD tests robust (including replays and OOO); handshake ready.

6) Location Service + Presence (Issue #17)
   - [x] Implement embedded LS register/resolve for `/uuid` presence (prototype Swift + filesystem store).
   - [ ] Publish optional `/location` geo records.
   - [ ] Admission control: only registered clients accepted.
   - [ ] Exit: client resolves server via LS; presence visible.

7) ACL engine (Issue #18)
   - [ ] Implement allow/deny with intersection; load from boxd.toml; enforce on operations.
   - [ ] Exit: unauthorized requests denied; examples from spec pass.

8) NAT traversal tooling (Issue #19)
 - [x] Admin-channel NAT probe, PCP/NAT‑PMP/UPnP mapping, keepalives; `box check connectivity` JSON. *(keepalives/CLI orchestration à finaliser)*
 - [x] Add PCP PEER support for coordinated hole punching and surface external IPv4 candidates to clients. *(exposé via `portMappingPeer*`, `manualExternal*`, LS `addresses[]`)*
 - [ ] Once UPnP-capable hardware is available, validate the automatic mapping sequence end-to-end (enable UPnP/PCP/NAT-PMP on the gateway, run `box admin nat-probe --gateway <gw>` and confirm status `ok`). Document any required router settings.
 - [ ] Exit: IPv6 reachable detection; mapping acquired on supported gateways.

Android Track (parallel)
- [ ] Extend minimal C API with no-op JNI-callable methods (e.g., BFCoreSelfTest()).
- [ ] Prepare OpenSSL/libsodium Android builds and add a BoxFoundation-android target (later milestone).

9) Android sample: expand coverage (app + JNI) (Issue #20)
   - [ ] Build JNI via externalNativeBuild from the sample app (use android/jni CMake).
   - [ ] Package multi-ABI native libs (arm64-v8a, armeabi-v7a, x86_64) and verify on devices/emulator.
   - [ ] Expose and call additional JNI methods (e.g., connectivity check stub) and render results in UI.
   - [ ] Add required permissions (WAKE_LOCK, ACCESS_NETWORK_STATE, CHANGE_WIFI_MULTICAST_STATE) and request flows where needed.
   - [ ] Add a GitHub Actions job to assemble the sample in CI (build-only, no emulator).
   - [ ] Exit: app builds in CI, runs on a device to display version and a stub connectivity check result.

Notes
- Keep patch size small and focused per milestone item.
- Update docs as behavior changes; add tests where missing.
