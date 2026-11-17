//! The clipboard on HarmonyOS: text goes through egui and the NAPI bridge;
//! pictures and file lists have no bridge yet.
//!
//! Text copies are already handled above this crate: ZapFast calls
//! `egui::Context::copy_text`, egui emits `OutputCommand::CopyText`, and the
//! XComponent host hands it to ArkTS, which writes it to the system
//! pasteboard. Pastes arrive the other way as `egui::Event::Paste`. What is
//! left for this module is the clipboard's pictures and file lists, reached
//! only by arboard on the desktop. Every read reports that there is nothing;
//! every write reports that HarmonyOS cannot take it yet, so the interface
//! says so instead of pretending it worked.

use std::borrow::Cow;
use std::path::PathBuf;

/// Why a clipboard operation failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// The clipboard holds nothing of the requested kind.
    ContentNotAvailable,
    /// Another program holds the clipboard.
    ClipboardOccupied,
    /// The content could not be represented.
    ConversionFailure,
    /// A platform-specific failure.
    Unknown { description: String },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ContentNotAvailable => f.write_str("the clipboard holds nothing of that kind"),
            Self::ClipboardOccupied => f.write_str("another program holds the clipboard"),
            Self::ConversionFailure => f.write_str("the clipboard content could not be read"),
            Self::Unknown { description } => f.write_str(description),
        }
    }
}

impl std::error::Error for Error {}

/// A clipboard handle.
#[derive(Debug, Default)]
pub struct Clipboard;

/// An RGBA picture, as arboard describes one.
#[derive(Clone, Debug)]
pub struct ImageData<'a> {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// Straight-alpha RGBA bytes, width times height times four.
    pub bytes: Cow<'a, [u8]>,
}

impl Clipboard {
    /// Opens the clipboard. HarmonyOS needs no connection; this never fails.
    pub fn new() -> Result<Self, Error> {
        Ok(Self)
    }

    /// The clipboard's text.
    pub fn get_text(&mut self) -> Result<String, Error> {
        Err(Error::ContentNotAvailable)
    }

    /// Puts text on the clipboard. Text copies go through egui's own output
    /// and the NAPI bridge; this path is not used by the app.
    pub fn set_text(&mut self, _text: impl Into<String>) -> Result<(), Error> {
        Err(Error::Unknown {
            description: "text copies go through the HarmonyOS bridge".to_owned(),
        })
    }

    /// What else the clipboard holds: pictures and file lists.
    pub fn get(&mut self) -> Get<'_> {
        Get { _clipboard: self }
    }

    /// The clipboard's picture.
    pub fn get_image(&mut self) -> Result<ImageData<'static>, Error> {
        Err(Error::ContentNotAvailable)
    }

    /// Puts a picture on the clipboard. HarmonyOS's pasteboard takes pixels
    /// through an ArkTS `PixelMap`, which the bridge does not carry yet.
    pub fn set_image(&mut self, _image: ImageData<'_>) -> Result<(), Error> {
        Err(Error::Unknown {
            description: "pictures do not reach the HarmonyOS pasteboard yet".to_owned(),
        })
    }
}

/// A clipboard read of something other than text.
pub struct Get<'a> {
    _clipboard: &'a mut Clipboard,
}

impl Get<'_> {
    /// The files a file manager put on the clipboard.
    pub fn file_list(&mut self) -> Result<Vec<PathBuf>, Error> {
        Err(Error::ContentNotAvailable)
    }
}
