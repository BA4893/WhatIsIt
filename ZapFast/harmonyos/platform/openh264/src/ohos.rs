//! H.264 encode and decode on HarmonyOS, until AVCodec is bound.
//!
//! The desktop uses openh264, whose `openh264-sys2` build script has no
//! HarmonyOS target. HarmonyOS has the codec in the system through AVCodec's
//! `OH_VideoDecoder` and `OH_VideoEncoder`, but binding those is a separate
//! piece of work; this module keeps the interface ZapFast calls so the rest of
//! the app works, and answers that no picture was produced. A video message
//! shows that it cannot play here; a call's camera stays receive-only, which
//! is the same path a camera that cannot open takes.
//!
//! Nothing here claims a frame decoded: `decode` returns an error and `encode`
//! returns an error, so a caller's own error paths run.

/// Why an encoder or decoder did not do its work.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

fn unavailable() -> Error {
    Error("H.264 needs HarmonyOS's AVCodec, which this build does not bind yet".to_owned())
}

/// The library an encoder or decoder is built from.
#[derive(Debug, Clone, Copy, Default)]
pub struct OpenH264API;

impl OpenH264API {
    /// The library built from source on the desktop; here there is none.
    pub fn from_source() -> Self {
        Self
    }
}

/// The picture layouts an encoder and decoder exchange.
pub mod formats {
    /// A YUV 4:2:0 picture, in three planes.
    pub trait YUVSource {
        /// Width and height.
        fn dimensions(&self) -> (usize, usize);
        /// Row lengths of the luma, blue-difference and red-difference planes.
        fn strides(&self) -> (usize, usize, usize);
        /// The luma plane.
        fn y(&self) -> &[u8];
        /// The blue-difference plane.
        fn u(&self) -> &[u8];
        /// The red-difference plane.
        fn v(&self) -> &[u8];

        /// Writes straight-alpha RGBA, as openh264's own helper does. The
        /// stand-in never produces a picture, so this only exists for callers
        /// that name it.
        fn write_rgba8(&self, dst: &mut [u8]) {
            for pixel in dst.chunks_exact_mut(4) {
                pixel[3] = 255;
            }
        }
    }

    /// Three borrowed planes.
    pub struct YUVSlices<'a> {
        y: &'a [u8],
        u: &'a [u8],
        v: &'a [u8],
        size: (usize, usize),
        strides: (usize, usize, usize),
    }

    impl<'a> YUVSlices<'a> {
        /// Borrows planes of `size`, with their row lengths.
        pub fn new(
            (y, u, v): (&'a [u8], &'a [u8], &'a [u8]),
            size: (usize, usize),
            strides: (usize, usize, usize),
        ) -> Self {
            Self {
                y,
                u,
                v,
                size,
                strides,
            }
        }
    }

    impl YUVSource for YUVSlices<'_> {
        fn dimensions(&self) -> (usize, usize) {
            self.size
        }

        fn strides(&self) -> (usize, usize, usize) {
            self.strides
        }

        fn y(&self) -> &[u8] {
            self.y
        }

        fn u(&self) -> &[u8] {
            self.u
        }

        fn v(&self) -> &[u8] {
            self.v
        }
    }
}

/// A picture out of the decoder.
pub mod decoder {
    use super::formats::YUVSource;
    use super::{Error, OpenH264API};

    /// A decoded picture, borrowed from its decoder.
    pub struct DecodedYUV<'a> {
        _borrow: std::marker::PhantomData<&'a mut ()>,
    }

    impl YUVSource for DecodedYUV<'_> {
        fn dimensions(&self) -> (usize, usize) {
            (0, 0)
        }

        fn strides(&self) -> (usize, usize, usize) {
            (0, 0, 0)
        }

        fn y(&self) -> &[u8] {
            &[]
        }

        fn u(&self) -> &[u8] {
            &[]
        }

        fn v(&self) -> &[u8] {
            &[]
        }
    }

    /// How the decoder treats the frames waiting after one is decoded.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Flush {
        /// Decode every picture in the access unit at once.
        NoFlush,
        /// Wait for the next access unit.
        Flush,
    }

    /// How a decoder is set up.
    #[derive(Debug, Clone, Default)]
    pub struct DecoderConfig {
        _private: (),
    }

    impl DecoderConfig {
        /// The defaults.
        pub fn new() -> Self {
            Self::default()
        }

        /// Whether to flush after each decode.
        pub fn flush_after_decode(self, _flush: Flush) -> Self {
            self
        }
    }

    /// An H.264 decoder.
    #[derive(Debug, Default)]
    pub struct Decoder {
        _private: (),
    }

    impl Decoder {
        /// A decoder with openh264's default configuration.
        pub fn new() -> Result<Self, Error> {
            Self::with_api_config(OpenH264API::from_source(), DecoderConfig::new())
        }

        /// A decoder from the named library and configuration.
        pub fn with_api_config(_api: OpenH264API, _config: DecoderConfig) -> Result<Self, Error> {
            Ok(Self::default())
        }

        /// Decodes one access unit, or says that this build cannot.
        pub fn decode(&mut self, _data: &[u8]) -> Result<Option<DecodedYUV<'_>>, Error> {
            Err(super::unavailable())
        }

        /// The pictures still waiting in the decoder.
        pub fn flush_remaining(&mut self) -> Result<Vec<DecodedYUV<'_>>, Error> {
            Err(super::unavailable())
        }
    }
}

/// An encoder's output.
pub mod encoder {
    use std::os::raw::c_void;

    use super::formats::YUVSource;
    use super::{Error, OpenH264API};

    /// The H.264 profile to encode at.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Profile {
        /// Constrained Baseline, which WhatsApp's clients decode.
        Baseline,
        /// Main profile.
        Main,
        /// High profile.
        High,
    }

    /// How the encoder spends its bitrate.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum RateControlMode {
        /// Keep to the bitrate.
        Bitrate,
        /// Keep to a quality.
        Quality,
    }

    /// A target bitrate.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct BitRate(u32);

    impl BitRate {
        /// Bits per second.
        pub fn from_bps(bps: u32) -> Self {
            Self(bps)
        }
    }

    /// A frame rate.
    #[derive(Debug, Clone, Copy, PartialEq)]
    pub struct FrameRate(f32);

    impl FrameRate {
        /// Frames per second.
        pub fn from_hz(hz: f32) -> Self {
            Self(hz)
        }
    }

    /// How often a keyframe goes out.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct IntraFramePeriod(u32);

    impl IntraFramePeriod {
        /// A period in frames.
        pub fn from_num_frames(frames: u32) -> Self {
            Self(frames)
        }
    }

    /// How an encoder is set up.
    #[derive(Debug, Clone, Default)]
    pub struct EncoderConfig {
        _private: (),
    }

    impl EncoderConfig {
        /// The defaults.
        pub fn new() -> Self {
            Self::default()
        }

        /// The H.264 profile.
        pub fn profile(self, _profile: Profile) -> Self {
            self
        }

        /// The target bitrate.
        pub fn bitrate(self, _bitrate: BitRate) -> Self {
            self
        }

        /// How the bitrate is spent.
        pub fn rate_control_mode(self, _mode: RateControlMode) -> Self {
            self
        }

        /// The frame rate.
        pub fn max_frame_rate(self, _rate: FrameRate) -> Self {
            self
        }

        /// How often a keyframe goes out.
        pub fn intra_frame_period(self, _period: IntraFramePeriod) -> Self {
            self
        }

        /// Whether frames may be skipped.
        pub fn skip_frames(self, _skip: bool) -> Self {
            self
        }
    }

    /// An encoded access unit.
    #[derive(Debug, Default)]
    pub struct EncodedBitStream {
        bytes: Vec<u8>,
    }

    impl EncodedBitStream {
        /// Appends the bytes to `out`.
        pub fn write_vec(&self, out: &mut Vec<u8>) {
            out.extend_from_slice(&self.bytes);
        }

        /// The bytes.
        pub fn to_vec(&self) -> Vec<u8> {
            self.bytes.clone()
        }
    }

    /// The encoder's raw interface, for options its wrapper does not expose.
    pub struct RawEncoder<'a> {
        _encoder: &'a mut Encoder,
    }

    impl RawEncoder<'_> {
        /// Sets an openh264 encoder option; this stand-in refuses every one.
        ///
        /// # Safety
        ///
        /// As openh264's own: `value` must point at a value of the option's
        /// type, and the encoder must be initialised. The stand-in reads
        /// neither.
        pub unsafe fn set_option(&mut self, _option: i32, _value: *mut c_void) -> i32 {
            -1
        }
    }

    /// An H.264 encoder.
    #[derive(Debug, Default)]
    pub struct Encoder {
        _private: (),
    }

    impl Encoder {
        /// An encoder with openh264's default configuration.
        pub fn new() -> Result<Self, Error> {
            Self::with_api_config(OpenH264API::from_source(), EncoderConfig::new())
        }

        /// An encoder from the named library and configuration.
        pub fn with_api_config(_api: OpenH264API, _config: EncoderConfig) -> Result<Self, Error> {
            Ok(Self::default())
        }

        /// Encodes one picture, or says that this build cannot.
        pub fn encode(&mut self, _yuv: &impl YUVSource) -> Result<EncodedBitStream, Error> {
            Err(super::unavailable())
        }

        /// Asks for the next frame to be a keyframe.
        pub fn force_intra_frame(&mut self) {}

        /// The raw interface.
        pub fn raw_api(&mut self) -> RawEncoder<'_> {
            RawEncoder { _encoder: self }
        }
    }
}
