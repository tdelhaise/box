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

Fedora (dnf)
- Install toolchain and libs:
  sudo dnf install -y @development-tools cmake ninja-build pkg-config openssl-devel ripgrep clang-tools-extra
- Configure and build:
  make configure BUILD_TYPE=Debug
  make build

Arch Linux (pacman)
- Install toolchain and libs:
  sudo pacman -Syu --needed base-devel cmake ninja pkgconf openssl ripgrep clang-format
- Configure and build:
  make configure BUILD_TYPE=Debug
  make build

macOS (Homebrew)
- Install tooling:
  xcode-select --install  # if CLI tools not installed
  brew update
  brew install cmake ninja openssl@3 pkg-config ripgrep llvm git
- Configure with OpenSSL path:
  export OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
  cmake -S . -B build -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR"
  cmake --build build -j

Windows (MSVC + vcpkg)
- Install tooling:
  - Visual Studio Build Tools (MSVC)
  - CMake, Ninja, LLVM (clang-format), ripgrep, Git
- OpenSSL via vcpkg:
  # PowerShell (run as regular user)
  git clone https://github.com/microsoft/vcpkg.git $env:USERPROFILE\vcpkg
  & $env:USERPROFILE\vcpkg\bootstrap-vcpkg.bat
  $env:VCPKG_ROOT = "$env:USERPROFILE\vcpkg"
  $env:VCPKG_DEFAULT_TRIPLET = "x64-windows"
  & $env:VCPKG_ROOT\vcpkg.exe install openssl:x64-windows
- Configure (example using vcpkg toolchain):
  $toolchain = "$env:VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake"
  cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$toolchain"
  cmake --build build

Chocolatey (optional, for tooling installs)
- PowerShell (Admin):
  Set-ExecutionPolicy Bypass -Scope Process -Force; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; `
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
- Then install tools:
  choco install -y cmake ninja llvm ripgrep git

vcpkg Toolchain Snippet (cross-platform)
- Windows PowerShell:
  $env:VCPKG_ROOT = "$env:USERPROFILE\vcpkg"
  $toolchain = "$env:VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake"
  cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DCMAKE_BUILD_TYPE=Release
- macOS/Linux (bash):
  export VCPKG_ROOT="$HOME/vcpkg"
  git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT" && "$VCPKG_ROOT/bootstrap-vcpkg.sh"
  export VCPKG_DEFAULT_TRIPLET=x64-osx   # or x64-linux
  cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
  cmake --build build -j

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

Containerized Dev Environment (Docker)
- A lightweight dev image is provided to avoid local setup differences.
- Build the image:
  docker build -f Dockerfile.dev -t box-dev .
- Run a container with the repo mounted:
  docker run --rm -it -v "$PWD":/work -w /work box-dev bash
- Inside the container, build and test:
  make configure BUILD_TYPE=Debug && make build && make test
