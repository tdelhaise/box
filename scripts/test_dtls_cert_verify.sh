#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)

# Skip on CI or restricted env unless explicitly enabled
if [ "${BOX_IT_ENABLE:-}" != "1" ]; then
  echo "[it] Skipped (set BOX_IT_ENABLE=1 to run)"
  exit 0
fi
BUILD_DIR="$ROOT_DIR/build"

cd "$BUILD_DIR"

echo "[it] Generating self-signed server/client certs..."
openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.pem -days 1 -nodes -subj "/CN=boxd" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -keyout client.key -out client.pem -days 1 -nodes -subj "/CN=box" >/dev/null 2>&1

echo "[it] Starting boxd (server)..."
"$BUILD_DIR/boxd" --cert server.pem --key server.key &
SERVER_PID=$!
sleep 0.3

echo "[it] Running box (client) with CA + hostname verification..."
export BOX_CA_FILE="$BUILD_DIR/server.pem"
export BOX_EXPECTED_HOST="boxd"
"$BUILD_DIR/box" --cert client.pem --key client.key 127.0.0.1 || {
  echo "[it] Client failed"
  kill "$SERVER_PID" || true
  exit 1
}

echo "[it] Shutting down server..."
kill "$SERVER_PID" || true
wait "$SERVER_PID" 2>/dev/null || true

echo "[it] OK"
