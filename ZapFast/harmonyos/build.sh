#!/usr/bin/env bash
# Builds ZapFast for HarmonyOS: the Rust host, then the HAP that carries it.
#
# Everything runs on a HarmonyOS PC with the command-line tools (hmos-clt),
# no DevEco Studio and no Windows VM. The signing material is separate: an
# unsigned HAP is produced here, and README.md says how to sign it with the
# SDK's hap-sign-tool or how to let DevEco Studio sign it.
#
#   ./harmonyos/build.sh                 # debug HAP
#   ./harmonyos/build.sh release         # release HAP
#
# Environment:
#   HMS_CLT     the command-line tools (default: the hmos-clt install)
#   RUST_ROOT   the aarch64-unknown-linux-ohos Rust toolchain
#   CARGO_TARGET_DIR  where Cargo builds (default: the repository's target/)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
mode="${1:-debug}"
if [[ "$mode" != "debug" && "$mode" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

HMS_CLT="${HMS_CLT:-/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0}"
RUST_ROOT="${RUST_ROOT:-$HOME/rust-ohos/rust-1.95.0-aarch64-unknown-linux-ohos}"
SDK="$HMS_CLT/sdk"
NODE="$HMS_CLT/node/bin"
HVIGOR="$HMS_CLT/hvigor/bin/hvigorw"
export DEVECO_SDK_HOME="$SDK"
export PATH="$RUST_ROOT/bin:$NODE:$PATH"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/cacert.pem}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo/target}"

echo "== building the Rust host ($mode)"
# The port builds with the Rust 1.95 toolchain that runs on the device; the
# desktop manifests advertise a newer MSRV, so the check is relaxed here. The
# code that actually needs a newer compiler, if any, will fail to compile and
# has to be handled, not papered over.
if [ "$mode" = "release" ]; then
  cargo build \
    --manifest-path "$repo/Cargo.toml" \
    --package zapfast-ohos \
    --lib \
    --target aarch64-unknown-linux-ohos \
    --ignore-rust-version \
    --release
else
  cargo build \
    --manifest-path "$repo/Cargo.toml" \
    --package zapfast-ohos \
    --lib \
    --target aarch64-unknown-linux-ohos \
    --ignore-rust-version
fi

static="$CARGO_TARGET_DIR/aarch64-unknown-linux-ohos/$mode/libzapfast_ohos.a"
if [[ ! -f "$static" ]]; then
  echo "the Rust host was not built at $static" >&2
  exit 1
fi
mkdir -p "$here/entry/libs/arm64-v8a"
cp "$static" "$here/entry/libs/arm64-v8a/libzapfast_ohos.a"

echo "== installing the app's package dependencies"
(cd "$here" && "$HMS_CLT/ohpm/bin/ohpm" install --all)

echo "== building the HAP ($mode)"
cd "$here"
"$HVIGOR" --mode module -p product=default -p buildMode="$mode" \
  assembleHap --no-daemon

out="$here/entry/build/default/outputs/default"
echo
echo "HAP:"
ls -1 "$out"/*.hap 2>/dev/null || true
echo
echo "Install a signed HAP with:"
echo "  $SDK/default/openharmony/toolchains/hdc install -r <file>.hap"
