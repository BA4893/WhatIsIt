# ZapFast → HarmonyOS rewrite

**Goal:** a native, fast WhatsApp client for HarmonyOS PC, with the same app
running on phones and MatePad tablets. No browser engine, no hosted backend.

**Reference product:** [ZapFast](https://github.com/crmne/zapfast)
(MIT, Rust + egui + `whatsapp-rust`). It is a desktop app; its UI and platform
glue are not portable to HarmonyOS. Its protocol engine and product behaviour
are the reusable parts.

## Why this is a rewrite, not a port

| ZapFast component | HarmonyOS reality |
|---|---|
| egui / eframe / fastframe UI | No ArkUI equivalent; must be rewritten in ArkTS |
| `whatsapp-rust` protocol engine | Reusable in principle; must be cross-compiled for HarmonyOS and exposed through NAPI |
| SQLCipher archive + keyring | SQLCipher can be cross-compiled; keyring must use HarmonyOS asset store |
| fastframe-audio, rodio, openh264, sonus | HarmonyOS AudioKit / AVCodec / camera APIs; new I/O layer |
| Tray, global shortcuts, updater, file pickers | HarmonyOS window/notification/picker APIs |
| Multi-account, archive, calls, stickers | Product behaviour to reimplement in the new UI/engine |
| Passkey/SHORTCAKE | **Not present in ZapFast**; must be added for gated accounts |

ZapFast is roughly 130k lines of Rust. The UI alone is 26 modules. A literal
one-shot rewrite is not realistic; the work must be gated by an engine spike.

## Recommended architecture

```
ArkTS / ArkUI shell (phone · tablet · PC)
  │  Chats · Calls · Settings · account switch · media UI
  ▼
WaEngine NAPI surface (the existing `services/WaEngine.ets` shape)
  │  start/stop, QR, pair code, chats, messages, send, media, calls
  ▼
libwa_engine.so — Rust, built from whatsapp-rust
  │  protocol, SQLCipher archive, history sync, Voip
  ▼
HarmonyOS AudioKit / AVCodec / Camera / Asset store
```

- The ArkTS shell is a new ZapFast-inspired design, not a QML/egui port.
- The engine is `whatsapp-rust` (MIT), built for HarmonyOS; this is the
  gating technical risk.
- Until the engine spike works, the current `server-go` path remains the only
  way to show live data; the new UI must not be built against a mock protocol.

## Form factors

| Device | Layout |
|---|---|
| Phone | One pane; bottom navigation (Chats, Calls, Settings); chat opens full screen |
| MatePad / tablet | Two panes: chat list + conversation; rail for Calls/Settings |
| PC / 2-in-1 | Three columns: ZapFast-style rail, chat list, conversation; keyboard shortcuts, resizable window, min width |

The same ArkTS components use breakpoints; no separate apps.

## Phase plan and gates

### Phase 0a — HTTP engine validation (gate)
- Build and run the existing `server/` Rust `whatsapp-rust` backend on a
  Linux/Windows PC or VPS. It already exposes `/status`, `/pair`,
  `/pair-code`, `/chats`, `/messages`, `/send`, `/call/*` and `/passkey/*`,
  matching the app's `CdpBridge`.
- Point the app's **Live engine** at it; verify QR/phone linking, chats,
  send, calls and passkey.
- **Gate:** one real account works end-to-end through the HTTP engine.

### Phase 0b — NAPI extraction (gate)
- `server/src` now has a library target; `engine/` implements the C ABI in
  `wa_bridge.cpp` and reuses the same protocol/state/event code.
- `.github/workflows/build-engine.yml` builds `libwa_engine.so` for
  `aarch64-unknown-linux-ohos`; the artifact can be dropped into
  `entry/libs/arm64-v8a/` (CMake also accepts the local
  `engine/target/...` path).
- **Gate:** the same account links and a message round-trips through NAPI on
  the device. If this fails, stop; do not rewrite the UI.

The HTTP server is a validation harness, not the final architecture. It uses
the same protocol engine and produces the JSON fixtures the NAPI layer must
match.

### Phase 1 — shell and core chat
- New ArkUI shell with phone/tablet/PC layouts.
- Chats, conversation, send/receive, receipts, media placeholders.
- Archive schema from ZapFast's `archive.rs` (chats/messages/contacts).
- **Gate:** daily-driver text chat on all three form factors.

### Phase 2 — media and history
- Images, files, voice notes, stickers, GIFs, video playback.
- History backfill and encrypted archive.
- Media cache and permissions.

### Phase 3 — calls
- `whatsapp-rust` Voip signaling and media.
- HarmonyOS AudioKit capture/render, AEC (port ZapFast's sonora pipeline if
  feasible), camera/AVCodec video.
- Call state machine from ZapFast's `calls.rs`; incoming/outgoing/missed.
- **Gate:** two-way voice call on a phone; then video.

### Phase 4 — product parity
- Multi-account, notifications, app lock, themes, settings, search, labels,
  favorites, polls, reactions, edits/revokes, groups/channels, privacy.
- Passkey/SHORTCAKE linking for gated accounts.

### Phase 5 — polish
- Performance (startup, memory, scrolling), accessibility, i18n, update path,
  crash diagnostics.

## Non-goals / boundaries

- No egui, fastframe, QML, Sailfish or server-go code in the final app.
- No browser WebView as the primary client.
- No hosted backend or telemetry.
- Do not copy ZapFast's GPL notification sounds without complying with their
  license; use licensed or original sounds.

## Cangjie option

Cangjie can replace **code we write** (native modules, a NAPI/FFI layer, even
UI logic), but it does **not** replace the missing WhatsApp protocol engine.
There is no Cangjie WhatsApp library; `whatsapp-rust` is Rust, and calling it
through FFI still requires a built `libwa_engine.so`.

A Cangjie engine would mean implementing, from scratch:

- Noise handshake, Curve25519/AES-GCM, Signal X3DH and double ratchet;
- WhatsApp protobuf schemas, binary nodes, WebSocket transport;
- QR/phone pairing, history sync, media encryption/download;
- passkey/SHORTCAKE, VoIP signaling, MLow/Opus and video;
- an encrypted archive and key storage.

That is a multi-month protocol project with no upstream Cangjie implementation,
and it is larger than the Rust toolchain problem it tries to avoid. The Cangjie
compiler is also not present in this SDK.

**Conclusion:** Cangjie is not a shortcut around Rust for the engine. If the
requirement is “no Rust build host”, the realistic options are a prebuilt
Rust `.so` from CI/another machine, or the HTTP engine as an interim; if the
requirement is “no Rust in the product at all”, that is a separate Cangjie
protocol project, not a quick pivot.

## Decisions

1. **Full native rewrite.** The final app uses the Rust engine through NAPI,
   not `server-go` or a hosted backend.
2. **Passkey belongs in the new engine.** The C ABI already exposes the
   `passkey_*` functions; `whatsapp-rust`'s `CallbackAuthenticator` drives it.
3. **Voice-first.** Video follows the voice gate unless it is declared a launch
   requirement.
4. **Replace the ArkTS shell** with the ZapFast-inspired ArkUI described in
   `SHELL-SPEC.md`, after the engine gate; keep the current shell runnable until
   the replacement compiles.

**Recommendation:** run Phase 0 before changing the UI. The engine is the
make-or-break item; the UI is a large but known rewrite.
