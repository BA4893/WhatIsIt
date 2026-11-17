---
title: HarmonyOS
description: ZapFast on HarmonyOS PC and 2-in-1, tablets and phones, hosted in an ArkUI XComponent with the same Rust and egui interface.
nav_order: 6
seo:
  title: ZapFast for HarmonyOS
---

ZapFast runs on HarmonyOS PC and 2-in-1 devices, tablets and phones. The desktop
app is Rust and egui; on HarmonyOS it keeps the same interface, the same views
and the same WhatsApp engine, and only its window is different. The app is
hosted in a native ArkUI `XComponent`: an EGL surface made from the component's
native window is painted by `egui_glow`, so what you see is the application
itself, not a second interface written in ArkTS.

The one-pane phone layout, the rail-and-two-columns tablet and PC layout, the
keyboard shortcuts, the themes and every chat screen are the ones the desktop
draws. That is the point of using the XComponent: no browser engine, no
duplicate UI, no mock protocol.

## Install

There is no store build yet. Build the HAP from source on a HarmonyOS PC with
the command-line tools:

```sh
export HMS_CLT=/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0
export RUST_ROOT=$HOME/rust-ohos/rust-1.95.0-aarch64-unknown-linux-ohos
./harmonyos/build.sh
```

Then sign the unsigned HAP with the SDK's `hap-sign-tool` (your certificate and
provisioning profile), or open `harmonyos` in DevEco Studio and let it sign, and
install it with `hdc install -r <file>.hap`. The bundle id is
`rocks.zapfast.harmony`.

## What works

- The complete interface: chats, calls, settings, search, groups, polls,
  reactions, edits, stickers, themes, and the app lock, drawing through the
  same egui views as the desktop.
- The WhatsApp engine, the SQLCipher archive and the session store are the
  desktop's code, compiled into the HAP and started with the app. This build
  was checked against the offline sample chats; linking and message delivery
  were not exercised on a device yet, so treat them as untested here rather
  than broken or complete.
- Touch, mouse and wheel input, the hardware keyboard with ZapFast's
  shortcuts, window resizing and display density changes.
- Text copy through egui to the system pasteboard. Pasting into the composer
  is written through the ArkTS pasteboard bridge but needs a permission a
  normal app cannot hold, so it is a known gap rather than a working path.
- HarmonyOS Sans as the interface's fallback, so Chinese and other CJK text
  draws with the system's own typeface.

## What is not bound yet

These are missing platform bridges, not product decisions. The app says so
rather than pretending:

- **Sound.** The audio layer compiles against a stand-in that paces frames and
  records silence, so voice messages play silently and recordings are empty.
  OHAudio is the next piece; ZapFast's own audio and call layers then work as
  they do on the desktop.
- **Video codecs.** H.264 through openh264 has no HarmonyOS build; AVCodec
  (`OH_VideoDecoder` and `OH_VideoEncoder`) is the next piece. Video messages
  do not play, and a call's camera sends nothing, so a call is receive-only.
- **The soft keyboard and IME.** The XComponent asks the system for the soft
  keyboard while egui edits text, and committed text is forwarded to egui, but
  input-method composition has not been tested on a device yet.
- **File pickers.** Attaching files, choosing wallpaper and importing stickers
  need ArkUI's pickers and a result bridge.
- **Notifications and the launcher badge.** The counts are kept in Rust; the
  ArkTS side has no bridge for them yet.

The archive key is kept in a private file inside the app's sandbox until the
HarmonyOS asset store is bound.

## Building and testing

`harmonyos/README.md` in the repository describes the architecture, the build
script, the offscreen screenshot tool that draws the real screens without
ArkUI, and the per-crate adapters that keep the desktop platforms on their own
dependencies.

The desktop builds are unchanged: the HarmonyOS-specific crates exist only for
`aarch64-unknown-linux-ohos`, and every desktop target still uses the pinned
upstream dependencies.
