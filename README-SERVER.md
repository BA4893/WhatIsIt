# WhatIsIt — native protocol backend notes

> **Legacy architecture notes.** The current app is the design-led shell in
> [README.md](README.md). This document preserves the native protocol / server
> details used by the optional Live mode.

A HarmonyOS WhatsApp client. It has two modes:

- **Default (no server):** the app opens the real **WhatsApp Web** inside
  ArkWeb, so the user links with the normal QR code or the phone-number code.
  There is no backend host/port/token to configure. The home page is WhatsApp
  Web's chat list; the WebView stores the session across restarts.
- **Native protocol mode (optional):** a native ArkUI chat client whose session
  runs on a `whatisit-server` (always-on VPS) or the embedded Rust engine. This
  mode uses the server HTTP/WS contract below.

```
HarmonyOS device (WhatIsIt)
   native ArkUI: QR pairing screen → chat list → thread (native bubbles, media,
   reactions, delivery ticks, WhatsApp-native calls)
        │  HTTP: /status /pair /pair-code /passkey/* /chats /messages /send
        │        /send-media /read /react /logout /call/* /media/{id}/{kind}
        │  WS:   /ws push {qr, linked, message, receipt, chats, logged_out,
        │        incoming_call, passkey_request, passkey_confirmation} + binary
        │        media frames (audio PCM + H.264 video)
        ▼
whatisit-server (Go, whatsmeow + meowcaller) — WhatsApp Multi-Device protocol,
Signal E2EE, SQLite session store, keepalive + auto-reconnect, media cache,
1:1 voice/video calls, SHORTCAKE passkey linking
```

> **Backend**: `server-go/` is the current backend — a wire-compatible port of
> the original Rust `server/` (whatsapp-rust). It has been **live-validated
> end-to-end** (QR link, full-history sync, live messaging, persistence across
> restarts). The Rust `server/` is kept as the historical reference.

## How it works

1. The user opens the app — it shows a **QR code** (native ArkUI `QRCode`), or
   taps **Link with phone number instead** to get an 8-char code typed into
   WhatsApp.
2. WhatsApp → Linked Devices → Link a Device → scan (or enter the code).
3. If the account is in WhatsApp's **passkey cohort**, the server pushes a
   `passkey_request` event; the app completes the WebAuthn assertion (see
   "Passkey linking" below) and shows any verification code.
4. The app auto-routes to the chat list. Chats/messages come from the server
   over HTTP + WebSocket push (no browser, no DOM scraping).
5. The server keeps the socket alive (own keepalive + auto-reconnect), so the
   session survives indefinitely while the VPS is up — the app needs no
   keep-alive ping (battery win).

## Passkey linking (SHORTCAKE)

Meta's 2026 passkey device-link gate requires a WebAuthn assertion from a
passkey already registered to the account. `whatsmeow` implements the
handshake; the server bridges the app into it:

- WS `passkey_request {options}` — the `PublicKeyCredentialRequestOptions` JSON;
  the app runs a WebAuthn `get` and POSTs the assertion to `/passkey/assertion`.
- WS `passkey_confirmation {code}` — a verification code to show on the phone
  (fresh links).
- HTTP `/passkey/request`, `/passkey/assertion`, `/passkey/confirm`,
  `/passkey/cancel` — the app ↔ server seam.

> This SDK version has no Credential Manager / WebAuthn API, so the app's
> passkey card accepts a pasted assertion JSON as a developer fallback. Swap in
> a native `navigator.credentials.get` call in `PasskeyService.obtainAssertion`
> the moment `@kit` ships WebAuthn.

## Files

| File | Purpose |
|---|---|
| `server-go/` | Go backend (current): `config.go`, `auth.go`, `state.go`, `events.go`, `store.go`, `client.go` (whatsmeow wrapper), `media.go`, `extract.go`, `calls.go` (meowcaller relay), `web.go` (HTTP + WS + passkey + call endpoints), `ws.go` (WS + media relay), `parity_test.go` (wire-compat suite), `Dockerfile`, `deploy/`. |
| `server/` | Rust backend (reference, pre-migration): `main.rs`, `events.rs`, `state.rs`, `history.rs`, `store.rs`, `media.rs`, `web.rs`, `calls.rs`, `DEPLOY.md`. |
| `entry/src/main/ets/services/CdpBridge.ets` | The app's backend client (HTTP + WS + passkey + calls); keeps the page-facing API. |
| `entry/src/main/ets/services/PasskeyService.ets` | SHORTCAKE passkey ceremony orchestration (assertion submit/confirm/cancel). |
| `entry/src/main/ets/services/ServerConfig.ets` | Hidden backend host/port/token constants (no UI plumbing). |
| `entry/src/main/ets/pages/MainPage.ets` | QR pairing screen (QR + phone-code + passkey card) → chats → thread. |
| `entry/src/main/ets/pages/ChatListView.ets` / `ChatThreadView.ets` | Native chat list + thread (media, reactions, ticks, WhatsApp-native calls). |
| `entry/src/main/ets/pages/CallSurfaceView.ets` / `services/CallService.ets` / `CallAudio.ets` | WhatsApp-native call UI (XComponent surfaces, PiP) + media relay. |
| `entry/src/main/cpp/` | Native `call_media` module: OH_VideoEncoder/Decoder (H.264), NAPI bridge. |
| `entry/src/main/ets/services/MediaDownloader.ets` | Downloads `/media/{id}` into the private sandbox for native rendering. |

## Capabilities (honest)

| Feature | Status |
|---|---|
| QR pairing in-app (scan with phone) | ✅ live-validated |
| Phone-number 8-char code pairing + country code | ✅ (`/pair-code` + on-screen code with country prefix) |
| Provisioning QR (air-gapped / per-customer) | ✅ (`whatisit://provision` deep link + QR) |
| Passkey (SHORTCAKE) linking | 🟡 server + app flow done; on-device WebAuthn needs SDK Credential Manager (manual-paste dev fallback) |
| Chat list, 1:1 + group text | ✅ |
| Instant send, replies, reactions, mark-read | ✅ |
| Delivery / read ticks | ✅ (server receipt events → WS) |
| Media send + receive (image/video/audio/doc) | ✅ (cached server-side) |
| Full chat history at link | ✅ when you pick "full history" at pairing — history sync is ingested + persisted |
| History survives server restarts | ✅ auto-flush every 5s + flush on graceful shutdown (was previously lost) |
| Chronological message ordering | ✅ time-sorted store (order independent of arrival) |
| Older-history on-demand backfill | ✅ `/history/backfill` (WhatsApp Web's "scroll up" equivalent) |
| Persistent session (no re-link) | ✅ SQLite + server keepalive |
| Status tab (recent updates) | ✅ live status posts from `status@broadcast`; **ephemeral — not backfilled by history sync** |
| Channels tab | ✅ subscribed channels + channel directory (find/follow/unfollow) |
| Communities | ❌ not on the protocol surface |
| WhatsApp-native voice calls | 🟡 meowcaller bridge implemented + compiles; **not yet live-validated** |
| WhatsApp-native video calls | 🟡 H.264 via native `call_media` encode/decode; meowcaller video path unproven — test after voice |

## Sync & history (how it works now)

- **History arrives from the phone, not the server.** WhatsApp only pushes a
  `HistorySync` when a device is linked and you choose how much to include
  (24h / 6 months / full). There is no server-side "fetch all history" API in
  this whatsmeow build, so:
  - to get the full backlog, **re-link and pick "full history"** at pairing;
  - `server-go/history.json` is written from whatever the phone sent, and the
    linked-device QR code is shown in-app whenever the server is unlinked.
- **Ordering is chronological.** Messages are inserted time-sorted (deduped by
  ID), so chat previews, threads and the chat list stay correct no matter what
  order the phone delivers them in.
- **Everything persists.** The store auto-flushes every 5s (and on shutdown),
  so live messages survive a crash/restart — previously they were lost.
- **Full history is served.** `/messages?chat=` returns the whole stored thread
  by default (up to a 5,000-message cap), optional `limit=`.
- **Older messages can be walked back on demand.** `POST /history/backfill
  {chat, count}` asks the phone for messages older than the oldest one the
  server holds (the same peer-data mechanism WhatsApp Web uses when scrolling
  up). The reply arrives as a normal history sync and is ingested into the
  store.
- **Statuses are live-only.** Status posts arrive as ephemeral messages in
  `status@broadcast`; the phone does not include them in history sync. The
  Status tab shows posts that happen while the server is connected, plus any
  `status@broadcast` messages present in a history sync (they are ingested as
  the latest per contact).

## Testing done vs. what the emulator cannot test

**Done on the HarmonyOS emulator (+ a real WhatsApp account):**
QR link with full-history sync (22 conversations / 4,154 messages ingested and
served time-ordered), live messaging, persistence across server restarts,
chats/channels/status rendering, backfill request handshake.

**Cannot be validated on the emulator — needs a real device:**
- WhatsApp-native voice/video calls end-to-end (meowcaller signalling, H.264
  encode/decode, PiP, camera/mic capture) — the bridge compiles but is unproven.
- On-device passkey WebAuthn (the SDK has no Credential Manager; the app falls
  back to pasting a JSON assertion).
- System push notifications while the app is backgrounded/killed.
- Real hardware battery/keepalive behaviour and screen-off behaviour.
- Large-scale media (multi-GB transfers, GPU-accelerated rendering of many
  videos), and scrolling very long threads (10k+ messages).
- SMS/phone-number 8-char pairing against a live SIM on a physical handset.

## Backends

### server-go (current)
Wire-compatible port of the original Rust `server/` to **Go** on `whatsmeow` + `meowcaller`. See `server-go/README.md` for details.

### WhatsMiau Adapter (experimental)
A thin Go adapter that sits in front of [WhatsMiau](https://github.com/verbeux-ai/whatsmiau), translating its Evolution API-compatible routes and webhooks into the custom API the app expects. See `adapter/README.md` for architecture, run instructions, and Docker Compose.

> **Note**: the adapter does not yet proxy WhatsApp-native calls or the full SHORTCAKE passkey ceremony. Use `server-go` if you need those features.

## Build & run

**server-go backend:**
```bash
cd server-go
go build ./... && go test ./...   # needs Go >= 1.25 (auto-downloads)
go run ./cmd/server               # starts :18770 (see server-go/README.md)
```

**WhatsMiau + Adapter backend:**
```bash
# 1. Start WhatsMiau
cd server-whatsmiau
cp .env.example .env
go mod tidy
go run main.go                    # starts :8080

# 2. Start adapter
cd adapter
go mod tidy
go run main.go                    # starts :18770
```

Or with Docker Compose:
```bash
docker compose -f docker-compose.adapter.yml up -d --build
```

**App:**
```bash
oniro-app lint --files entry/src/main/ets/**
oniro-app build
oniro-app app apply
oniro-app app launch
```

> Note: the app build requires the HarmonyOS SDK (DevEco command-line-tools +
> SDK components). The Go backends build anywhere with Go 1.25+ (pure Go, no
> CGO).

## Deploy

See `server-go/DEPLOY.md` — free VPS (GCP e2-micro), Docker or systemd, Caddy/
Cloudflare Tunnel for TLS. The app's `ServerConfig.BACKEND_HOST` (or the
hidden `backend_host` pref) points at the server.

For the WhatsMiau + Adapter stack, use `docker-compose.adapter.yml` and point
the app at the adapter host on port 18770.

## Notes

- **Single account per server** — one linked WhatsApp number per instance.
  Multi-user on a shared VPS IP is a ban risk (the same verdict as before).
- **Unofficial client** — using custom WhatsApp clients may violate Meta's
  ToS and could result in account suspension. Use at your own risk.
- **No browser, no Chrome, no container, no Jitsi** — the CDP/real-Chrome path
  and the Jitsi fallback are fully removed; calls are WhatsApp-native through
  the Go backend.
