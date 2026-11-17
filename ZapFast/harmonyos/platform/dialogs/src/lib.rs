//! The `rfd` surface ZapFast uses, for every platform.
//!
//! On the desktop this is rfd itself, unchanged. HarmonyOS picks files
//! through ArkUI's own pickers (`PhotoViewPicker`, `DocumentViewPicker`,
//! `AudioViewPicker`), which need a UIAbility context and so belong to the
//! ArkTS side. Until that bridge lands, every dialog here answers "nothing
//! was chosen", which is what a cancelled dialog answers: attaching a file or
//! choosing a save path reports that the person cancelled, and nothing else
//! changes.

#[cfg(not(target_env = "ohos"))]
pub use upstream::*;

#[cfg(target_env = "ohos")]
mod ohos;
#[cfg(target_env = "ohos")]
pub use ohos::*;
