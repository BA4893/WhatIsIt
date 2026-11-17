# Path A — native chrome + visible WhatsApp Web

This is the working-app path. It removes the hidden-WebView bridge from the startup path.

## Structure

```
HybridShell (entry page)
├── native header        WhatIsIt / WhatsApp Web / reload
├── native navigation    Chats · Updates · Calls · Communities · Settings
└── content
    ├── Chats           visible WhatsApp Web
    ├── Updates         native UpdatesPane
    ├── Calls           native CallsPane
    ├── Communities     native CommunitiesPane
    └── Settings        native SettingsPane
```

- The WebView stays mounted when switching tabs, so the WhatsApp Web session is preserved.
- There is no `javaScriptOnDocumentStart` shim, no `WhatsAppWebBridge`, no Store polling and no hidden link gate.
- QR/phone login happens in the visible WebView, exactly as WhatsApp Web expects.
- Native panes cover the WebView for non-Chats tabs.

## Phone one-pane layout

On phone widths, `PHONE_LAYOUT_JS` injects a one-pane slide adapter into WhatsApp Web:

- chat list fills the width when no chat is open;
- `#side` and `#main` become fixed full-viewport panels;
- tapping a thread slides the list left and the conversation in from the right (220 ms);
- a left-edge right swipe slides back to threads;
- the native **List** button also returns to the chat list;
- pinch zoom is disabled (`zoomAccess(false)` and `user-scalable=no`);
- the WhatsApp Web desktop navigation rail is hidden by geometry;
- QR/login is untouched.

This uses WhatsApp Web's `#side`, `#main` and `#pane-side` structure, so it is a selector-dependent adapter rather than a custom responsive client.

## Phone fit

On phone widths the header has **Fit phone**. It sets a synthetic 820 px viewport at 0.44 initial scale and enables pinch zoom, so the desktop/tablet WhatsApp Web layout fits the phone until a true responsive client exists. Tablet/desktop keep the natural viewport. This is a scaling workaround, not a responsive redesign.

## Why

The hidden-WebView bridge was the fragile part: ArkWeb lifecycle, DOM selectors, Store module names and link-state scraping. The WebView itself works. Path A keeps the proven part and puts native ArkUI around it.

## Native takeover toggle

The Chats header has **Web / Native**. Native shows the existing `ChatsPane` and `ConversationView` with `WhatsAppStore` sample data, and opens local threads. The WebView stays mounted behind it, so switching back to Web preserves the WhatsApp Web session. Real native chat data still requires the engine/bridge; the toggle proves the layout and interaction without the hidden DOM dependency.

## Incremental native takeover

The content area is isolated in `HybridShell.WebContent()`. A native Chats implementation can replace it later without changing the header, navigation, Settings or window layout.

## Routes

`EntryAbility` now loads `pages/HybridShell`. `pages/Index` is kept for the experimental bridge path but is no longer the entry page.

## Build

```zsh
# same hvigor build as before
```

The HAP is unsigned when built from this CLI; sign it with DevEco or `hap-sign-tool`.
