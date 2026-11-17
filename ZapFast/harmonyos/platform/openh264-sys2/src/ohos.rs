#![allow(non_camel_case_types)] // C names, kept as the library spells them.

//! The two openh264 values ZapFast touches, for HarmonyOS.
//!
//! A call's camera moves a running encoder's bitrate through the raw API; on
//! the desktop that is openh264's own `SBitrateInfo` and
//! `ENCODER_OPTION_BITRATE`. The stand-in encoder accepts the same values and
//! refuses them (it has no encoder), so the call site is unchanged.

/// Which openh264 encoder option a raw call names.
pub type ENCODER_OPTION = i32;

/// Which spatial layer of the encoder a raw call names.
pub type LAYER_NUM = i32;

/// The bitrate option, as openh264 numbers it.
pub const ENCODER_OPTION_BITRATE: ENCODER_OPTION = 5;

/// Every spatial layer, as openh264 names it.
pub const SPATIAL_LAYER_ALL: LAYER_NUM = 4;

/// A bitrate change, as openh264 expects it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(C)]
#[allow(non_snake_case)] // The C library names these fields; keep its spelling.
pub struct SBitrateInfo {
    /// The layer, or [`SPATIAL_LAYER_ALL`].
    pub iLayer: LAYER_NUM,
    /// The maximum bitrate, in bits per second.
    pub iBitrate: std::os::raw::c_int,
}
