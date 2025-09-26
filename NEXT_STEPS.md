Next Steps and Status

Status (high level)
- [x] Spec complete for v0.1 (SPECS.md): protocol framing, LS, queues, ACLs, NAT, connectivity CLI, threat model, examples.
- [x] Conventions and dependencies documented; CI in place (native, dockerized, Android minimal + JNI build).
- [x] Baseline C code builds/tests. DTLS and OpenSSL have been removed (Issue #21 complete).
- [x] Libsodium groundwork present: AEAD helpers (XChaCha20‑Poly1305) and Noise transport skeleton compiled/linked when available.
- [x] Non‑root enforcement active on Unix/macOS; admin channel skeleton is live on `~/.box/run/boxd.socket` with a `status` command; `box admin status` CLI added.
- [x] Minimal config parser loads `~/.box/boxd.toml` (port/log settings) with CLI/env precedence.

Immediate TODOs (near-term)
1) Protocol framing v1 in C (Issue #13)
   - [x] Add v1 header (magic 'B', version, length, command, request_id) alongside current simple header.
   - [x] Gate via feature flag; update tests in `test/test_BFBoxProtocol.c`.
   - [ ] Exit: round‑trip HELLO over UDP (unencrypted, temporary) using the new frame; tests green (toggle exists but default encore simple; valider workflow complet + doc).

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
   - [ ] Implement embedded LS register/resolve; publish `/uuid` presence and optional `/location`.
   - [ ] Admission control: only registered clients accepted.
   - [ ] Exit: client resolves server via LS; presence visible.

7) ACL engine (Issue #18)
   - [ ] Implement allow/deny with intersection; load from boxd.toml; enforce on operations.
   - [ ] Exit: unauthorized requests denied; examples from spec pass.

8) NAT traversal tooling (Issue #19)
   - [ ] Admin-channel NAT probe, PCP/NAT‑PMP/UPnP mapping, keepalives; `box check connectivity` JSON.
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
