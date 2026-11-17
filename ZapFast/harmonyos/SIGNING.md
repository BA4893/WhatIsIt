# Signing

HarmonyOS identifies an installed app and its updates by its signing
certificate. Regenerating the certificate makes a build that device and
AppGallery Connect treat as a different app. Keep one key pair for the life of
the app.

## What has to stay the same

| Material | Keep it | Can it be re-issued? |
| --- | --- | --- |
| Keystore (`.p12`), key alias, passwords | Back it up; losing it blocks updates | No |
| Release certificate (`.cer`) | Yes, or renew it from the same key | Yes, from the same key pair |
| Release profile (`.p7b`) | Yes | Yes, from the same certificate and bundle |
| Debug certificate and profile | Only for development | Yes, but it is device-bound and not for AppGallery |

Two rules matter most:

1. The **private key** in the `.p12` must not change. A new key means a new
   signing identity.
2. The **bundle name** must not change. It is `rocks.zapfast.harmony` here.

Profiles expire and can be replaced. A new profile with the same certificate
and bundle keeps the app identity; a new certificate does not.

## Set up release signing once

1. In DevEco Studio, open **Build > Generate Key and CSR**. Create a keystore
   and a CSR. Back up the `.p12`, the alias, and both passwords. This is the
   one key pair the app will use for all releases.
2. In AppGallery Connect, open the app's **Certificates** page and upload the
   CSR. Download the resulting release certificate (`.cer`).
3. On the **Profiles** page, create a **release** profile for
   `rocks.zapfast.harmony`, select that certificate, and download the profile
   (`.p7b`).
4. In DevEco Studio, open **Project Structure > Signing Configs**, turn off
   automatic signing, and add a configuration named `release` with the `.p12`,
   `.cer`, `.p7b`, alias, and passwords. Select it for the `default` product,
   or for the release build.
5. Build a release App and upload the `.app` package to AppGallery Connect.
   Debug-signed packages are not accepted.

Keep the signing material outside the repository. A convenient layout is a
private folder such as `~/.ohos/zapfast-signing/`; alternatively use
`harmonyos/signing/`, which is gitignored, but never commit the files.

## Stop the "Generate Signing Files" loop

DevEco Studio's automatic signing creates a **debug** certificate and a debug
profile whose device list names the connected devices. It is disposable by
design: regenerate it and the certificate changes, which is why a reinstall can
fail with "Metadata validation failed".

For day-to-day development:

- Generate the debug signing files once and keep them. Do not click **Generate
  Signing Files** again unless the profile has actually expired or you need to
  add a device.
- For a new device, update the debug profile's device list in AppGallery
  Connect and download the new `.p7b`; the certificate and key stay the same.
- If an install complains about signing, uninstall the old app once rather than
  generating a new key.

The automatic debug configuration is not suitable for AppGallery Connect.
Release builds must use the release certificate and release profile above.

## Renewals

- **Profile expired:** create a new profile with the **same certificate** and
  bundle name, download it, and replace the `.p7b` in the signing config.
- **Certificate expiring:** renew it using a CSR made from the **same** `.p12`
  (for example with `openssl req -new -key`), so the public key and signing
  identity stay the same. Do not generate a new key pair.
- **Key lost:** back up the `.p12` in at least two places. Without the private
  key you cannot update the published app under the same identity; recovering
  it is an AppGallery Connect support process, not a rebuild.

## CI

`build-profile.json5` stores the signing paths and machine-encrypted passwords.
That is convenient for a local DevEco Studio build, but it is not portable
across machines or suitable as a repository secret. For CI, keep the `.p12`,
`.cer`, `.p7b`, and passwords in the CI secret store and sign with
`hap-sign-tool` after the build, or provision a dedicated build machine whose
DevEco signing configuration is created from those secrets. Do not commit any
of the files or the plain passwords.

## The current configuration

The `signingConfigs` block in `harmonyos/build-profile.json5` currently holds a
`default` configuration that DevEco Studio generated automatically
(`keyAlias: debugKey`, paths under `~/.ohos/config`). It is a debug
configuration for this machine. Keep using it for local runs, but add the
`release` configuration above and select it for AppGallery builds instead of
uploading a debug-signed package.
