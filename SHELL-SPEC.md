# HarmonyOS shell specification (ZapFast-inspired)

**Decision:** full native rewrite; ArkUI shell; native `whatsapp-rust` engine
(`libwa_engine.so`) through the existing `WaEngine` NAPI contract. No egui/QML
port, no WebView as the primary client.

**Reference:** ZapFast (MIT) for product behaviour and visual language;
[HarmonyOS Skills](https://github.com/liasica/harmonyos-skills) for ArkTS /
ArkUI rules and official API citations. HarmonyOS Skills is an offline
documentation mirror, **not** a UI kit; its rules are adopted, its docs are
consulted, its files are not copied into the app.

## Layout by form factor

| Form factor | Structure |
|---|---|
| Phone (< 600 vp) | One pane; bottom navigation: **Chats · Calls · Settings**; conversation and call screens push over it |
| MatePad / tablet (600–1024 vp) | Two panes: chat list + conversation; compact rail for Calls/Settings |
| PC / 2-in-1 (> 1024 vp) | Three columns: 72 vp rail, 340 vp chat list, flexible conversation; keyboard shortcuts, resizable window |

Use ArkUI `Navigation` with automatic split mode for tablet/PC, and a
`NavPathStack` for phone pushes. Do not hand-roll three layouts with duplicated
state.

## Visual language

- ZapFast-like calm surface, strong typography, rounded 16–20 vp cards,
  generous list rows, subtle separators, no heavy chrome.
- WhatsApp palette for brand/bubbles, but neutral surfaces for the shell.
- Light/dark/system from `AppearanceStore`; every colour is a resource.
- Chat wallpaper: a subtle doodle/neutral texture, not a flat wall.
- Avatars: deterministic fallback from the contact id, like the current
  `Avatar`/`Theme.avatarColor` path.
- Motion: state-driven `animateTo`, `renderGroup(true)` on animated lists;
  never animate width/height/padding. Respect reduced motion.

## Screens (parity order)

1. **Chats** — search, filters (All/Unread/Private/Favorites/Groups), pinned,
   archived, unread badges, presence, typing, delivery ticks.
2. **Conversation** — text, replies, edits, reactions, forwards, media,
   voice notes, polls, stickers, link previews; composer with attachment,
   emoji, voice; message actions.
3. **Calls** — history, missed/incoming/outgoing, in-call surface, speaker,
   mute, camera, PiP; ringing notification.
4. **Settings** — account/device, engine status, passkey, notifications,
   appearance, media/storage, privacy/lock, about.
5. **Updates/Channels/Communities** — status and channel views, follow/search;
   no fake data once live.

## State and boundaries

- UI uses `WaEngine` / `CdpBridge` only; no protocol types in views.
- One account for Phase 1; multi-account is Phase 4.
- Live and preview must be visibly distinct; no sample data presented as live.
- Boot: engine status → link screen if unlinked → chats.

## ArkTS rules

Follow `harmonyos/rules/arkts-coding-rules.md`:

- No `any`/`unknown`, no destructuring, no `var`, no `Function.bind/call/apply`,
  no `for..in`, no index signatures, explicit return types where required.
- Object literals only where the target type is explicit; otherwise classes.
- `$r` resources for colours/strings; add dark resources and i18n keys.
- Use official APIs; verify signatures in the HarmonyOS Skills references.

## Phase mapping

| Phase | Shell scope |
|---|---|
| 0a/0b | No UI rewrite until the engine gate passes |
| 1 | New shell: Chats, Conversation, Send/Receive, phone/tablet/PC |
| 2 | Media/history in Conversation |
| 3 | Calls surface, incoming/outgoing, voice then video |
| 4 | Settings/notifications/privacy/multi-account |
| 5 | Polish, accessibility, i18n, performance |

## Open decisions

- Voice-first is recommended; video follows the voice gate. Confirm whether
  video is a launch requirement.
- The current `Index.ets` shell is replaced after the engine gate; until then
  it remains the only runnable UI.
- HarmonyOS Skills stays a reference; the app does not vendor its 17k docs.
