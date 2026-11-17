# Native Route — Implementation Plan

Status: future plan. Path A (native chrome + visible WhatsApp Web) remains the
shipping fallback while this is built behind a feature flag.

## 1. Objective

A native ArkUI WhatsApp client for HarmonyOS that does not depend on a hidden
WebView, DOM scraping, WhatsApp Web Store injection, or a PC bridge.

Core promise:

- native QR / phone-code / passkey linking
- native chat list and conversation
- native send, reply, reactions and read receipts
- native media
- native calls when the call stack is ready
- WebView used only as an explicit fallback for unsupported passkey or call
  flows, never as the data source

## 2. Current assets

| Layer | File | State |
|---|---|---|
| Protocol | `server/` + `whatsapp-rust 0.7` | QR, pair code, history sync, messages, receipts, passkey callback, calls slice |
| C ABI | `engine/src/lib.rs` | start/stop/status/chats/messages/send, pair code, logout, passkey |
| NAPI | `entry/src/main/cpp/wa_bridge.cpp` | full declared surface |
| ArkTS wrapper | `entry/src/main/ets/services/WaEngine.ets` | typed calls + event callback |
| Native link UI | `NativeLinkView.ets` | QR/phone/code state machine, currently Web-backed |
| Native models | `ChatItem`, `MessageItem` | used by native shell |
| Native UI | `ChatsPane`, `ConversationView`, `HybridShell` | ready for real data |
| Store | `server/src/state.rs`, `store.rs`, `history.rs` | SQLite chats/messages/media refs |
| Calls | `server/src/calls.rs` | signaling/media relay foundation |

### Missing or stubbed

- No `libwa_engine.so` artifact yet. This is the hard gate.
- `wa_engine_send_media` — stub.
- `wa_engine_send_reply` — stub.
- `wa_engine_react` — stub.
- `wa_engine_media_path` — stub.
- `wa_engine_call_*` — stubs.
- `wa_engine_mark_read` only updates the local store; verify network receipt.
- No avatar/profile-picture pipeline.
- No native passkey credential provider; callback exists, UI bridge does not.
- `NativeLinkView` still consumes the WebView bridge, not `WaEngine` events.

## 3. Target architecture

```
ArkUI
├── NativeLinkView        QR string / pair code / passkey
├── ChatsPane             WaEngine.chats()
├── ConversationView      WaEngine.messages()
├── MediaViewer           sandbox file media
└── CallSurface           native call state

WaEngine.ets              typed NAPI wrapper, UI-thread event dispatch
        │
wa_bridge.cpp             NAPI, TSFN event callback
        │
libwa_engine.so           C ABI, Tokio runtime
        │
whatsapp-rust             Noise/Signal, history, media, calls, passkey
        │
SQLite + media dir        app sandbox
```

Rule: every native screen reads from `WaEngine` or the local store. No DOM,
no hidden WebView, no `window.__waNative`.

## 4. Phases and gates

### Phase 0 — Build gate

Deliverable: `libwa_engine.so` for `aarch64-unknown-linux-ohos`.

- Run `build-wa-engine` in GitHub Actions.
- Fix the first compiler error; do not change the public C ABI unless necessary.
- Package into `entry/libs/arm64-v8a/libwa_engine.so`.
- Build the HAP and verify `WaEngine.isReady() === true`.

Acceptance:

- `wa_engine_start()` returns `0`.
- `wa_engine_status()` returns JSON.
- A QR event reaches ArkTS.
- App does not crash when the engine is absent.

Blockers: no Rust/OHOS toolchain locally. Use the Integrated Engine openEuler VM — see [PHASE0-OPENEULER.md](PHASE0-OPENEULER.md) — or CI/Linux host.

### Phase 1 — Native auth

Deliverable: native QR / phone-code / passkey linking.

- Switch `NativeLinkView` from `WhatsAppWebBridge` to `WaEngine` events:
  - `qr` → native `QRCode(qrString)`; do not use a data-URL image.
  - `pair_code` → native code card.
  - `linked` → shell.
  - `passkey_request` / `passkey_confirmation` / `passkey_error` → native states.
- `status()` supplies linked/phone/qr on cold start.
- Persist session; logout clears it.

Acceptance:

- Link a phone by QR and by 8-character code.
- Cold start goes straight to native chats when linked.
- No WebView visible in the normal path.
- Passkey flow either completes natively or shows an explicit PC-bridge fallback.

### Phase 2 — Native chat list

Deliverable: real `ChatItem[]` from `wa_engine_chats()`.

- Map: id, name, preview, time, unread, pinned, group, channel, archived, muted.
- Avatar: profile-picture request + disk cache; initials fallback.
- Local search, unread filter, pin ordering.
- History-sync completion triggers a list refresh.

Acceptance:

- Real chats appear within 2 s of link/start.
- Unread/pin state matches WhatsApp.
- No placeholder/sample chats when linked.

### Phase 3 — Native conversation and actions

Deliverable: real `MessageItem[]` plus send/reply/reaction/read.

- `wa_engine_messages(chat, limit)`; pagination and older-message loading.
- Send: optimistic bubble, server id reconciliation, failure/retry.
- Reply: implement `wa_engine_send_reply`.
- Reactions: implement `wa_engine_react`; show reaction chips.
- Read receipts: verify `wa_engine_mark_read` sends the network receipt.
- Receipt/typing/presence events update the open thread.
- Day separators, quoted messages, sender names in groups.

Acceptance:

- Send from native appears on the phone.
- Incoming message appears without reopening the chat.
- Ticks match sent/delivered/read.
- Reactions and replies round-trip.

### Phase 4 — Native media

Deliverable: image/video/audio/document without WebView.

- Implement `wa_engine_send_media`.
- Implement `wa_engine_media_path`.
- Download and decrypt incoming media into the app sandbox.
- Native `Image`, `Video`, audio and document cards.
- Thumbnail cache, full-screen viewer, share/save.
- Upload progress for outgoing media.

Acceptance:

- Image opens natively.
- Video plays natively.
- Document opens/saves.
- Media survives restart via the sandbox cache.

### Phase 5 — History, contacts and app state

Deliverable: a complete local mirror.

- Apply history sync into SQLite.
- Lazy-load older messages and search.
- Contacts, groups, channels, communities.
- Mute, pin, archive, read state sync.
- Notification pipeline and badge counts.

Acceptance:

- Search works offline over synced history.
- App-state changes survive restart and sync to the phone.

### Phase 6 — Passkey

Deliverable: automatic native passkey linking.

- Wire `CallbackAuthenticator` options to a native credential provider.
- Prefer the HarmonyOS system passkey/credential manager.
- Fall back to the PC bridge only when the device cannot complete WebAuthn.
- Remove manual IP/token UI from the normal flow.

Acceptance:

- A passkey-protected account links without a WebView or manual bridge setup.
- Cancellation and error states are handled.

### Phase 7 — Calls

Deliverable: native voice/video calls.

- Implement `wa_engine_call_start/accept/reject/end/mute/camera`.
- Use the `server/src/calls.rs` signaling/media foundation.
- Integrate HarmonyOS audio/video capture and playback.
- Native in-call surface, mute, camera, speaker, duration.
- Until this lands, calls can remain an explicit WebView fallback.

Acceptance:

- Voice call connects and audio flows both ways.
- Video call connects; camera/mute work.
- Incoming call rings natively.

## 5. Feature flag and migration

Add:

```ts
nativeEnabled: boolean
```

Selection:

```
if (nativeEnabled && waEngine.isReady() && engineLinked) -> native shell
else -> Path A hybrid WebView
```

Do not remove Path A until:

- native link, chat list, conversation, send, media and reconnect are stable,
- crash-free sessions are acceptable,
- passkey/calls have a clear fallback.

This keeps a working app while the engine is unfinished.

## 6. Immediate next five tasks

1. Build the engine artifact in CI.
2. Smoke-test `start/status/QR` through `WaEngine`.
3. Switch `NativeLinkView` to `WaEngine` QR/pair-code events.
4. Render real `WaEngine.chats()` in `ChatsPane`.
5. Render real `WaEngine.messages()` and send a text message.

Everything else is blocked on those five.

## 7. Engineering rules

- Pin `whatsapp-rust` and keep protocol calls behind an adapter.
- Keep the C ABI stable; add fields, do not repurpose names.
- All engine calls return JSON; ArkTS parses into explicit models.
- Never block the UI thread; events hop to ArkUI.
- Store message ids as the reconciliation key.
- Media is file-based in the sandbox, not base64 in the model.
- Security: keys and session material stay in the app sandbox; use HUKS for
  long-term secrets; encrypt the local database where possible.
- Log engine event types, not message contents.

## 8. Risks

| Risk | Mitigation |
|---|---|
| `whatsapp-rust` API changes | pin version, adapter layer, CI compile gate |
| OHOS Rust target unavailable | CI Docker + OHOS SDK, cache artifact |
| Passkey unsupported on device | PC bridge fallback, explicit state |
| Calls take longer than chat | keep WebView call fallback |
| Account risk | personal-use scope, no bulk automation |
| Media decryption complexity | reuse `server/src/media.rs` and `history.rs` |
| History sync size | lazy load, pagination, local search |
| Large binary | release LTO/strip, size budget |

## 9. Definition of done

- No hidden WebView on the normal path.
- Real chats/messages appear from the engine.
- Sending, replies, reactions and receipts work.
- Media works natively.
- QR, phone code and passkey linking work.
- Calls either work natively or have an explicit, documented fallback.
- Path A can be disabled without losing account access.

## 10. Non-goals for the first native release

- Full ZapFast-style UI parity.
- Desktop-class multi-window.
- All WhatsApp Business features.
- Importing old WebView data.
- Replacing the official apps.

## 11. Current fallback

Until Phases 0–3 are complete, `HybridShell` is the shipping app:

- native header/tabs/settings,
- visible WhatsApp Web for Chats,
- native sample Chats/Conversation toggle for layout validation,
- one-pane phone adapter with slide navigation.

That fallback is intentional, not a temporary hack to be removed before the
engine works.
