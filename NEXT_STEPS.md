Next Steps and Status

Status (high level)
- Spec complete for v0.1 (SPECS.md): protocol framing, LS, queues, ACLs, NAT, connectivity CLI, threat model, examples.
- Conventions and dependencies documented; CI in place (native, dockerized, Android minimal + JNI build).
- Baseline C code builds/tests; DTLS path exists for bring‑up. Android minimal core compiles; JNI wrapper and sample app added.

Immediate TODOs (near-term)
1) Protocol framing v1 in C (Issue #13)
   - Add v1 header (magic 'B', version, length, command, request_id) alongside current simple header.
   - Gate via feature flag; update tests in `test/test_BFBoxProtocol.c`.
   - Exit: round-trip HELLO over DTLS with new frame; tests green.

2) Config + Non‑root enforcement + Admin channel (skeleton) (Issue #14)
   - Enforce non‑root/Administrator refusal in `boxd` startup.
   - Parse TOML: `~/.box/boxd.toml` and `~/.box/box.toml` (Unix/macOS; Windows equivalents).
   - Implement local admin channel socket/pipe and `status` action.
   - Exit: `boxd` exposes status via admin channel; unit test/smoke check.

3) Storage and Queues (filesystem + index) (Issue #15)
   - Implement storage root layout and portable B‑tree index.
   - Implement PUT/GET/DELETE in `boxd`; compute SHA‑256 digests.
   - Wire `box` CLI for `sendTo`, `getFrom`, `deleteFrom` on localhost.
   - Exit: e2e object transfer locally; tests for store/retrieve by digest.

4) Crypto (Noise + XChaCha) groundwork (Issue #16)
   - Vendor or depend on libsodium; add a new transport path (kept behind flag).
   - Implement NK/IK handshake skeleton; payload AEAD with XChaCha20‑Poly1305.
   - Exit: encrypted echo using new transport; AEAD unit tests.

5) Location Service + Presence (Issue #17)
   - Implement embedded LS register/resolve; publish `/uuid` presence and optional `/location`.
   - Admission control: only registered clients accepted.
   - Exit: client resolves server via LS; presence visible.

6) ACL engine (Issue #18)
   - Implement allow/deny with intersection; load from boxd.toml; enforce on operations.
   - Exit: unauthorized requests denied; examples from spec pass.

7) NAT traversal tooling (Issue #19)
   - Admin-channel NAT probe, PCP/NAT‑PMP/UPnP mapping, keepalives; `box check connectivity` JSON.
   - Exit: IPv6 reachable detection; mapping acquired on supported gateways.

Android Track (parallel)
- Extend minimal C API with a couple of no-op methods we can invoke from JNI (e.g., BFCoreSelfTest()).
- Prepare OpenSSL/libsodium Android builds and add a BoxFoundation-android target (later milestone).

8) Android sample: expand coverage (app + JNI) (Issue #20)
   - Build JNI via externalNativeBuild from the sample app (use android/jni CMake).
   - Package multi-ABI native libs (arm64-v8a, armeabi-v7a, x86_64) and verify on devices/emulator.
   - Expose and call additional JNI methods (e.g., connectivity check stub) and render results in UI.
   - Add required permissions (WAKE_LOCK, ACCESS_NETWORK_STATE, CHANGE_WIFI_MULTICAST_STATE) and request flows where needed.
   - Add a GitHub Actions job to assemble the sample in CI (build-only, no emulator).
   - Exit: app builds in CI, runs on a device to display version and a stub connectivity check result.

Notes
- Keep patch size small and focused per milestone item.
- Update docs as behavior changes; add tests where missing.
