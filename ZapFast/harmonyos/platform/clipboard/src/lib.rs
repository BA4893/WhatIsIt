//! The `arboard` surface ZapFast uses, for every platform.
//!
//! On the desktop this is arboard itself, unchanged. HarmonyOS has no X11 or
//! Wayland clipboard; its pasteboard belongs to the ArkUI side, reached from
//! this port's NAPI bridge. Text copies go through egui's own `CopyText`
//! output, which the XComponent host hands to ArkTS, and pastes arrive as
//! egui `Paste` events from the bridge: this module is what remains for the
//! clipboard's pictures and file lists, which the bridge does not carry yet.

#[cfg(not(target_env = "ohos"))]
pub use upstream::*;

#[cfg(target_env = "ohos")]
mod ohos;
#[cfg(target_env = "ohos")]
pub use ohos::*;
