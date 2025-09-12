Dependencies

Overview
- This document lists build-time and optional runtime dependencies for the Box project (box/boxd) across Linux, macOS, and Windows, and provides quick setup guidance.
- The current codebase uses OpenSSL for DTLS bring‑up; the specification targets Noise (Ed25519/X25519) + XChaCha20‑Poly1305 via libsodium in a later milestone.

Core Build Tooling (all platforms)
- CMake >= 3.16
- C compiler and linker
  - Linux/macOS: Clang or GCC
  - Windows: MSVC (Visual Studio Build Tools)
- Build system: Ninja or Make
- Utilities: pkg-config (optional, for QUIC autodiscovery), ripgrep (scripts), clang-format (format checks), bash (scripts)

Mandatory Libraries (current)
- OpenSSL (SSL, Crypto)
  - Used by the DTLS transport path in BoxFoundation for secure datagram sessions during bring‑up.
  - CMake target: OpenSSL::SSL OpenSSL::Crypto

Planned/Optional Libraries
- Crypto (planned default): libsodium (Ed25519, X25519, XChaCha20‑Poly1305)
  - To implement Noise NK/IK over UDP per SPECS.md
- NAT mapping (optional, for convenience):
  - miniupnpc (UPnP IGD)
  - libnatpmp (NAT‑PMP)
  - PCP client library (if adopted) or custom minimal PCP client
- QUIC (optional, experimental):
  - ngtcp2 (+ ngtcp2_crypto[_openssl]) or
  - MsQuic or
  - picoquic
  - Note: current code contains adapter stubs; QUIC is not required for normal builds.
- Storage backends (optional):
  - BSD libdb (available on macOS/FreeBSD/OpenBSD)
  - LMDB (portable)
  - Default path uses a portable in‑tree B‑tree and the filesystem; no external DB required.

Platform Setup

Linux (Debian/Ubuntu)
- Install toolchain and libs:
  sudo apt-get update
  sudo apt-get install -y build-essential cmake ninja-build pkg-config libssl-dev ripgrep clang-format
- Configure and build:
  make configure BUILD_TYPE=Debug
  make build

macOS (Homebrew)
- Install tooling:
  brew install cmake ninja openssl@3 pkg-config ripgrep llvm
- Configure with OpenSSL path:
  cmake -S . -B build -DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3)
  cmake --build build -j

Windows (MSVC + vcpkg)
- Install tooling:
  - Visual Studio Build Tools (MSVC)
  - CMake, Ninja, LLVM (clang-format), ripgrep
- OpenSSL via vcpkg:
  vcpkg install openssl:x64-windows
- Configure (example using vcpkg toolchain):
  cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE="C:/path/to/vcpkg/scripts/buildsystems/vcpkg.cmake"
  cmake --build build

Scripting and Utilities
- OpenSSL CLI is used by the `certs` target to generate self‑signed certificates for DTLS tests.
- Bash is required to run scripts under `scripts/`.

Environment Variables
- OPENSSL_ROOT_DIR: Path to a non‑system OpenSSL installation (required on macOS with Homebrew OpenSSL).

Runtime Notes
- If linking dynamically to OpenSSL, ensure runtime packages (libssl/libcrypto) are installed on the target system.
- No other runtime services are required; Location Service is embedded in boxd.

CI Dependencies
- GitHub Actions workflow installs: cmake, build-essential, ninja, libssl-dev, pkg-config, ripgrep, clang-format.

