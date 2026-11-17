# Phase 0a — HTTP engine validation

This is the validation harness, not the final app architecture. It uses the
same `whatsapp-rust` engine that `engine/` will expose through NAPI.

## 1. Start the engine on a PC/VPS

```bash
cd server
PORT=18770 WHATSAPP_TOKEN=change-me cargo run --release 2>&1 | tee server.log
```

Or from the repository root:

```bash
PORT=18770 WHATSAPP_TOKEN=change-me ./scripts/run-server.sh
```

Requirements: Rust 1.99+, a C toolchain for the SQLite dependency, and network
access. Keep the machine awake: the WhatsApp session lives there.

## 2. Point the app at it

Settings → **Live engine**:

- host: the PC/VPS LAN/public IP
- port: `18770`
- token: `change-me`
- **Save & connect**

The app probes `/status`. If it fails, open this from the phone browser:

```text
http://<PC-IP>:18770/status
```

## 3. Pair

Settings → **Link a device**:

- QR: scan with WhatsApp.
- Phone: enter the country code/national number, then the 8-character code on
  the phone.

The server emits `qr`, `pair_code`, `linked` and `passkey_*` events over
`/ws`; the app mirrors them in the link sheet.

## 4. Passkey accounts

Start the PC bridge:

```bash
node bridge/agent.js --token <long-random-token>
```

Settings → **Passkey bridge**: PC IP, port `18771`, token.

The native link sheet sends `passkey_request` options to the bridge, gets a
Chrome WebAuthn assertion, posts it to `/passkey/assertion`, then shows the
confirmation code for `/passkey/confirm`.

## 5. Calls

Calls use `/call`, `/call/accept`, `/call/reject`, `/call/end`, `/call/mute`,
`/call/camera`, `/call/state` and binary audio/video over `/ws`. The Calls tab
also reads `/calls` (call history), which the server now records for outgoing,
accepted incoming and rejected/missed calls.

## 6. If it fails

Collect:

```bash
tail -200 server/server.log
hdc shell hilog | grep -E 'CdpBridge|LinkDevice|PasskeyBridge|WaEngine|WebLogin'
```

Send the log with phone numbers, JIDs, QR payloads and pairing codes redacted.

Common cases:

| Symptom | Check |
|---|---|
| `No native engine is reachable` | server process, `http://IP:18770/status`, firewall, token match |
| `pair-code failed` | passkey configured, code requested within ~60s, phone number E.164 |
| QR appears but never links | `/ws` connected, app token, server log around `linked` |
| passkey request with no bridge | Settings → Passkey bridge, `bridge/agent.js`, Chrome profile |
| Calls tab empty | `/calls` reachable; start/accept a call after linking |

## Known gaps in this harness

- `/status-list`, `/channels`, `/history/backfill` are not implemented by the
  Rust HTTP server yet; Updates/Channels remain sample/empty.
- Media send/reply/react are stubs in the NAPI engine; the HTTP server has
  `/send-media` and `/react`, but the link gate only needs text.
- The NAPI engine is the final path; this server is removed once
  `libwa_engine.so` passes Phase 0b.
