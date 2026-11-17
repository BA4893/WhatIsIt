# Automatic passkey flow

**Requirement:** the user taps **Link a device**, chooses phone number, approves
on the phone, and the passkey step completes. No terminal, no IP, no token, no
manual `bridge/agent.js` configuration.

## Why it is not automatic today

WhatsApp’s SHORTCAKE gate requires a WebAuthn assertion for
`web.whatsapp.com`. ArkWeb can show a passkey prompt but, on this device, cannot
complete the assertion. The current PC bridge was a workaround: it moved the
assertion to Chrome, but exposed host/port/token and a CLI, which is exactly the
manual flow to remove.

There are only three ways to make it automatic:

| Path | Phone-only? | Reality |
|---|---|---|
| **A. Native/system passkey** | Yes | Requires HarmonyOS to provide a usable WebAuthn credential for WhatsApp’s RP. Must be tested; the app cannot invent one. |
| **B. Automatic companion bridge** | No | A one-time PC helper, auto-discovered over mDNS/QR, runs Chrome and returns the assertion. No IP/token/CLI after pairing. |
| **C. WhatsApp Web only** | Yes | Use the system browser where passkeys already work; the native engine cannot reuse that browser session. |

## Path A — phone-only passkey (preferred if it works)

Before building anything, test the phone’s **system browser**:

1. Open `https://web.whatsapp.com` in Chrome/Huawei Browser on the phone.
2. Link with phone number.
3. When the passkey prompt appears, complete it with the phone’s biometrics.

- If it **works**, the credential/provider exists on the phone. The next step is
  to investigate why ArkWeb does not use it (WebAuthn provider, hybrid
  transport, client hints, or a WebView limitation).
- If it **fails**, Android/HarmonyOS does not expose that passkey to the
  browser either; a phone-only automatic flow is not available without a
  native passkey implementation.

The native engine exposes `passkey_request` / `passkey_assertion`; if a native
credential source exists, this becomes fully automatic and no PC is involved.

## Path B — automatic companion (fallback)

Remove every manual step from the current bridge:

1. The phone app opens WhatsApp Web, or the native link sheet reaches the
   passkey request.
2. A companion helper is discovered automatically:
   - mDNS service `_whatisit-passkey._tcp`, or
   - a QR shown once by the helper and scanned by the app.
3. The app sends the `PublicKeyCredentialRequestOptions` over an authenticated
   local channel; the helper returns the assertion.
4. The helper runs Chrome with remote debugging, opens
   `https://web.whatsapp.com`, completes the passkey, and returns the assertion.
5. The app submits it to the engine and shows the confirmation code.

No IP field, no token field, no terminal. The helper is a signed background app
installed once; it can auto-start.

This is still a PC companion. It is the only practical route if Path A fails and
the account must keep its passkey.

## What gets removed from the UI

- **Settings → Passkey bridge** host/port/token fields.
- The README instruction to run `node bridge/agent.js`.
- Manual Chrome remote-debugging setup.

The helper may show a one-time pairing QR and a “Passkey helper connected”
status, nothing else.

## Decision gate

1. Test the phone’s system browser against WhatsApp Web.
2. If passkey works there: build Path A; phone-only.
3. If it fails: build Path B; one-time helper, automatic discovery.
4. In neither case ship the manual bridge UI.

## Security

- Companion pairing uses a one-time secret, mDNS discovery is not trusted by
  itself.
- The helper signs only `rpId = web.whatsapp.com`.
- No key export; Chrome performs the assertion.
- No assertion/challenge logging.
