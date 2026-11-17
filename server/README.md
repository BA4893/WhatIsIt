# WhatIsIt Server (Rust)

The whatisit-server backend: a **whatsapp-rust** (WhatsApp Multi-Device
protocol) bridge with QR pairing, chats/messages, media, and delivery
receipts — exposed over HTTP + WebSocket for the HarmonyOS app.

## Requirements

- Rust 1.94+ (MSRV of whatsapp-rust)
- On Windows without MSVC link.exe, use the GNU toolchain:
  ```
  rustup toolchain install stable-x86_64-pc-windows-gnu
  rustup default stable-x86_64-pc-windows-gnu
  rustup component add clippy
  ```
  plus MinGW-w64 (e.g. winlibs) on PATH.

## Build & run

```bash
cd server
cargo build          # first run downloads deps (needs internet)
cargo run            # starts on :18770
```

Env vars:

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `18770` | HTTP listen port |
| `WHATSAPP_TOKEN` | (empty) | If set, every request needs `Authorization: Bearer <token>` (or `?token=`). |
| `DB_PATH` | `data/whatsmeow.db` | whatsapp-rust session store (SQLite). Keeps the session across restarts. |
| `MEDIA_DIR` | `data/media` | Cached media files (served via `/media/{id}/{kind}`). |

## Endpoints

```
GET  /status         {linked, phone, qr}
POST /pair           start QR pairing (no-op when linked)
GET  /chats          [{id, name, preview, time, unread, pinned}]
GET  /calls          [{id, peer, dir, video, missed, time, name}]
GET  /messages?chat= [{id, text, dir, time, status, replyTo, reactions, media}]
POST /send           {chat, text, replyTo?}
POST /send-media     multipart {chat, file, caption?}
POST /read           {chat}
POST /react          {chat, messageId, emoji}
POST /logout
GET  /media/{id}/{kind}   cached media (kind: image|video|audio|voice|document|sticker|thumb)
WS   /ws             push {type: qr|linked|message|receipt|chats|logged_out|status}
```

## Verify pairing manually

```bash
curl -s http://localhost:18770/status        # {"linked":false,"phone":"","qr":""}
curl -s -X POST http://localhost:18770/pair  # starts pairing
# The server logs "QR code issued (N chars)"; watch /status or the WS for the
# rotating code. Scan with WhatsApp → Linked Devices → Link a Device.
# After linking, /status flips to {"linked":true,"phone":"+1..."}.
```

## Notes

- **Calls**: whatsapp-rust ships 1:1 audio VoIP, but this server's HTTP layer
  does not expose call signaling — the app uses Jitsi for video (Free Path).
- **Status/Channels/Communities** tabs in the app show honest empty states
  (not implemented over this protocol surface).
- **Media**: incoming media is downloaded to the cache when the live message
  arrives; older history media may show a "not cached" placeholder.
