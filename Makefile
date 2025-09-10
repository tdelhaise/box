# Simple Make wrapper for CMake workflow

.PHONY: help configure build test check format format-check certs clean rebuild

BUILD_TYPE ?= Debug

help:
	@echo "Targets:"
	@echo "  configure  - Configure CMake build (BUILD_TYPE=$(BUILD_TYPE))"
	@echo "  build      - Build all targets"
	@echo "  test       - Run ctest (output on failure)"
	@echo "  check      - Run naming convention checks"
	@echo "  format     - Run clang-format on C headers/sources"
	@echo "  format-check - Check formatting (fails if changes needed)"
	@echo "  certs      - Generate self-signed certs (CMake target)"
	@echo "  clean      - Clean CMake build artifacts"
	@echo "  rebuild    - Reconfigure and rebuild from scratch"

configure:
	@cmake -S . -B build -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) $(OPENSSL_ROOT_DIR:%=-DOPENSSL_ROOT_DIR=%)

build:
	@cmake --build build -j

test:
	@ctest --test-dir build --output-on-failure

check:
	@cmake --build build --target check || bash scripts/check_naming.sh

format:
	@bash scripts/format.sh

format-check:
	@bash scripts/check_format.sh

certs:
	@cmake --build build --target certs

clean:
	@cmake --build build --target clean || true

rebuild:
	@rm -rf build
	@$(MAKE) configure BUILD_TYPE=$(BUILD_TYPE)
	@$(MAKE) build
