# WhatIsIt — Test User Setup Guide (legacy native-server mode)

> **Legacy guide.** The current app is the design-led shell described in
> [README.md](README.md). The native server-backed path is optional; this guide
> documents it for developers.

This guide gets a test user from fresh device to linked + chat usage with the
**Go backend** (`server-go/`, whatsmeow + meowcaller) on a VPS. No PC, no
Chrome, no container needed after linking. Total time: ~5 minutes.

> **Backend status**: `server-go/` is the current backend — a wire-compatible
> port of the original Rust `server/` (whatsapp-rust). It is built and its
> parity tests pass, but it has **not yet been live-linked** to a real
> WhatsApp account on a VPS. The Rust `server/` is kept as the known-good
> reference until the Go server passes the live link + call test.

---

## What you need

- A Huawei device (HarmonyOS) with the **WhatIsIt** app installed.
- The **WhatsApp** app on a phone (the same device or another one) for
  scanning the QR or entering the phone-link code.
- An internet connection. **No server is required for normal login**: if no
  native protocol engine/backend is reachable, the app opens the real
  WhatsApp Web inside the app for QR / phone-number linking.

> The native `server-go` path is optional and intended for developers. It is
> only used when a native engine or a reachable backend is configured at build
> time; normal installs use the in-app WhatsApp Web fallback.

---

## Step 1 — Install and open

1. Install WhatIsIt on the Huawei device.
2. Open the app. It loads WhatsApp Web in the app window.
3. There is no IP, port or token to enter.

---

## Step 2 — Link with the QR code or phone number

1. On the WhatsApp Web page in the app, either:
   - **Scan the QR** with WhatsApp on another phone: WhatsApp → Settings →
     Linked devices → Link a device.
   - **Link with phone number instead**: tap it on the page, enter your phone
     number, then on the phone use WhatsApp → Linked devices → Link with
     phone number and enter the 8-character code shown.
2. The page loads the WhatsApp Web chat list; the session is stored in the app.

> With only one phone, use the phone-number flow. The QR flow needs a second
> device to scan.

---

## Step 3 — Use chats

In the default WebView login, use the normal WhatsApp Web chat list, threads,
media and ticks inside the app. The session is stored by the WebView, so
reopening the app returns to the same account.

> The native chat list/thread UI described below is the optional
> `server-go` path; it is not used when the app is in WebView mode.

---

## Step 4 — Keep it alive

- **WebView mode:** WhatsApp Web keeps the linked-device session in the app's
  storage. Reopen the app and it returns to the chat list; no server or
  keep-alive process is involved.
- **Native mode (optional server):** the server keeps the WhatsApp socket
  alive (keepalive + auto-reconnect); SQLite keeps the session across restarts.

---

## Calls

- **WhatsApp-native voice calls**: use the 📞 button in a chat — the server
  runs the call over the WhatsApp protocol (meowcaller VoIP) and relays the
  audio to the app over the WebSocket.
- **WhatsApp-native video calls**: use the 📹 button — H.264 is encoded/
  decoded by the native `call_media` module (OH_VideoEncoder/Decoder) and
  rendered on native XComponent surfaces (PiP overlay for the local camera).
- No Jitsi, no browser, no third-party media servers.

> **Call status**: the meowcaller bridge is implemented and compiles, but has
> not been validated against a live peer yet. meowcaller's video send/receive
> paths are marked "NOT VALIDATED" upstream. Test voice first, then video.

---

## Passkey linking (SHORTCAKE)

Some WhatsApp accounts now require a **passkey check** when linking a new
device (Meta's 2026 security rollout). If your account hits this:

1. The app shows a **"WhatsApp security check"** card on the Link screen.
2. It expects a WebAuthn assertion from a passkey registered to the account.
   This SDK has no native Credential Manager API yet, so the card accepts a
   **pasted assertion JSON** (developer fallback) — a future `@kit` WebAuthn
   API will make this a one-tap biometric prompt.
3. If a **verification code** appears, enter it in WhatsApp when asked, then
   tap **Confirm** in the app.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| WhatsApp Web is blank / browser warning | Check internet. The WebView sends a desktop Chrome UA; if WhatsApp still refuses the embedded browser, use the system browser to link and report the exact warning. |
| QR is clipped / tiny | Scroll or pinch; the page is desktop-width. Alternatively use "Link with phone number instead". |
| Phone-number code fails | Enter the country code separately and the national number without a leading 0; use the code on the same phone's WhatsApp → Linked devices → Link with phone number. |
| Session lost | WhatsApp removed the linked device, or the WebView storage was cleared. Link again. |
| Native chat UI never appears | Expected: without a native engine/backend the app uses WhatsApp Web. |
| "WhatsApp security check" card stuck (native mode) | Passkey support is incomplete; use the WebView login, which handles WhatsApp's own web flow. |

---

## What the test user should report back

1. Did the QR scan link successfully?
2. Did the phone-number 8-char code link work?
3. Did the passkey security check complete (if your account requires it)?
4. Did the chat list load?
5. Did tapping a chat open the thread instantly?
6. Did sending text + an image work?
7. Did delivery ticks appear (sent → delivered → read)?
8. Did a WhatsApp-native voice call work? A video call?
9. (Next day) Is it still linked without re-scanning?

## Alternative backend: WhatsMiau Adapter

If you want to use [WhatsMiau](https://github.com/verbeux-ai/whatsmiau) as the
WhatsApp engine (robust, Evolution API-compatible, lightweight), run the
adapter instead of `server-go`:

```bash
# 1. Start WhatsMiau
cd server-whatsmiau
cp .env.example .env
go mod tidy
go run main.go

# 2. Start adapter
cd adapter
go mod tidy
go run main.go
```

Or with Docker Compose:

```bash
docker compose -f docker-compose.adapter.yml up -d --build
```

The adapter listens on port 18770 and exposes the same API the app expects.
It auto-creates a single WhatsMiau instance, forwards send operations, and
receives webhooks to build the local chat/message history the app polls.

See `adapter/README.md` for full details, environment variables, and known
limitations.
