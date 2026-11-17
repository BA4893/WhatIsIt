#!/usr/bin/env bash
# Build libwa_engine.so on a trusted Linux/macOS/Windows host and place it in
# the module libs. Run from the repository root.
set -euo pipefail

: "${OHOS_SDK_NATIVE:?Set OHOS_SDK_NATIVE to the OpenHarmony SDK native directory}"

CLANG="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
CXX="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
AR="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$CLANG"
export CC_aarch64_unknown_linux_ohos="$CLANG"
export CXX_aarch64_unknown_linux_ohos="$CXX"
export AR_aarch64_unknown_linux_ohos="$AR"

cargo build --manifest-path engine/Cargo.toml --release \
  --target aarch64-unknown-linux-ohos

mkdir -p entry/libs/arm64-v8a
cp engine/target/aarch64-unknown-linux-ohos/release/libwa_engine.so \
   entry/libs/arm64-v8a/libwa_engine.so

echo "engine installed: entry/libs/arm64-v8a/libwa_engine.so"
