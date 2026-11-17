# Build and install without DevEco Studio

GitHub Actions can build both the Rust engine and the HAP on Linux. DevEco
Studio is not required. Signing credentials are required; they are certificates,
not an IDE.

## One-time: get signing material

You need:

- a `.p12` keystore,
- the matching `.cer` certificate,
- a `.p7b` provisioning profile,
- the key alias and the two passwords.

Ways to get them without DevEco Studio:

1. **Huawei AppGallery Connect** → your app → **Certificates, APP IDs & Profiles**
   → create a debug/release certificate and a provisioning profile, then
   download the `.cer`, `.p7b`, and `.p12`.
2. If the project was previously signed on this machine, copy the files named
   in `build-profile.json5` from `~/.ohos/config/` once. Do not commit them.

Base64-encode each file and store them as GitHub Actions secrets:

```bash
base64 -w0 key.p12 > key.b64
base64 -w0 cert.cer > cert.b64
base64 -w0 profile.p7b > profile.b64
```

Secrets: `SIGNING_KEY`, `SIGNING_CERT`, `SIGNING_PROFILE`, `KEY_ALIAS`,
`KEY_PASSWORD`, `KEYSTORE_PASSWORD`.

## Build in GitHub Actions

Push the repository, then run **Actions → build-all → Run workflow**.

It has two jobs:

1. **engine** — builds `libwa_engine.so` for `aarch64-unknown-linux-ohos`.
2. **hap** — downloads the engine, builds the HAP, signs it with
   the SDK’s `hap-sign-tool` if the signing secrets exist, and uploads
   `whatisit-hap`.

No Windows VM and no DevEco Studio are involved.

## Install the signed HAP

Download the `whatisit-hap` artifact and install from any machine with `hdc`:

```bash
hdc install entry-default-signed.hap
```

The engine `.so` is already inside the HAP; no separate server is needed.

## If the HAP is unsigned

Without signing secrets the workflow uploads the unsigned HAP. A stock
HarmonyOS device will not install it. Add the signing secrets, rerun, and install
the signed artifact.

## Notes

- The signing profile must include the target device UDID for debug installs.
- `build-profile.json5` still has a local `signingConfig` pointing at
  `~/.ohos/config`; on CI that path is absent, so `assembleHap` produces the
  unsigned HAP and the workflow signs it explicitly.
- The `build-all` workflow uses the `harmonyos-ci-image` container for
  `hvigorw`/`ohpm`; pin its tag for reproducible builds instead of `latest`.
