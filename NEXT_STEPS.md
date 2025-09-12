Next Steps and Status

Status (high level)
- Spec complete for v0.1 (SPECS.md): protocol framing, LS, queues, ACLs, NAT, connectivity CLI, threat model, examples.
- Conventions and dependencies documented; CI in place (native, dockerized, Android minimal + JNI build).
- Baseline C code builds/tests. DTLS and OpenSSL have been removed (Issue #21 complete).
- Libsodium groundwork present: AEAD helpers (XChaCha20‑Poly1305) and Noise transport skeleton compiled/linked when available.
- Non‑root enforcement active on Unix/macOS; admin channel skeleton is live on `~/.box/run/boxd.sock` with a `status` command; `box admin status` CLI added.
- Minimal config parser loads `~/.box/boxd.toml` (port/log settings) with CLI/env precedence.

Immediate TODOs (near-term)
1) Protocol framing v1 in C (Issue #13)
   - Add v1 header (magic 'B', version, length, command, request_id) alongside current simple header.
   - Gate via feature flag; update tests in `test/test_BFBoxProtocol.c`.
   - Exit: round‑trip HELLO over UDP (unencrypted, temporary) using the new frame; tests green.

2) Config + Non‑root enforcement + Admin channel (skeleton) (Issue #14)
   - Current: non‑root enforcement done (Unix/macOS); parse `~/.box/boxd.toml` (port/log); admin socket implemented with `status` action; `box admin status` added.
   - Next: extend config keys; add Windows named pipe; add more admin actions.
   - Exit: `boxd` exposes status and basic controls via admin channel; config round‑trip in tests.

3) Remove DTLS (legacy) and references (Issue #21)
   - DTLS code, headers, OpenSSL wiring, tests and docs removed; builds/tests green.

4) Storage and Queues (filesystem + index) (Issue #15)
   - Implement storage root layout and portable B‑tree index.
   - Implement PUT/GET/DELETE in `boxd`; compute SHA‑256 digests.
   - Wire `box` CLI for `sendTo`, `getFrom`, `deleteFrom` on localhost.
   - Exit: e2e object transfer locally; tests for store/retrieve by digest.

5) Crypto (Noise + XChaCha) groundwork (Issue #16)
   - Current: libsodium autodetected; AEAD helpers + Noise adapter skeleton present.
   - Next: define wire format and implement encrypt/decrypt; add unit tests for framing + AEAD.
   - Exit: encrypted echo using new transport; AEAD unit tests.

6) Location Service + Presence (Issue #17)
   - Implement embedded LS register/resolve; publish `/uuid` presence and optional `/location`.
   - Admission control: only registered clients accepted.
   - Exit: client resolves server via LS; presence visible.

7) ACL engine (Issue #18)
   - Implement allow/deny with intersection; load from boxd.toml; enforce on operations.
   - Exit: unauthorized requests denied; examples from spec pass.

8) NAT traversal tooling (Issue #19)
   - Admin-channel NAT probe, PCP/NAT‑PMP/UPnP mapping, keepalives; `box check connectivity` JSON.
   - Exit: IPv6 reachable detection; mapping acquired on supported gateways.

Android Track (parallel)
- Extend minimal C API with a couple of no-op methods we can invoke from JNI (e.g., BFCoreSelfTest()).
- Prepare OpenSSL/libsodium Android builds and add a BoxFoundation-android target (later milestone).

9) Android sample: expand coverage (app + JNI) (Issue #20)
   - Build JNI via externalNativeBuild from the sample app (use android/jni CMake).
   - Package multi-ABI native libs (arm64-v8a, armeabi-v7a, x86_64) and verify on devices/emulator.
   - Expose and call additional JNI methods (e.g., connectivity check stub) and render results in UI.
   - Add required permissions (WAKE_LOCK, ACCESS_NETWORK_STATE, CHANGE_WIFI_MULTICAST_STATE) and request flows where needed.
   - Add a GitHub Actions job to assemble the sample in CI (build-only, no emulator).
   - Exit: app builds in CI, runs on a device to display version and a stub connectivity check result.

Notes
- Keep patch size small and focused per milestone item.
- Update docs as behavior changes; add tests where missing.
