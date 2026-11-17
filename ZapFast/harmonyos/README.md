# ZapFast on HarmonyOS

ZapFast's desktop build is Rust, egui and eframe. HarmonyOS has no eframe or
winit backend, so this directory hosts the same application in an ArkUI
`XComponent` instead of a desktop window: one Rust library creates an EGL
surface from the component's native window, paints the real `zapfast::app::App`
with `egui_glow`, and feeds it the touch, mouse, wheel and keyboard events
ArkUI reports. The interface, its state, its archive and its protocol client
are the desktop's, not a reimplementation in ArkTS.

That is the difference from a rewrite: the phone, tablet and PC builds run the
same views as the desktop build, with the narrow-window layout ZapFast already
has (one pane on a phone, rail and two columns on a 2-in-1), and the same
WhatsApp engine.

## Layout

```
harmonyos/                 the HarmonyOS application project (open this in DevEco Studio)
  AppScope/                bundle identity, icon, name
  entry/                   the entry HAP
    src/main/cpp/          the NAPI module and XComponent bridge (C++)
    src/main/ets/          EntryAbility and the XComponent page
  build-profile.json5      the HarmonyOS product and the entry module
  rust/                    the Rust host (zapfast-ohos, static library)
    src/egl.rs             EGL display, window/pbuffer surfaces, GLES 3
    src/host.rs            the frame loop, surface lifecycle, event queue
    src/input.rs           ArkUI events to egui RawInput events
    src/fonts.rs           HarmonyOS Sans as egui fallbacks
    src/bin/ohos-shot.rs   offscreen screenshots of the real screens
  keyring/                 the archive key store (private sandbox file)
  platform/                per-crate desktop/ HarmonyOS facades (see below)
  build.sh                 builds the Rust host and the HAP
```

Open `harmonyos/` itself in DevEco Studio, the folder that contains
`build-profile.json5` and `hvigorfile.ts`. Opening the repository root or a
parent folder is what makes DevEco say "Select a HarmonyOS project": the
project model lives here, not one level up.

The NAPI surface is small: `start`, `stop`, `text`, `paste`, clipboard and URL
polling, the soft-keyboard wish, density and focus. Surface and input events go
straight from the native XComponent callbacks to the Rust host, so touch and
mouse never cross the JavaScript boundary.

## Why the platform crates

Four desktop crates assume a Linux, Windows or macOS platform layer:

| Crate | Desktop | HarmonyOS |
|---|---|---|
| `fastframe-shell` | eframe window, tray-driven window recreation | the XComponent owns the window; this project's frame loop |
| `fastframe-titlebar` | drawn caption buttons, traffic-light alignment | the system draws the frame; zero caption room |
| `fastframe-dock` | launcher badge, Dock icon | the launcher owns the badge; the stand-in remembers the count |
| `fastframe-audio` | PipeWire/PulseAudio/ALSA/CoreAudio/WASAPI | silent until OHAudio is bound (see below) |
| `arboard` | X11/Wayland clipboard | text copy/paste through egui and the ArkTS pasteboard bridge |
| `rfd` | native file dialogs | ArkUI pickers, once bridged; cancelled dialogs until then |
| `openh264` / `openh264-sys2` | openh264 | stand-in until AVCodec is bound |

Each lives in `harmonyos/platform/`. On every desktop target the crate re-exports
the pinned upstream dependency unchanged, so Linux, macOS and Windows builds
still use the real crates. On HarmonyOS the module beside it provides the same
names with HarmonyOS behaviour. No dependency source is copied, and no fork is
used; the desktop dependency sources are exactly the ones `Cargo.toml` pinned
before the port.

Rust's HarmonyOS target is `aarch64-unknown-linux-ohos`, which reports
`target_os = "linux"` **and** `target_env = "ohos"`. Every gate in this
directory is on `target_env`, which is the only thing that tells HarmonyOS
from a desktop Linux.

## Build

A HarmonyOS PC with the `hmos-clt` command-line tools and the
`aarch64-unknown-linux-ohos` Rust toolchain:

```sh
# once, if the tools are in the usual places
export HMS_CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0
export RUST_ROOT=$HOME/rust-ohos/rust-1.95.0-aarch64-unknown-linux-ohos

./harmonyos/build.sh            # debug HAP
./harmonyos/build.sh release    # release HAP
```

`build.sh` builds the Rust host as a static library, copies it into
`harmonyos/entry/libs/arm64-v8a/`, installs the app's package dependencies and
runs `hvigorw assembleHap`. The product's `runtimeOS` is `HarmonyOS` in
`harmonyos/build-profile.json5`, and the built HAP reports
`"compileSdkType": "HarmonyOS"`. The SDK keeps its OpenHarmony base under
`sdk/default/openharmony` (the NDK, `hdc` and the signing tools live there),
which is why that path appears in the tool commands; it is not the app's
runtime. The result is
`harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap`.

The app's `build-profile.json5` turns off `strictMode.caseSensitiveCheck`: the
ArkTS compiler verifies every ancestor directory's spelling by listing it, and
a build account whose home it cannot list (a sandbox, CI, a restricted work
account) fails with `EPERM` on the way to `/`. The project's own paths are
lowercase and fixed, so the check adds nothing here.

### Building in DevEco Studio

DevEco Studio builds the ArkTS side and the C++ bridge, but it does not run
Cargo. Before the first IDE build, run `./harmonyos/build.sh` once on a machine
with the `aarch64-unknown-linux-ohos` Rust toolchain: it leaves
`harmonyos/entry/libs/arm64-v8a/libzapfast_ohos.a` in place, and DevEco Studio
then builds, signs and runs the project as usual. That library is a build
artifact and is gitignored, so a fresh checkout has none; the IDE's native step
stops with "libzapfast_ohos.a missing and no known rule to make it" until it is
built. If the file lives elsewhere, point the CMake cache variable
`ZAPFAST_RUST_LIB` at it instead.

An app installed from a differently signed HAP cannot be updated in place.
HarmonyOS ties the install to its signing certificate, so uninstall the old
copy before installing a build signed with new material; otherwise the deploy
step can fail with "Metadata validation failed". The same applies when moving
from a test-signed HAP to DevEco Studio's own signing.

The HAP must be signed before a commercial HarmonyOS device installs it. Use
the SDK's `hap-sign-tool` with your own certificate and provisioning profile,
or open `harmonyos` in DevEco Studio and let it sign with its automatic
signing. The bundle id here is `rocks.zapfast.harmony`.

DevEco Studio's automatic signing is a **debug** identity and is not accepted
by AppGallery Connect. For a stable release identity, a release certificate,
profile renewals, and the "Generate Signing Files" loop, see
[SIGNING.md](SIGNING.md).

```sh
"$SDK/default/openharmony/toolchains/lib/hap-sign-tool" sign-app \
  -keyAlias "<alias>" -signAlg "SHA256withECDSA" -mode "localSign" \
  -appCertFile "<certificate.cer>" -profileFile "<profile.p7b>" \
  -inFile "harmonyos/entry/build/default/outputs/default/entry-default-unsigned.hap" \
  -keystoreFile "<keystore.p12>" -outFile "zapfast-signed.hap" \
  -keyPwd "<key password>" -keystorePwd "<keystore password>" -signCode "1"
```

The SDK also ships OpenHarmony's own reference material
(`toolchains/lib/OpenHarmony.p12` and `.pem` files) for OpenHarmony devices;
a HarmonyOS phone, tablet or PC needs a HarmonyOS certificate and a profile
that names your bundle, issued through AppGallery Connect.

### Offscreen screenshots

The `zapfast-ohos-shot` tool draws ZapFast's real screens into a PNG through
the same renderer, without ArkUI, so the port can be inspected on a machine
where the HAP cannot be installed:

```sh
cargo run --release -p zapfast-ohos --features demo \
  --bin zapfast-ohos-shot -- \
  --size 1440x900 --density 1 --page chat --chat --out /tmp/zapfast.png
```

## Status

Working:

- the real interface, all pages, dialogs and offline demo screens;
- the WhatsApp engine (`whatsapp-rust`), the SQLCipher archive, the session
  store and history sync, compiled in through the same `Account`/`Backend`
  code as the desktop, so the app starts the same link. Linking and delivery
  were not exercised against WhatsApp from this build environment (no account
  to link), so that part is compiled and started, not proven;
- EGL/GLES 3 rendering of egui, including the frosted-header GL callback;
- surface creation, resize, destroy, foreground/background, focus and density
  changes;
- touch, mouse, wheel and hardware-keyboard input, with the same shortcuts;
- text copy through egui to the ArkTS pasteboard; reads from it on paste wait
  for a way to ask for `READ_PASTEBOARD` (a system permission) or a
  `PasteButton`;
- system fonts (HarmonyOS Sans and HarmonyOS Sans SC) as egui fallbacks;
- the archive key in a private file in the app sandbox.

Not bound yet, and reported honestly in the app rather than faked:

- **Audio**: the `fastframe-audio` stand-in paces frames and records silence.
  Voice messages play silently and recording captures nothing. OHAudio
  (`libohaudio.so`, in the NDK) is the next piece; ZapFast's `audio` and
  `call_audio` layers then work unchanged.
- **Video codecs**: H.264 encode/decode through openh264 is unavailable
  because `openh264-sys2` has no HarmonyOS target. Video messages do not play
  and a call's camera sends nothing; the call itself is receive-only, the same
  path a camera that will not open takes. AVCodec's
  `OH_VideoDecoder`/`OH_VideoEncoder` is the next piece.
- **Soft keyboard and IME**: the XComponent asks for the soft keyboard when
  egui is editing text, and `keyText`/`unicode` are forwarded as text events,
  but IME composition has not been tested on a device. A dedicated ArkTS
  composer overlay is the fallback if the system input method does not commit
  text to the XComponent.
- **File pickers**: `rfd` answers a cancelled dialog; attachment, wallpaper
  and sticker picking need ArkUI's pickers and a result bridge.
- **Clipboard images and file lists**: text only.
- **Notifications and the launcher badge**: the Rust side keeps the counts;
  ArkTS has no notification or badge bridge yet.
- **Calls**: signaling and audio routing compile, but without audio or video
  codecs a call has nothing to send. Receive-only audio needs OHAudio.
- **Tray, auto-update, login item**: desktop-only in the product; the
  HarmonyOS build does not start them.

## Testing

- `cargo check --lib -p zapfast --target aarch64-unknown-linux-ohos
  --ignore-rust-version` checks the whole desktop library against the
  HarmonyOS target. The `--ignore-rust-version` is needed only because the
  device's Rust toolchain is older than the desktop manifest's advertised
  MSRV; anything that actually needs the newer compiler fails to compile.
- `cargo run ... --bin zapfast-ohos-shot` renders screens on the device.
- `cargo test -p zapfast-ohos` runs the host's own unit tests (input mapping).
- The desktop checks in `AGENTS.md` still apply to the desktop build; this
  machine only has the HarmonyOS toolchain, so the port's own checks were run
  here and the desktop builds were not.
