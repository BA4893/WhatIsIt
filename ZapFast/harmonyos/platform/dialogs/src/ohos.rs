//! File and folder dialogs on HarmonyOS.
//!
//! ArkUI's pickers (`PhotoViewPicker`, `DocumentViewPicker`, `AudioViewPicker`)
//! need a `UIAbilityContext` and run on the ArkTS side, so they belong to the
//! app's NAPI bridge. Until that bridge lands, each dialog answers what a
//! cancelled dialog answers: `None`. The worker then reports that the person
//! cancelled, which is its existing path, and nothing else changes. No dialog
//! is ever faked as successful.

use std::path::{Path, PathBuf};

/// A file dialog with no platform behind it yet.
#[derive(Clone, Debug, Default)]
pub struct FileDialog {
    title: Option<String>,
    file_name: Option<String>,
    directory: Option<PathBuf>,
}

impl FileDialog {
    /// A dialog that is not configured yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// The dialog's title.
    pub fn set_title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self
    }

    /// A filter of extensions, named in the dialog.
    pub fn add_filter(self, _name: impl Into<String>, _extensions: &[impl AsRef<str>]) -> Self {
        self
    }

    /// The file name a save dialog starts with.
    pub fn set_file_name(mut self, name: impl Into<String>) -> Self {
        self.file_name = Some(name.into());
        self
    }

    /// The directory a dialog starts in.
    pub fn set_directory(mut self, path: impl AsRef<Path>) -> Self {
        self.directory = Some(path.as_ref().to_path_buf());
        self
    }

    /// One file, or `None` when the person cancelled.
    pub fn pick_file(self) -> Option<PathBuf> {
        self.log();
        None
    }

    /// Several files, or `None` when the person cancelled.
    pub fn pick_files(self) -> Option<Vec<PathBuf>> {
        self.log();
        None
    }

    /// A folder, or `None` when the person cancelled.
    pub fn pick_folder(self) -> Option<PathBuf> {
        self.log();
        None
    }

    /// A save path, or `None` when the person cancelled.
    pub fn save_file(self) -> Option<PathBuf> {
        self.log();
        None
    }

    fn log(&self) {
        log::info!(
            "the HarmonyOS picker for {:?} is not bridged yet; reporting a cancelled dialog",
            self.title.as_deref().unwrap_or("a file")
        );
    }
}

/// A message dialog. HarmonyOS shows alerts through ArkUI, so none is drawn
/// here; the caller's own toast still appears.
#[derive(Clone, Debug, Default)]
pub struct MessageDialog {
    title: Option<String>,
    description: Option<String>,
}

impl MessageDialog {
    /// A dialog that is not configured yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// The dialog's title.
    pub fn set_title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self
    }

    /// The dialog's text.
    pub fn set_description(mut self, description: impl Into<String>) -> Self {
        self.description = Some(description.into());
        self
    }

    /// Shows the dialog; HarmonyOS has no native one from here yet.
    pub fn show(self) {
        log::info!(
            "message dialog {:?} is shown as a toast only on HarmonyOS",
            self.title.as_deref().unwrap_or("")
        );
    }
}
