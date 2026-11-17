//! The `openh264` surface ZapFast uses, for every platform.
//!
//! On the desktop this is the openh264 crate, unchanged. openh264-sys2's build
//! script has no HarmonyOS target, and the NDK ships the system's own H.264
//! codec through `OH_VideoDecoder`/`OH_VideoEncoder` (AVCodec) instead, so
//! HarmonyOS gets a stand-in with the same names until that backend is bound:
//! it starts, reports that a frame cannot be decoded or encoded, and the call
//! and media screens say so. Nothing pretends a picture arrived.

#[cfg(not(target_env = "ohos"))]
pub use upstream::*;

#[cfg(target_env = "ohos")]
mod ohos;
#[cfg(target_env = "ohos")]
pub use ohos::*;
