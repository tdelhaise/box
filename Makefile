# Simple Make wrapper for CMake workflow

.PHONY: help configure build test check format format-check certs clean rebuild docker-build docker-shell

BUILD_TYPE ?= Debug

help:
	@echo "Targets:"
	@echo "  configure  - Configure CMake build (BUILD_TYPE=$(BUILD_TYPE))"
	@echo "  build      - Build all targets"
	@echo "  test       - Run ctest (output on failure)"
	@echo "  bench      - Build and run microbenchmarks (array/dictionary)"
	@echo "  check      - Run naming convention checks"
	@echo "  format     - Run clang-format on C headers/sources"
	@echo "  format-check - Check formatting (fails if changes needed)"
	@echo "  certs      - Generate self-signed certs (CMake target)"
	@echo "  clean      - Clean CMake build artifacts"
	@echo "  rebuild    - Reconfigure and rebuild from scratch"
	@echo "  docker-build - Build dev container image (DOCKER_IMAGE=$(DOCKER_IMAGE))"
	@echo "  docker-shell - Start an interactive shell in the dev container with repo mounted"

configure:
	@cmake -S . -B build -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) $(OPENSSL_ROOT_DIR:%=-DOPENSSL_ROOT_DIR=%)

build:
	@cmake --build build -j

test:
	@ctest --test-dir build --output-on-failure

bench:
	@$(MAKE) build
	@echo "Running BFSharedArray benchmark..."
	@./build/bench_BFSharedArray || true
	@echo "Running BFSharedDictionary benchmark..."
	@./build/bench_BFSharedDictionary || true

check:
	@cmake --build build --target check || bash scripts/check_naming.sh
	@bash scripts/check_abbreviations.sh || true

.PHONY: check-strict
check-strict:
	@cmake --build build --target check || bash scripts/check_naming.sh
	@ENFORCE_ABBREV=1 bash scripts/check_abbreviations.sh include/box src/box src/boxd android/jni

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

# --- Docker dev environment ---

DOCKER_IMAGE ?= box-dev

docker-build:
	docker build -f Dockerfile.dev -t $(DOCKER_IMAGE) .

docker-shell: docker-build
	docker run --rm -it -v "$(PWD)":/work -w /work -u $$(id -u):$$(id -g) $(DOCKER_IMAGE) bash
