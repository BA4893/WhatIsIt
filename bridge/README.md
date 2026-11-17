# WhatIsIt passkey bridge

WhatsApp has a server-side passkey/“SHORTCAKE” gate for companion linking. On
this HarmonyOS device ArkWeb can show the passkey prompt but cannot complete the
assertion. This bridge lets a PC do the WebAuthn ceremony while the phone keeps
WhatsApp Web in the app.

It is **not** a server. It runs on a PC on the same LAN as the phone, talks to
Chrome over DevTools, and returns only the signed assertion. The passkey itself
stays in Chrome / the password manager.

## Requirements

- Node.js 22 or newer (the agent uses the built-in `WebSocket` and `fetch`).
- Google Chrome on the PC, with the WhatsApp passkey available.
- Phone and PC on the same LAN.
- The phone running WhatIsIt 2.0.0 or newer.

## Start the bridge

1. Close Chrome completely. Chrome must be started with remote debugging; an
   already-running Chrome cannot enable it.
2. Run the agent on the PC:

   ```bash
   node bridge/agent.js --token <long-random-token>
   ```

   It prints something like:

   ```text
   listening : http://192.168.1.20:18771
   token     : <long-random-token>
   ```

   Useful flags:

   ```text
   --port 18771            bridge HTTP port
   --chrome-port 9222      Chrome DevTools port
   --chrome <path>         Chrome executable
   --profile <dir>         Chrome user-data-dir (if your passkey profile is not the default)
   --no-launch             do not launch Chrome; use an existing debug endpoint
   ```

   If the agent cannot find Chrome, pass `--chrome` explicitly. On Windows:
   `--chrome "C:\Program Files\Google\Chrome\Application\chrome.exe"`.

3. Leave the agent running. It launches Chrome at `https://web.whatsapp.com`.
   The passkey prompt appears in that Chrome window.

## Configure the phone

1. Open WhatIsIt → **Settings → Passkey bridge**.
2. Enter the PC LAN address printed by the agent (for example `192.168.1.20`),
   the port (`18771`) and the token.
3. Tap **Save**, then **Test bridge**. It should report reachable.
4. Open **Settings → WhatsApp Web**, then **Link with phone number**.
5. Enter the 8-character code on the phone's WhatsApp.
6. When Chrome prompts for the passkey on the PC, complete it there (biometric /
   PIN / phone approval).
7. Return to the app; WhatsApp Web should complete the link.

## What the agent does

```text
WhatsApp Web (ArkWeb)
  navigator.credentials.get({publicKey})     <- intercepted by the injected shim
        |
        | window.__waPasskeyBridge.getAssertion(options)
        v
  WhatIsIt native (HTTP over LAN)
        |
        v
  bridge/agent.js  --CDP-->  Chrome on https://web.whatsapp.com
                                   passkey prompt
        <-- assertion JSON --------
        |
  shim builds a PublicKeyCredential-like object
        |
  WhatsApp Web sends the assertion to WhatsApp
```

The shim is injected with `javaScriptOnDocumentStart` and only intercepts
public-key `get` calls for `web.whatsapp.com`. If the bridge is not configured,
it falls back to ArkWeb's native WebAuthn behavior.

## Security

- The agent requires `Authorization: Bearer <token>`. Use a long random token.
- It refuses any `rpId` other than `web.whatsapp.com`.
- It does not export or log the passkey or the assertion.
- It binds Chrome DevTools to localhost (`127.0.0.1:9222` by default).
- The phone must be on the same LAN. Do not expose the bridge port to the
  internet.
- Run it only while linking; stop it afterwards.
- Chrome remote debugging gives local control of that Chrome profile. Use a
  dedicated profile if you do not want the bridge to attach to your everyday
  profile.

## Known limits

- The WebView must stay alive while the phone code is entered and the passkey
  is completed. On a single phone, prefer split-screen or a second device; the
  app can be suspended in the background.
- WhatsApp can change its WebAuthn flow at any time. The shim is deliberately
  small and only wraps `get`.
- The shim constructs a credential-like object. If WhatsApp starts requiring a
  native `PublicKeyCredential` with internal slots, this approach will need to
  be revisited.
- If Chrome uses a phone-hybrid passkey, the prompt may appear on the phone
  instead of the PC; complete it there.
