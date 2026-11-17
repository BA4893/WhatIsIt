//! The `fastframe-dock` surface ZapFast builds against, for every platform.
//!
//! On the desktop this is the upstream crate itself, re-exported unchanged:
//! the application's behaviour and the tests are the ones the crate ships.
//! HarmonyOS has no platform layer in that crate (it targets a desktop window
//! manager, sound server or launcher), so there the module below stands in
//! with the same names and signatures and HarmonyOS's own behaviour. ZapFast
//! therefore needs no platform branches at its call sites, and the desktop
//! build still uses the crate itself.
//!
//! This is not a fork: no source of `fastframe-dock` is copied, and the desktop
//! path depends on it at the pinned revision. The HarmonyOS half is ZapFast's
//! own platform code, living beside the port it belongs to.

#[cfg(not(target_env = "ohos"))]
pub use upstream::*;

#[cfg(target_env = "ohos")]
mod ohos;
#[cfg(target_env = "ohos")]
pub use ohos::*;
