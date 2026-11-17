//! The `openh264-sys2` surface ZapFast uses, for every platform.
//!
//! ZapFast calls the raw API for one thing only: moving a running encoder's
//! bitrate. On the desktop this re-exports the generated bindings unchanged.
//! HarmonyOS uses the stand-in in `ohos.rs`, whose values keep the same shapes
//! so the call site is the same.

#[cfg(not(target_env = "ohos"))]
pub use upstream::*;

#[cfg(target_env = "ohos")]
mod ohos;
#[cfg(target_env = "ohos")]
pub use ohos::*;
