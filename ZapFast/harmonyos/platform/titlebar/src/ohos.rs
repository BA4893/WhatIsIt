//! The part of fastframe-titlebar ZapFast's interface uses, for HarmonyOS.
//!
//! HarmonyOS decorates its own windows: there is no traffic-light strip to
//! align, no drawn caption buttons, and no title bar of ours to drag. The
//! interface asks this crate the same questions everywhere, so the answers
//! here are simply "nothing": zero caption footprint, no buttons, and no
//! window dragging from the app (the system's title bar does that). Keep the
//! signatures identical to the desktop crate so no view needs a platform
//! branch of its own.

use egui::{Color32, Context, Rect, Ui};

/// The traffic lights' width on macOS. There are none here.
pub const TRAFFIC_LIGHTS_WIDTH: f32 = 0.0;

/// The buttons a layout can hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Minimize,
    Maximize,
    Restore,
    Close,
}

/// The buttons at each end of the caption row.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Layout {
    /// The buttons at the left end, from the edge inwards.
    pub left: Vec<Button>,
    /// The buttons at the right end, from the inside out to the edge.
    pub right: Vec<Button>,
}

/// The caption buttons' glyphs and fills.
#[derive(Clone, Copy, Debug)]
pub struct Style {
    /// The glyphs' colour.
    pub icon: Color32,
    /// The round buttons' fill.
    pub button: Color32,
    /// The height of the header the buttons are centred in.
    pub header_height: f32,
}

/// The buttons' tooltips and accessible names, in the app's language.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Labels<'a> {
    /// Minimize.
    pub minimize: &'a str,
    /// Maximize.
    pub maximize: &'a str,
    /// Restore, on Maximize while maximized.
    pub restore: &'a str,
    /// Close.
    pub close: &'a str,
}

/// The room the caption buttons take at each end of a header.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Footprint {
    /// Width taken at the left end.
    pub left: f32,
    /// Width taken at the right end.
    pub right: f32,
    /// Height of the caption row the buttons sit in.
    pub height: f32,
}

/// Where a header's own controls go beside the caption buttons.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Reserve {
    /// Width to leave free at the header's right end.
    pub inline_width: f32,
    /// How far to move the header down, under the caption row.
    pub push_down: f32,
}

impl Footprint {
    /// There are no caption buttons, so a header keeps its full width.
    pub fn reserve(&self, _width: f32, _min_content: f32) -> Reserve {
        Reserve::default()
    }
}

/// Installs the icons the caption buttons would use; there are none.
pub fn install(_ctx: &Context) {}

/// Chooses whether ZapFast draws its own title bar. HarmonyOS never does.
pub fn set_enabled(_on: bool) {}

/// Whether ZapFast draws its own title bar. Never on HarmonyOS.
pub fn enabled() -> bool {
    false
}

/// The caption buttons' room at a header of `header_height`.
pub fn footprint(_ctx: &Context, _header_height: f32) -> Footprint {
    Footprint::default()
}

/// Where the buttons would sit.
pub fn layout() -> Layout {
    Layout::default()
}

/// Draws the caption buttons. There are none.
pub fn controls(_ui: &mut Ui, _style: &Style, _labels: &Labels<'_>) {}

/// Draws the window's resize edges. HarmonyOS draws its own.
pub fn resize(_ui: &mut Ui) {}

/// Makes `rect` drag the window. The system's title bar does that.
pub fn drag(_ui: &mut Ui, _rect: Rect) {}
