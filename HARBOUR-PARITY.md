# Harbour parity plan (Route C)

**Decision:** use [smatkovi/harbour-whatsapp](https://github.com/smatkovi/harbour-whatsapp)
as the feature/UX specification. **Do not** port its QML/Silica UI or its
Linux/Sailfish backend. Keep a HarmonyOS-native ArkTS UI and the existing
`server-go` engine, which already has an app-facing call-audio relay.

## What is reused

- Feature inventory, screen flows and edge cases (calls, chats, media, groups,
  channels, status, notifications, reconnect behaviour).
- Protocol expectations already implemented by `server-go`/whatsmeow.
- The project is MIT; attribution is kept in the README.

## What is not reused

- `qml/harbour-whatsapp.qml` — Silica components, pyotherside, D-Bus, Cover.
- `wa-backend` — glibc aarch64 binary requiring SQLCipher, D-Bus, Sailfish
  Secrets and PulseAudio; it does not run on HarmonyOS.
- Sailfish `voicecallplugin` — replaced by `CallService`/`CallAudio` and the
  native call media surface.

## Parity status

| Area | Harbour feature | WhatIsIt status |
|---|---|---|
| Calls | Incoming ringing, accept/decline | **Done** — `IncomingCallSheet` + `Index` hand-off |
| Calls | In-call mute, camera, hang-up, duration | Done (`CallSurfaceView`) |
| Calls | Speaker/earpiece routing | Missing |
| Calls | Background ringing/notification, missed-call alert | Missing — needs a background call service |
| Calls | Call history, missed calls | Live from `/calls`; verify |
| Chats | Text send/receive, ticks, read receipts | Live via engine |
| Chats | Images/video/audio/documents, voice notes | Partial / missing |
| Chats | Replies, reactions, edit/revoke, forward, pin | Partial / missing |
| Chats | Groups, invites, participants, descriptions | Partial / missing |
| Chats | Disappearing messages, archive/mute/pin | Partial / missing |
| Chats | Block, profile, contact info, avatars | Partial / missing |
| Updates | Status post/view/delete | Partial |
| Channels | Search, follow/unfollow, channel messages | Partial / missing |
| Settings | Notifications, media storage, call preferences | Partial |
| Resilience | Reconnect/backoff, offline/relay states | Engine-side exists; UI partial |
| Security | Encrypted local session store | Server-side; app stores config only |
| Passkey | SHORTCAKE companion linking | Engine passkey endpoint + PC bridge implemented; verify live |

## Next slices

1. **Calls hardening** — speaker routing, missed-call notification, background
   ringing, call log refresh on `call_state`.
2. **Chat media** — image/video/audio/document send and receive, voice notes.
3. **Message actions** — reply, react, edit, revoke, forward, pin.
4. **Groups/channels** — participants, invites, channel search/follow.
5. **Settings parity** — notification policy, media storage, call preferences.
6. **Background/resilience** — continuous task or service for WS/ringing.

## Rule for new work

Every new screen/behaviour is written in ArkTS against the existing
`CdpBridge`/`CallService` engine contract. Harbour is consulted for behaviour,
copy and edge cases; its code is not copied into the app unless it is a small
MIT-licensed algorithm that is explicitly attributed.
