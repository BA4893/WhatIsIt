# Terminal build on HarmonyOS PC (no Windows VM)

Everything can run from the DevEco/HiShell zsh terminal on the HarmonyOS PC.
DevEco Studio is not required for the build steps; it is only the source of your
signing credentials.

Assumption: the project is at
`/storage/Users/currentUser/Documents/DevEcoStudioProjects/WhatIsIt-main/WhatIsIt-main`.

## 0. Set the tool paths

```zsh
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/WhatIsIt-main/WhatIsIt-main

export NODE_HOME=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/node/bin
export PATH="$NODE_HOME:$PATH"
export DEVECO_SDK_HOME=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk
export PROJECT_ROOT="$PWD"

HVIGOR=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/hvigor/bin/hvigorw
OHPM=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/ohpm/bin/ohpm
HDC=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/toolchains/hdc
SIGN_TOOL=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/toolchains/lib/hap-sign-tool
```

## 1. Build/download `libwa_engine.so`

GitHub Actions (no Windows VM):

1. Push the project to GitHub.
2. Run **Actions → build-wa-engine → Run workflow**.
3. Download `libwa_engine-ohos-arm64`.

Back in zsh:

```zsh
mkdir -p entry/libs/arm64-v8a
cp ~/Downloads/libwa_engine.so entry/libs/arm64-v8a/libwa_engine.so
```

Or use the helper:

```zsh
./scripts/install-engine.sh ~/Downloads/libwa_engine.so
```

## 2. Install dependencies (first build only)

```zsh
"$OHPM" install --all
```

## 3. Rebuild the HAP

```zsh
"$HVIGOR" clean --no-daemon
"$HVIGOR" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

The engine is linked by CMake from `entry/libs/arm64-v8a/libwa_engine.so` and
packaged into the HAP.

Outputs:

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
entry/build/default/outputs/default/entry-default-signed.hap
```

If `SignHap` fails with `EPERM ... .ohos/config/material`, the CLI user cannot
read DevEco's signing material. Use the DevEco **Build** action once, or sign
manually with your own material in step 4.

## 4. Sign from the terminal (if hvigor did not)

You need the `.p12`, `.cer`, `.p7b`, alias and passwords. The native
`hap-sign-tool` does not need Java/DevEco:

```zsh
"$SIGN_TOOL" sign-app \
  -keyAlias "<alias>" \
  -signAlg "SHA256withECDSA" \
  -mode "localSign" \
  -appCertFile "<cert.cer>" \
  -profileFile "<profile.p7b>" \
  -inFile "entry/build/default/outputs/default/entry-default-unsigned.hap" \
  -keystoreFile "<keystore.p12>" \
  -outFile "entry/build/default/outputs/default/entry-default-signed.hap" \
  -keyPwd "<key-password>" \
  -keystorePwd "<keystore-password>" \
  -signCode "1"
```

The SDK also ships OpenHarmony debug keys, but a HarmonyOS commercial device
needs a HarmonyOS/Huawei profile; do not assume the OpenHarmony profile installs.

## 5. Install

```zsh
"$HDC" list targets
"$HDC" install -r entry/build/default/outputs/default/entry-default-signed.hap
```

If no target appears, enable developer mode/USB debugging on the device and
authorize the PC.

## 6. Verify the engine loaded

```zsh
"$HDC" shell hilog | grep -E 'WaEngine|wa_engine|LinkDevice'
```

Expected: the engine loads; the link sheet uses NAPI instead of HTTP.
If it still says `wa_engine native not loaded`, the `.so` was not packaged or
the ABI load failed.

## Why not a Windows VM

`hvigorw`, `ohpm`, `hdc` and `hap-sign-tool` are Linux/HarmonyOS binaries in the
SDK. The only Windows-specific piece in this project is a stale
`server/.cargo/config.toml` path; it is irrelevant to the HAP build.

The unavoidable part is the engine artifact: it must be compiled by CI or
another trusted host first. The phone cannot compile Rust in this sandbox.
