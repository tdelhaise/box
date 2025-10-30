Contributing Guidelines
=======================

Thank you for helping improve Box. The project is now purely Swift (Swift 6.2, SwiftPM). The legacy C toolchain has been removed; new contributions should target the Swift modules under `swift/Sources/` and tests under `swift/Tests/`.

## Development Environment
- Install Swift 6.2 (recommended: `swiftly install 6.2.0`).
- Clone the repository, then run:
  ```bash
  swift build --product box
  swift test --parallel
  ```
- Prefer running the CLI through SwiftPM during development (`swift run box …`). When packaging, use `swift build -c release`.

## Coding Style
- Follow the conventions in `CODE_CONVENTIONS.md`.
- Document public types, properties and functions with `///` comments.
- Avoid abbreviated identifiers (e.g., `addr`, `buf`, `idx`). Use descriptive names (`address`, `buffer`, `index`).
- Keep patches focused: one logical change per pull request, with accompanying tests and doc updates.

## Commit Expectations
- Add or update tests whenever behaviour changes; prefer integration tests in `BoxCLIIntegrationTests` for CLI/admin flows and unit tests in `BoxAppTests` for pure logic.
- Run `swift test --parallel` before submitting.
- If your change touches runtime behaviour or operational guidance, update `README.md`, `SPECS.md`, or `DEVELOPMENT_STRATEGY.md` as appropriate.

## Submitting Changes
1. Create a feature branch off `main`.
2. Commit your work using clear, imperative messages (e.g., “Add permanent queue support to BoxServerStore”).
3. Push your branch and open a pull request summarising:
   - Motivation and scope.
   - Tests performed (include the `swift test` output or relevant subset).
   - Documentation updates.
4. Be available for review feedback; small, iterative fixes are encouraged.

## Not in Scope
- Reintroducing CMake, Make, or the retired C sources.
- Changes that break existing Swift tests without replacement coverage.

By contributing, you agree to keep the documentation and tests in sync with your changes and to maintain the Swift-only toolchain moving forward.
