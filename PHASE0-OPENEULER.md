# Phase 0 on the Integrated Engine VM

Yes — the **Integrated Engine for Developers** openEuler VM can be the Linux
build host for `libwa_engine.so`. It is a better fit than waiting on GitHub
Actions because you can iterate on the first compiler error directly.

## 0. What the VM needs to be

- Turned on from **System console → Integrated Engine for Developers → Turn on**.
- Terminal access.
- Internet access for `dnf`, rustup and crates.io.
- A shared folder or another way to see the project and write the `.so` back.

Check first:

```bash
uname -m
cat /etc/os-release
free -h
df -h
curl -I https://static.rust-lang.org
```

The architecture matters:

- `aarch64` — reuse the HarmonyOS PC SDK native toolchain; it is already an
  aarch64 Linux ELF toolchain.
- `x86_64` — download the Linux x86_64 OpenHarmony SDK.

## 1. Install build dependencies

```bash
sudo dnf install -y \
  git curl tar gzip unzip xz \
  gcc gcc-c++ make cmake pkg-config \
  python3 nodejs npm jq \
  openssl-devel sqlite-devel
```

4 GB RAM is tight for a Rust release build with `whatsapp-rust`. Add swap:

```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
free -h
```

## 2. Install Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustc --version
```

Install the pinned toolchain from the workflow:

```bash
rustup toolchain install 1.99.1
rustup default 1.99.1
rustup target add aarch64-unknown-linux-ohos
```

If `rustup target add` says the target is unavailable:

```bash
rustup toolchain install nightly
rustup +nightly component add rust-src
```

and use `cargo +nightly build -Z build-std=std,panic_abort ...` below.

## 3. Get the OpenHarmony native SDK

### If the VM is aarch64

The HarmonyOS PC SDK already contains an aarch64 `clang`. Copy the native
directory into the VM through File sharing:

```text
/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/native
```

Keep the whole `native/` directory, not only `llvm/`: the sysroot is required.

```bash
export OHOS_SDK_NATIVE=/path/to/native
file "$OHOS_SDK_NATIVE/llvm/bin/clang"
# expect: ELF 64-bit LSB ..., ARM aarch64
```

### If the VM is x86_64

Download the Linux SDK, for example the `v7.0` asset from
`openharmony-rs/ohos-sdk`, extract it, and use:

```bash
export OHOS_SDK_NATIVE=/path/to/sdk/linux/native
```

If the release is split into `.aa`, `.ab` parts, concatenate them first, then
extract.

## 4. Put the project in the VM

Use **File sharing** to mount the project, or copy a tarball over HTTP.

Host side, if needed:

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects
tar -czf /tmp/WhatIsIt-main.tgz WhatIsIt-main
python3 -m http.server 8000 --directory /tmp
```

VM side (QEMU NAT usually exposes the host as `10.0.2.2`):

```bash
curl -O http://10.0.2.2:8000/WhatIsIt-main.tgz
tar -xzf WhatIsIt-main.tgz
cd WhatIsIt-main
```

Build in a shared folder if possible so the resulting `.so` appears directly on
the HarmonyOS side.

## 5. Build the engine

```bash
cd WhatIsIt-main

export OHOS_SDK_NATIVE=/path/to/native
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CC_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
export CXX_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang++"
export AR_aarch64_unknown_linux_ohos="$OHOS_SDK_NATIVE/llvm/bin/llvm-ar"
export CMAKE_TOOLCHAIN_FILE="$OHOS_SDK_NATIVE/build/cmake/ohos.toolchain.cmake"

# 4 GB VM: avoid LTO and cap parallelism for the first build
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_BUILD_JOBS=2

./scripts/build-engine.sh
```

If `rustup target add` failed, use:

```bash
cargo +nightly build \
  --manifest-path engine/Cargo.toml \
  --release \
  --target aarch64-unknown-linux-ohos \
  -Z build-std=std,panic_abort
```

Then copy manually:

```bash
mkdir -p entry/libs/arm64-v8a
cp engine/target/aarch64-unknown-linux-ohos/release/libwa_engine.so \
   entry/libs/arm64-v8a/libwa_engine.so
```

## 6. Verify the artifact

```bash
file entry/libs/arm64-v8a/libwa_engine.so
readelf -h entry/libs/arm64-v8a/libwa_engine.so | grep Machine
```

Expected:

```text
ELF 64-bit LSB shared object, ARM aarch64
Machine: AArch64
```

Also check that the NAPI symbols are exported:

```bash
"$OHOS_SDK_NATIVE/llvm/bin/llvm-nm" -D \
  entry/libs/arm64-v8a/libwa_engine.so | grep wa_engine_
```

## 7. Build and probe the HAP

On the HarmonyOS side:

1. Ensure `entry/libs/arm64-v8a/libwa_engine.so` exists.
2. Build the HAP with DevEco or hvigor.
3. Sign and install.

The hybrid shell now includes a Phase 0 engine probe at startup:

```text
WaEngine: engine ready=true status={"linked":false,...}
WaEngine: engine event: qr
```

Capture:

```bash
HDC=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/toolchains/hdc
"$HDC" shell hilog | grep -E 'WaEngine|engine ready|engine event'
```

Acceptance:

- `engine ready=true`
- `status` is JSON
- a `qr` event arrives
- with the `.so` removed, the app still starts and logs the engine warning
  without crashing

## 8. First-error playbook

Send the **first** `error[E...]` or linker error. The likely classes:

- `aarch64-unknown-linux-ohos` std missing → nightly `build-std`.
- linker not found → `CARGO_TARGET_..._LINKER` and `CC_...` paths.
- `aarch64-unknown-linux-ohos-clang` cannot execute → wrong-arch SDK; use the
  SDK matching `uname -m`.
- C dependency build failure → `CMAKE_TOOLCHAIN_FILE`, `CC/CXX/AR`, sysroot.
- OOM / `signal: 9` → swap, `CARGO_BUILD_JOBS=1`,
  `CARGO_PROFILE_RELEASE_LTO=false`.
- crates.io/network failure → proxy or vendor dependencies.

## 9. Notes

- The integrated engine is a full Linux VM, so it can run the compiler and
  cargo. It is not the HarmonyOS ArkTS runtime.
- Starting the engine creates a separate WhatsApp companion session; test with
  a secondary account if you do not want to disturb the main one.
- The HAP still needs signing; Phase 0 only proves the artifact and engine
  lifecycle.
- Do not commit `libwa_engine.so`; it is a build artifact and is
  architecture-specific.
