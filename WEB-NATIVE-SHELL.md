# Native ArkUI shell over the linked WhatsApp Web session

**First slice implemented:** the root `Index` now keeps a hidden `Web` on
`web.whatsapp.com`, injects `WA_NATIVE_SHIM`, and
`WhatsAppWebBridge` populates the native chat list, conversation and composer.
`Settings → WhatsApp Web` (or a call from a Web-backed chat) reveals the same
WebView for calls/media. The UI marks this state **Web**, not **Live**.

**Native link selector tuning:** QR detection covers dedicated QR boxes, large canvases and QR images; phone fields/buttons have `data-testid`/aria/placeholder fallbacks; code parsing checks dedicated code selectors and text near “enter this code”. After ~10 s a `linkDebug` DOM snapshot is logged to HiLog.

**Native default + banner:** native shell now opens first; when Web is not linked, a banner shows Web load state with Retry / Open Web / Link actions. `showLinkScreen` is opt-in, not a startup gate.

**Native link onboarding:** `NativeLinkView` mirrors the hidden WhatsApp Web's unlinked state in ArkUI — QR image, phone entry, 8-character code, countdown, refresh, and linked transition. The WebView is not shown for normal linking; passkey/unsupported flows can fall back to Web. The same view can later be fed by `WaEngine` QR/pair-code events.

**Media viewer/cache:** tapping an image extracts a 1600 px JPEG from the WebView, persists it to the app cache via `MediaDownloader.saveDataUrl`, and opens a native full-screen `MediaViewer`. Video/document/voice still open WhatsApp Web.

**Polish (media/avatars/search):** image/video/document/voice messages produce native bubbles; images are cached as small canvas data URLs, video/document/voice open the WebView. Chat avatars use cached 64 px canvas data URLs with initials fallback. New-chat search has selector fallbacks, a 1.2 s result wait, and query-aware result matching.

**Polish:** once Web is live, the app skips the unused HTTP `/status` poll; the open native thread is refreshed every 1.5 s with a message signature so incoming messages appear without jumping the list.

**Web → native handoff:** the WebView is an explicit mode. Its header has **Native UI** and **Close**; after a link completes in Web mode it returns automatically after a short toast. If the app shows WhatsApp Web, it is in that mode, not the native shell.

**Step 5 implemented:** an optional Store path probes `window.require('WAWebCollections')`, reads `Store.Chat` / `chat.msgs.getModelsArray()`, and switches the native model to Store when available. DOM remains the fallback and still handles open/send/search. Store messages include `ack` status and sender; media metadata is not mapped yet.

**Step 4 implemented:** the native composer sends through `footer [contenteditable]`; New chat searches WhatsApp Web and opens the first result; Call and Attach reveal the WebView for WhatsApp Web's call/file UI; Settings stay native.

**Step 3 implemented:** tapping a Web chat opens it, reads the rendered
`msg-container` rows, maps direction/status/sender, scrolls the native list to
the newest bubble, and exposes upward scrolling as `scrollOlder()` for the
rendered-history window.

The WhatsApp Web session is already linked in the WebView. To get a native
ArkUI chat list, conversation and buttons, the WebView becomes a hidden
**data/action backend**; ArkUI draws the UI.

This is a web-backed native shell, not a native protocol client. It does not
use `libwa_engine.so`, and it cannot expose E2EE keys or native calls.

## Architecture

```
Native ArkUI shell
  Chats list · Conversation · Composer · Buttons
        │  runJavaScript / javaScriptProxy
        ▼
Hidden WebView (web.whatsapp.com, linked session)
        │  DOM selectors or WhatsApp Store
        ▼
WhatsApp Web
```

- WebView stays mounted, full-size, behind the native shell.
- Native overlay must be opaque and consume touches, or the WebView receives
  them.
- The WebView must stay alive; background suspension stops new-message events.

## Bridge API (JS side)

Inject at document start (same mechanism as the passkey shim):

```js
window.__waNative = {
  chats() { /* return JSON string */ },
  messages(limit) { /* open chat's messages */ },
  openChat(id) { /* click row */ },
  send(text) { /* insert into composer + send */ },
  linked() { /* chat list exists */ }
};
```

Native calls via `WebviewController.runJavaScript('window.__waNative.chats()')`.
For live updates, inject `window.__waNativeHost.onEvent(json)` through a
`javaScriptProxy`, or poll every 1–2 s. Polling is simpler and adequate for a
first native shell.

## DOM selectors (WhatsApp Web, 2026)

These change; keep them in one shim, with fallbacks.

| Data | Selector |
|---|---|
| Chat rows | `#pane-side [role="listitem"]`, `[data-testid="cell-frame-container"]` |
| Chat id | row `data-id` (e.g. `false_…@c.us`) |
| Chat name | `[data-testid="cell-frame-title"] span[title]`, fallback `span[title]` |
| Preview | `[data-testid="cell-frame-secondary"]`, fallback row text |
| Time | `[data-testid="cell-frame-primary-detail"]` |
| Unread | `[data-testid="icon-unread-count"]` |
| Avatar | row `img` |
| Open chat | `row.click()` |
| Header title | `[data-testid="conversation-info-header-chat-title"]` |
| Message rows | `[data-testid="msg-container"]` |
| Message text | `.selectable-text span`, `span[dir="ltr"]` |
| From me | row class `message-out`, or message id starting `true_` |
| Message time | `[data-testid="msg-meta"] span`, or `data-pre-plain-text` |
| Composer | `footer [contenteditable="true"]` |
| Send button | `[data-testid="send"]`, `span[data-icon="send"]` |

Open a chat, wait ~300 ms, then read messages. Scroll the message pane upward to
load older DOM nodes; WhatsApp Web does not render the whole history at once.

Sending:

```js
const box = document.querySelector('footer [contenteditable="true"]');
box.focus();
document.execCommand('insertText', false, text);
box.dispatchEvent(new InputEvent('input', { bubbles: true }));
document.querySelector('[data-testid="send"]')?.click();
```

## Deeper option: WhatsApp Web Store

DOM scraping is simple but brittle and only sees rendered messages. A more
capable bridge injects into WhatsApp Web’s webpack chunk and uses its internal
`Store` (the same technique as `whatsapp-web.js`):

- `Store.Chat.getModelsArray()` → chats, contacts, unread, pins
- `Store.Msg.getModelsArray()` / chat message collection → full loaded history
- `Store.SendTextMsgToChat` / `Store.Cmd` → send, read receipts, reactions
- media metadata and download URLs

This is more powerful but more fragile and more likely to break on WhatsApp Web
updates. Start with DOM; move to Store only if the native shell needs richer
data.

## ArkTS side

1. Add a `WebSessionHost` component: a `Web` with the linked session, behind the
   native shell, plus the shim and a `javaScriptProxy` event object.
2. Add `WhatsAppWebBridge`:
   - `chats(): Promise<WebChat[]>`
   - `messages(): Promise<WebMessage[]>`
   - `openChat(id)`, `send(text)`
   - poll timer + link detection.
3. Feed the existing `ChatItem`/`MessageItem` models and native
   `ChatsPane`/`ConversationView`.
4. Native buttons:
   - New chat → inject `openChat`/search
   - Send → `send(text)`
   - Attach → DOM file input or open the WebView temporarily
   - Call → show the WebView (WhatsApp Web call UI); native call controls are
     not available through this bridge
5. Keep a visible "Web session" indicator; do not present it as the NAPI
   engine.

## Limits to accept

- **Text-first**: media, polls, stickers, voice notes need extra DOM work or
  Store access.
- **Rendered messages only**: older history requires scrolling or Store.
- **Calls**: video/voice call UI lives in WhatsApp Web; a native in-call screen
  cannot be driven reliably from the DOM.
- **Notifications/background**: the WebView must stay alive; HarmonyOS may
  suspend it.
- **Brittleness**: selector changes break the shell; keep the shim isolated and
  log parse failures.
- **Terms**: an unofficial client; account risk remains.

## Recommendation

This is the fastest way to get a native ArkUI layout over the already-working
WebView session. Build it as a **text-first native shell**:

1. Hidden linked WebView.
2. DOM shim for chats + messages + send.
3. Native list and conversation.
4. Add media/calls later, or keep the WebView visible for those screens.

For a truly native protocol client, the NAPI engine remains the long-term path;
the two can coexist behind a feature flag.
