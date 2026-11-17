#!/usr/bin/env bash
# Install a downloaded CI artifact as the module's engine.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/libwa_engine.so" >&2
  exit 2
fi
mkdir -p entry/libs/arm64-v8a
cp "$1" entry/libs/arm64-v8a/libwa_engine.so
echo "installed: entry/libs/arm64-v8a/libwa_engine.so"
