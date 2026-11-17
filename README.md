# WhatIsIt

<p align="center">
  <b>A native, design-led WhatsApp client for HarmonyOS.</b><br>
  ArkTS · Stage model · API 26 · phone, tablet and 2-in-1
</p>

WhatIsIt is a reimagined third-party WhatsApp client. It takes the social-shell
structure and native HarmonyOS design language of the
[Harmony X](https://github.com/haohaoai0/HarmonyX) reference and applies it to
WhatsApp: **Chats** as the default root, **Updates**, **Calls**, **Communities**
and **Settings**, with a floating compose action and a warm, light/dark visual
system built from HarmonyOS resources and `SymbolGlyph` icons.

Sample conversations, statuses, calls and communities are available before
anything is configured, so the app is usable as a design-complete shell from
first launch. WhatsApp API access and device linking are opt-in.

---

## Highlights

| | |
|:--|:--|
| **Complete social shell** | Chats (default root), Updates, Calls, Communities, Settings, chat threads, a floating compose menu and full-screen status viewing. |
| **Native HarmonyOS design** | ArkUI, system symbols, light/dark resource palettes, adaptive phone / tablet / 2-in-1 layouts. |
| **WhatsApp API when configured** | Save a Client ID in Settings, then authorize with **OAuth 2.0 PKCE** in the system browser. No client secret is stored on-device. |
| **Actual device linking** | The Link a device sheet supports the native QR code and phone-number pairing when a WhatsApp engine is reachable, and the real WhatsApp Web QR/phone flow when it is not. |
| **Honest states** | “Preview” and “Live” badges, sample content before linking, and clear feedback when a call, status or message needs a linked device. |

## Screens

- **Chats** — search, All / Unread / Groups filters, unread badges, pinned rows,
  group markers, and a floating compose action.
- **Updates** — My status, recent status circles, followed channels and a
  discover entry point.
- **Calls** — recent voice/video history with missed-call treatment, a new-call
  picker, and the native call surface for linked devices.
- **Communities** — a hero card, community cards, join/open actions and a
  discover entry point.
- **Settings** — profile card, WhatsApp API (Client ID + OAuth PKCE), linked
  device, WhatsApp Web fallback, appearance (System / Light / Dark),
  notifications, read receipts and about.
- **Thread** — WhatsApp-style incoming/outgoing bubbles, date chip, delivery
  ticks, attachment/camera/mic entry points, voice/video call buttons and a
  composer.

## Design notes

- **Warm WhatsApp palette** in `resources/base` and `resources/dark`:
  `#25D366` brand, `#F0F2F5` page, `#FFFFFF` surface, `#111B21` ink in light;
  `#0B141A` page, `#111B21` surface, `#E9EDEF` ink in dark.
- **System-first** — HarmonyOS Sans, `SymbolGlyph` icons, resource colors only
  in pages, 4pt spacing rhythm and 16–24px card radii.
- **Adaptive shell** — a bottom tab bar on phones, a compact navigation rail on
  tablets and 2-in-1 windows; the content column widens while keeping readable
  line lengths.
- **No hidden server form** — device linking is a first-class sheet, not a
  developer-only IP field.

## Project configuration

| Setting | Value |
|:--|:--|
| Bundle | `com.example.whatisit` · version `2.0.0` (`versionCode` 2000000) |
| Module | `entry` · Stage model |
| SDK | target / compatible `26.0.0` |
| Devices | `default`, `tablet`, `2in1` |
| Window modes | fullscreen, split, floating |
| Permissions | Internet, camera, microphone, location, contacts, background running |
| Deep link | `whatisit://callback` (OAuth redirect) |
| Root page | `pages/Index` |
| OAuth callback page | `pages/OAuthCallback` |

## Build

With DevEco Studio: open the project and **Build → Build Hap(s)**.

With the command-line tools:

```bash
hvigorw --mode module -p product=default -p buildMode=debug assembleHap
```

Output:

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

> The CLI build is unsigned when the DevEco signing material is not readable by
> the command-line user. Sign in DevEco Studio before installing.

## Configure WhatsApp sign-in

1. Create an app on the WhatsApp/Meta developer platform.
2. Enable OAuth 2.0 and set the redirect URI to `whatisit://callback`.
3. Open **Settings → WhatsApp API** in WhatIsIt, paste the **Client ID**, tap
   **Save**, then **Connect WhatsApp**.
4. The system browser opens the provider's authorization page. The app uses
   PKCE (S256) and never stores a client secret.
5. After the browser redirects to `whatisit://callback`, the app exchanges the
   code and shows **API connected** in Settings.

The default provider endpoints are Meta's public OAuth endpoints in
`services/WhatsAppOAuth.ets`; a compatible provider can be substituted there.
Some WhatsApp APIs require business verification or paid access; the UI reports
the provider error instead of pretending the connection succeeded.

## Link a device

**Settings → Link a device** opens the linking sheet:

- **QR code** — scan with WhatsApp on another phone.
- **Phone number** — enter the country code and national number, then type the
  8-character code in WhatsApp's *Link with phone number instead* flow and
  approve the notification on the phone.
- **Use WhatsApp Web instead** — opens the real `web.whatsapp.com` in ArkWeb
  for the official QR/phone-number flow. This needs no backend and keeps its
  session in the app's WebView storage.

The native QR/phone path needs the existing WhatsApp engine/backend
(`server-go/` or an embedded engine). Without it, the shell stays in **Preview**
mode and the Link sheet offers the WhatsApp Web fallback.

### Passkey-protected accounts

WhatsApp has a passkey/“SHORTCAKE” gate for many accounts. ArkWeb can show the
passkey prompt but cannot complete the assertion on this device. The WebView
injects a small `navigator.credentials.get` shim that asks a **PC bridge** for
the assertion; the passkey stays in Chrome. This needs no server.

1. On the PC with Chrome and the passkey:

   ```bash
   node bridge/agent.js --token <long-random-token>
   ```

2. In the app: **Settings → Passkey bridge**, enter the PC LAN address, port
   (default `18771`) and token. Tap **Test bridge**.
3. Open **Settings → WhatsApp Web**, link with phone number, enter the code on
   the phone, then complete the passkey prompt in Chrome on the PC.

The WebView must stay alive during the link; on one phone use split-screen or a
second device. See [bridge/README.md](bridge/README.md) for the full setup,
security notes and limitations.

## Architecture

| Path | Purpose |
|---|---|
| `pages/Index.ets` | The adaptive shell, five tabs, header, floating compose, thread routing and sheet state. |
| `pages/OAuthCallback.ets` | PKCE code exchange and session persistence. |
| `pages/WebLoginView.ets` | In-app WhatsApp Web login fallback. |
| `components/ChatsPane.ets` / `ChatRow.ets` | Default Chats root. |
| `components/UpdatesPane.ets` | Status + channels. |
| `components/CallsPane.ets` | Call history; wire-up to `CallService`. |
| `components/CommunitiesPane.ets` | Community cards and join state. |
| `components/SettingsPane.ets` | Profile, Client ID, OAuth, link, appearance, preferences. |
| `components/ConversationView.ets` | Thread bubbles, ticks, composer, call buttons. |
| `components/ComposeSheet.ets` / `LinkDeviceSheet.ets` / `StatusComposerSheet.ets` | Floating compose, device link, status composer. |
| `services/WhatsAppStore.ets` | Sample content for the preview shell. |
| `services/Pkce.ets`, `AuthStore.ets`, `OAuthConfigStore.ets`, `OAuthFlowStore.ets`, `WhatsAppOAuth.ets` | OAuth 2.0 PKCE stack. |
| `services/CdpBridge.ets`, `CallService.ets`, `server-go/` | The optional native WhatsApp engine/backend. |
| `services/PasskeyBridge.ets` | Bridge config + LAN client used by the WebView shim. |
| `bridge/agent.js` | PC-side Chrome CDP passkey bridge. |

## Live vs preview

- **Preview** — the app ships with realistic sample chats, statuses, calls and
  communities. Every screen is navigable; sending a message adds a local bubble.
- **Live** — when a WhatsApp engine/backend is linked, `Index.ets` polls
  `/status` and replaces the sample chats/messages/statuses/channels/calls with
  live data. Calls and status posts use the existing `CallService` and
  `CdpBridge` endpoints.
- **Calls** — incoming calls now show a full-screen ringing sheet with
  Accept/Decline and hand off to the native `CallSurfaceView`; call history and
  missed calls come from the engine. Harbour-whatsapp is used as the feature/UX
  reference, not as a QML/Sailfish dependency.
- **Live engine** — native live data needs a running `server-go` (or the
  embedded `libwa_engine.so`, which is not built yet). Open
  **Settings → Live engine**, enter the host/port (and token if set), and tap
  **Save & connect**. Then use **Settings → Link a device** to scan the QR or
  request an 8-character code. Once linked, `/status` reports `linked` and the
  shell replaces the sample data with live chats, messages, statuses, calls and
  channels.
- **WhatsApp Web** — the official web login is always available as a fallback;
  its session lives in ArkWeb storage and is independent of the native shell.
  It cannot feed the native Chats/Calls data.

The embedded engine is built separately from the HAP:

- `server/` is the shared `whatsapp-rust` engine (also runnable over HTTP for
  Phase 0a).
- `engine/` is the NAPI cdylib; `.github/workflows/build-engine.yml` builds
  `libwa_engine.so` for `aarch64-unknown-linux-ohos`.
- Drop the artifact into `entry/libs/arm64-v8a/libwa_engine.so`; CMake links
  it through `wa_bridge.cpp`. See [engine/README.md](engine/README.md).

To run the engine on a PC/VPS:

```bash
cd server-go
WHATSAPP_TOKEN=change-me PORT=18770 go run ./cmd/server
```

Use the PC/VPS LAN or public address in **Settings → Live engine**. The session
lives on that host, so it must stay running; see [server-go/DEPLOY.md](server-go/DEPLOY.md).

For a passkey-protected account, also configure **Settings → Passkey bridge**.
The native link sheet now requests the WebAuthn assertion from the PC bridge,
posts it to `/passkey/assertion`, and confirms the code WhatsApp returns. The
server installs the passkey answer channel in `server-go/client.go`.

## ZapFast

[`ZapFast/`](ZapFast/README.md) holds the native Rust and egui WhatsApp client
ported to HarmonyOS. It keeps ZapFast's own engine, archive and interface and
draws them into an ArkUI XComponent, rather than reimplementing the client in
ArkTS. The HarmonyOS project, build steps and known gaps are in
[`ZapFast/harmonyos/README.md`](ZapFast/harmonyos/README.md); the signing notes
are in [`ZapFast/harmonyos/SIGNING.md`](ZapFast/harmonyos/SIGNING.md).

## Notes

- **Unofficial client** — using custom WhatsApp clients may violate Meta's Terms
  of Service and can result in account suspension. Use at your own risk.
- The design and the PKCE helper are adapted from the
  [Harmony X](https://github.com/haohaoai0/HarmonyX) project (Apache-2.0);
  WhatIsIt keeps its own identity, WhatsApp palette and functionality.
- Backend/deployment notes from the native protocol implementation are kept in
  [README-SERVER.md](README-SERVER.md).
