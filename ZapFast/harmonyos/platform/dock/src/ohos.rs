//! The part of fastframe-dock ZapFast's notification layer uses, for
//! HarmonyOS.
//!
//! A HarmonyOS app's unread count belongs to the launcher's own badge API,
//! reached through the app's ArkTS side, not to a Linux `.desktop` entry or a
//! Windows taskbar overlay. This keeps the count in memory until that bridge
//! exists, so the rest of ZapFast (and the decisions that ask how many chats
//! are unread) behaves exactly as on the desktop.

/// The application-wide unread count.
#[derive(Default)]
pub struct Badge {
    count: Option<u32>,
}

impl Badge {
    /// Creates a badge for a desktop entry. HarmonyOS needs no entry name.
    pub fn new(_desktop_entry: impl Into<String>) -> Self {
        Self::default()
    }

    /// Shows a count, or clears the badge at zero.
    pub fn set(&mut self, count: u32) {
        self.count = Some(count);
    }

    /// The last accepted count, or `None` before the first update.
    pub fn count(&self) -> Option<u32> {
        self.count
    }
}

/// A no-op taskbar overlay. Windows draws one; HarmonyOS has no taskbar.
#[derive(Default)]
pub struct Taskbar;

/// HarmonyOS has no Dock icon to replace; a packaged HAP keeps its own.
pub fn set_icon(_encoded_image: &[u8]) -> Result<bool, IconError> {
    Ok(false)
}

/// Why an application icon could not be set.
#[derive(Debug)]
pub struct IconError;

impl std::fmt::Display for IconError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HarmonyOS keeps the packaged app icon")
    }
}

impl std::error::Error for IconError {}

/// Shows or hides the Dock icon. HarmonyOS has none to hide.
pub fn set_dock_icon_visible(_visible: bool) -> bool {
    false
}

/// The launcher badge count is Unity's and macOS's; nothing to publish.
pub fn badge_description(count: u32) -> String {
    count.to_string()
}
