Contributing to Box

Thanks for your interest in contributing! This project uses a few simple conventions to keep the codebase consistent and easy to navigate.

**Naming Conventions**
- Components use the `BF` prefix with component-based names.
  - Examples: `BFCommon`, `BFSocket`, `BFUdp`, `BFUdpClient`, `BFUdpServer`, `BFBoxProtocol`.
  - Header ↔ source mapping:
    - `include/box/BFCommon.h` ↔ `src/lib/BFCommon.c`
    - `include/box/BFSocket.h` ↔ `src/lib/BFSocket.c`
    - `include/box/BFUdp.h` ↔ `src/lib/BFUdp.c`
    - `include/box/BFUdpClient.h` ↔ `src/lib/BFUdpClient.c`
    - `include/box/BFUdpServer.h` ↔ `src/lib/BFUdpServer.c`
    - (DTLS removed; Noise/libsodium transport in progress)
    - `include/box/BFBoxProtocol.h` ↔ `src/lib/BFBoxProtocol.c`
- Tests use the `test_` prefix followed by the component name.
  - Example: `test/test_BFBoxProtocol.c` with CMake target `test_BFBoxProtocol`.
- CMake options/macros use the `BOX_` prefix.
  - Example: `BOX_USE_PRESHAREKEY` (legacy `BOX_USE_PSK` is honored but deprecated).
- Public headers live under `include/box/` and are included via `#include "box/<Header>.h"`.

**Style & Safety**
- C code targets C11 and enables strict warnings; avoid introducing warnings.
- Keep changes focused and consistent with surrounding code.
- Prefer small, self-contained commits with clear messages.

**Running Checks**
- Build: `cmake -S . -B build && cmake --build build -j`
- Tests: `ctest --test-dir build --output-on-failure`
- Naming check: `bash scripts/check_naming.sh`

**Opening PRs**
- Describe the motivation, scope, and any behavior impact.
- If renaming/moving files, mention how it aligns with the conventions above.

**Optional pre-commit hook**
Run checks automatically before each commit:

1) Create `.git/hooks/pre-commit` with:

```
#!/usr/bin/env bash
set -euo pipefail

echo "pre-commit: running naming check..."
bash scripts/check_naming.sh

echo "pre-commit: formatting sources (if clang-format available)..."
bash scripts/format.sh
echo "pre-commit: verifying formatting..."
bash scripts/check_format.sh

echo "pre-commit: running fast build (if build/ exists)..."
bash scripts/fast_build.sh
```

2) Make it executable:

```
chmod +x .git/hooks/pre-commit
```

This prevents committing files that violate the BF naming conventions.
