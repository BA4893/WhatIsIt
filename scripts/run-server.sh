#!/usr/bin/env bash
# Run the HTTP validation engine and keep a log for the Phase 0a gate.
set -euo pipefail
cd "$(dirname "$0")/../server"

export PORT="${PORT:-18770}"
export WHATSAPP_TOKEN="${WHATSAPP_TOKEN:-}"
export DB_PATH="${DB_PATH:-data/whatsapp.db}"
export MEDIA_DIR="${MEDIA_DIR:-data/media}"
export RUST_LOG="${RUST_LOG:-info}"

echo "engine: http://0.0.0.0:${PORT}  db=${DB_PATH}"
cargo run --release 2>&1 | tee server.log
