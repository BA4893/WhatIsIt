//! The part of fastframe-audio ZapFast uses, on HarmonyOS.
//!
//! This keeps ZapFast's audio layer, its clocks, and its interface behaviour
//! intact while the device streams are not yet bound to OHAudio: an output
//! still paces frames in real time and asks its [`Render`] for sound, and an
//! input still asks its [`Capture`] for blocks at the rate it opened, but
//! nothing reaches the speakers or the microphone. The UI therefore plays
//! and records as it does on the desktop (positions, waveforms, call timing)
//! without sound. The next step is to implement the same surface on
//! `libohaudio.so`'s `OH_AudioStreamBuilder`, which is present in the
//! HarmonyOS NDK; nothing above this crate changes when that lands.
//!
//! Keep this API identical to the desktop crate: ZapFast's `audio` and
//! `call_audio` modules must not need a HarmonyOS branch.

use std::sync::{
    Arc, Mutex, PoisonError,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::Duration;

/// How long a block the silent output renders: 10 ms at 48 kHz.
const BLOCK_FRAMES: usize = 480;

/// A device's own id, to save in settings and open the same device later.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeviceId(String);

impl DeviceId {
    /// An id read back from settings.
    pub fn new(saved: impl Into<String>) -> Self {
        Self(saved.into())
    }

    /// The id as a string, to save.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for DeviceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Which device to open.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Device {
    /// The system's default device.
    #[default]
    Default,
    /// A device by its id.
    Id(DeviceId),
    /// A device by its name.
    Named(String),
}

impl Device {
    fn id(&self) -> DeviceId {
        match self {
            Self::Id(id) => id.clone(),
            Self::Named(name) => DeviceId(name.clone()),
            Self::Default => DeviceId::new("default"),
        }
    }

    fn name(&self) -> String {
        match self {
            Self::Id(id) => id.as_str().to_owned(),
            Self::Named(name) => name.clone(),
            Self::Default => "Default".to_owned(),
        }
    }
}

/// A device a picker can offer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceInfo {
    /// Its id, to save and open it by.
    pub id: DeviceId,
    /// Its name, to show.
    pub name: String,
    /// Whether it is the system's default device just now.
    pub is_default: bool,
}

/// A buffer size, in frames or as a duration at the stream's rate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BufferSize {
    /// Frames, whatever the sample rate.
    Frames(u32),
    /// A duration, turned into frames at the stream's sample rate.
    Duration(Duration),
}

/// The device's buffer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Buffer {
    /// The driver's own size.
    #[default]
    Driver,
    /// A fixed size on every platform.
    Fixed(BufferSize),
    /// A fixed size on Windows; the driver's own elsewhere.
    FixedOnWindows(BufferSize),
}

/// What kind of sound a stream carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum StreamRole {
    /// Music playback.
    Music,
    /// The sound of a video or film.
    Movie,
    /// Game sound.
    Game,
    /// Calls and other two-way voice.
    Communication,
    /// Notifications and alerts.
    Notification,
    /// Music production.
    Production,
    /// Screen readers and other accessibility output.
    Accessibility,
}

/// The app's name and icon in the system's volume mixer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppInfo {
    /// The app's name as users know it.
    pub name: String,
    /// The app's icon, by its icon name.
    pub icon: Option<String>,
}

/// What fills the output with sound. It runs on the audio thread.
pub trait Render: Send + 'static {
    /// The stream's sample rate and channel count.
    fn configure(&mut self, sample_rate: u32, channels: u16);

    /// Fills `out` with interleaved samples.
    fn render(&mut self, out: &mut [f32]);

    /// Whether the renderer has nothing to play.
    fn idle(&self) -> bool {
        false
    }
}

/// What takes the sound an [`Input`] captures. It runs on the audio thread.
pub trait Capture: Send + 'static {
    /// The stream's sample rate and channel count.
    fn configure(&mut self, sample_rate: u32, channels: u16);

    /// Takes interleaved samples.
    fn capture(&mut self, input: &[f32]);
}

/// How far a stream has played or captured, readable from any thread.
#[derive(Clone, Debug, Default)]
pub struct Clock(Arc<ClockState>);

#[derive(Debug, Default)]
struct ClockState {
    played_nanos: AtomicU64,
    latency_nanos: AtomicU64,
    capturing: AtomicBool,
    underruns: AtomicU64,
}

impl Clock {
    /// How much sound the stream has played (or captured).
    pub fn played(&self) -> Duration {
        Duration::from_nanos(self.0.played_nanos.load(Ordering::Acquire))
    }

    /// The stream's latency, as the device reports it.
    pub fn latency(&self) -> Duration {
        Duration::from_nanos(self.0.latency_nanos.load(Ordering::Acquire))
    }

    /// How many times the device played silence because a callback came too
    /// late. Never, without a device stream.
    pub fn underruns(&self) -> u64 {
        self.0.underruns.load(Ordering::Relaxed)
    }
}

/// What an output or input stream reports that the app may care about.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputError {
    kind: ErrorKind,
    message: String,
}

/// How to treat a stream error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// What is playing or recording can carry on.
    Recoverable,
    /// It has to stop.
    Fatal,
}

impl OutputError {
    /// How to treat it.
    #[must_use]
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// Whether what is playing or recording has to stop.
    #[must_use]
    pub fn is_fatal(&self) -> bool {
        self.kind == ErrorKind::Fatal
    }
}

impl std::fmt::Display for OutputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for OutputError {}

/// Why an output or an input could not be opened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenError {
    /// There is no device that way.
    NoDevice,
    /// The device refused.
    Device(OutputError),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoDevice => f.write_str("There is no audio device."),
            Self::Device(error) => write!(f, "Cannot open the audio device: {error}"),
        }
    }
}

impl std::error::Error for OpenError {}

/// Why the output or input opened its stream again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    /// The stream failed or its device went away.
    Failed,
    /// The default device changed.
    DefaultChanged,
    /// A device let go after a pause was taken back.
    Resumed,
    /// The clock stood still without an error.
    Stalled,
}

/// What [`Output::maintain`] or [`Input::maintain`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Maintained {
    /// Nothing changed.
    Unchanged,
    /// A new stream is playing, possibly on another device.
    Reopened {
        /// The device's name.
        device: String,
        /// The new stream's sample rate.
        sample_rate: u32,
        /// The new stream's channel count.
        channels: u16,
        /// Why.
        reason: Reason,
    },
    /// The device was let go.
    Released,
    /// The stream could not be opened again.
    Failed(OpenError),
}

/// How to open an [`Output`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputOptions {
    /// The device.
    pub device: Device,
    /// Channels to ask for; `0` takes the device's own.
    pub channels: u16,
    /// A sample rate to try first.
    pub sample_rate: Option<u32>,
    /// The device's buffer.
    pub buffer: Buffer,
    /// Calls [`Render::render`] in blocks of at most this many frames.
    pub max_block_frames: Option<u32>,
    /// Move to the new default output when it changes.
    pub follow_default: bool,
    /// Let the device go after the output has been paused this long.
    pub release_after: Option<Duration>,
    /// Pause the output once [`Render::idle`] has said so for this long.
    pub pause_when_idle: Option<Duration>,
    /// The stream's name in the system's volume mixer.
    pub media_name: Option<String>,
    /// What the stream carries.
    pub role: Option<StreamRole>,
}

impl Default for OutputOptions {
    fn default() -> Self {
        Self {
            device: Device::Default,
            channels: 2,
            sample_rate: None,
            buffer: Buffer::Driver,
            max_block_frames: None,
            follow_default: true,
            release_after: Some(Duration::from_secs(5 * 60)),
            pause_when_idle: None,
            media_name: None,
            role: None,
        }
    }
}

/// How to open an [`Input`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputOptions {
    /// The device.
    pub device: Device,
    /// Channels the capturer takes; `0`, the default, takes the source's own.
    pub channels: u16,
    /// A sample rate to try first.
    pub sample_rate: Option<u32>,
    /// The device's buffer.
    pub buffer: Buffer,
    /// Move to the new default input when it changes.
    pub follow_default: bool,
    /// The stream's name in the system's volume mixer.
    pub media_name: Option<String>,
    /// What the stream carries.
    pub role: Option<StreamRole>,
}

impl Default for InputOptions {
    fn default() -> Self {
        Self {
            device: Device::Default,
            channels: 0,
            sample_rate: None,
            buffer: Buffer::Driver,
            follow_default: true,
            media_name: None,
            role: None,
        }
    }
}

/// A stream that renders in real time but reaches no speaker.
pub struct Output<R: Render> {
    clock: Clock,
    sample_rate: u32,
    channels: u16,
    device_id: DeviceId,
    device_name: String,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// Keeps the renderer alive while the audio thread asks it for sound.
    _renderer: Arc<Mutex<R>>,
}

impl<R: Render> std::fmt::Debug for Output<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Output")
            .field("sample_rate", &self.sample_rate)
            .field("channels", &self.channels)
            .finish_non_exhaustive()
    }
}

impl<R: Render> Output<R> {
    /// Opens the device and starts playing through `renderer`. The stream is
    /// configured before this returns, so the app can connect to it.
    pub fn open(options: OutputOptions, mut renderer: R) -> Result<Self, OpenError> {
        let sample_rate = options.sample_rate.unwrap_or(48_000);
        let channels = if options.channels == 0 {
            2
        } else {
            options.channels
        };
        renderer.configure(sample_rate, channels);
        let renderer = Arc::new(Mutex::new(renderer));
        let clock = Clock::default();
        let paused = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let renderer = Arc::clone(&renderer);
            let clock = clock.clone();
            let paused = Arc::clone(&paused);
            let stop = Arc::clone(&stop);
            std::thread::Builder::new()
                .name("sound-output".to_owned())
                .spawn(move || {
                    let block_nanos =
                        (BLOCK_FRAMES as u64 * 1_000_000_000) / u64::from(sample_rate.max(1));
                    let mut buffer = vec![0f32; BLOCK_FRAMES * usize::from(channels)];
                    while !stop.load(Ordering::Acquire) {
                        if paused.load(Ordering::Acquire) {
                            std::thread::sleep(Duration::from_millis(10));
                            continue;
                        }
                        {
                            let mut renderer =
                                renderer.lock().unwrap_or_else(PoisonError::into_inner);
                            renderer.render(&mut buffer);
                        }
                        clock
                            .0
                            .played_nanos
                            .fetch_add(block_nanos, Ordering::AcqRel);
                        std::thread::sleep(Duration::from_nanos(block_nanos));
                    }
                })
                .ok()
        };
        Ok(Self {
            clock,
            sample_rate,
            channels,
            device_id: options.device.id(),
            device_name: options.device.name(),
            paused,
            stop,
            thread,
            _renderer: renderer,
        })
    }

    /// Stops the device asking for sound.
    pub fn pause(&mut self) {
        self.paused.store(true, Ordering::Release);
    }

    /// Has the device ask for sound again.
    pub fn resume(&mut self) {
        self.paused.store(false, Ordering::Release);
    }

    /// Whether the output is paused.
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    /// Whether the stream has failed. Never, without a device stream.
    #[must_use]
    pub fn failed(&self) -> bool {
        false
    }

    /// Keeps the output on a working device.
    pub fn maintain(&mut self) -> Maintained {
        Maintained::Unchanged
    }

    /// Drops the errors the stream reported since the last call.
    pub fn take_errors(&mut self) -> Vec<OutputError> {
        Vec::new()
    }

    /// How long the output has played, readable from any thread.
    #[must_use]
    pub fn clock(&self) -> Clock {
        self.clock.clone()
    }

    /// The device's name.
    #[must_use]
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// The device's id.
    #[must_use]
    pub fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    /// The stream's sample rate.
    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// The stream's channel count.
    #[must_use]
    pub fn channels(&self) -> u16 {
        self.channels
    }
}

impl<R: Render> Drop for Output<R> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A stream that captures in real time but hears no microphone.
pub struct Input<C: Capture> {
    clock: Clock,
    sample_rate: u32,
    channels: u16,
    device_id: DeviceId,
    device_name: String,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// The capturer ran on the audio thread; the handle names its type.
    _capture: std::marker::PhantomData<C>,
}

impl<C: Capture> std::fmt::Debug for Input<C> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Input")
            .field("sample_rate", &self.sample_rate)
            .field("channels", &self.channels)
            .finish_non_exhaustive()
    }
}

impl<C: Capture> Input<C> {
    /// Opens the device and starts capturing into `capturer`. The capturer is
    /// configured before this returns.
    pub fn open(options: InputOptions, mut capturer: C) -> Result<Self, OpenError> {
        let sample_rate = options.sample_rate.unwrap_or(48_000);
        let channels = if options.channels == 0 {
            1
        } else {
            options.channels
        };
        capturer.configure(sample_rate, channels);
        let clock = Clock::default();
        clock.0.capturing.store(true, Ordering::Release);
        let paused = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let clock = clock.clone();
            let paused = Arc::clone(&paused);
            let stop = Arc::clone(&stop);
            std::thread::Builder::new()
                .name("sound-input".to_owned())
                .spawn(move || {
                    let block_nanos =
                        (BLOCK_FRAMES as u64 * 1_000_000_000) / u64::from(sample_rate.max(1));
                    let silence = vec![0f32; BLOCK_FRAMES * usize::from(channels)];
                    let mut capturer = capturer;
                    while !stop.load(Ordering::Acquire) {
                        if paused.load(Ordering::Acquire) {
                            std::thread::sleep(Duration::from_millis(10));
                            continue;
                        }
                        capturer.capture(&silence);
                        clock
                            .0
                            .played_nanos
                            .fetch_add(block_nanos, Ordering::AcqRel);
                        std::thread::sleep(Duration::from_nanos(block_nanos));
                    }
                })
                .ok()
        };
        Ok(Self {
            clock,
            sample_rate,
            channels,
            device_id: options.device.id(),
            device_name: options.device.name(),
            paused,
            stop,
            thread,
            _capture: std::marker::PhantomData,
        })
    }

    /// Stops the device delivering sound.
    pub fn pause(&mut self) {
        self.paused.store(true, Ordering::Release);
    }

    /// Has the device deliver sound again.
    pub fn resume(&mut self) {
        self.paused.store(false, Ordering::Release);
    }

    /// Whether the input is paused.
    #[must_use]
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Acquire)
    }

    /// Whether the stream has failed. Never, without a device stream.
    #[must_use]
    pub fn failed(&self) -> bool {
        false
    }

    /// Keeps the input on a working device.
    pub fn maintain(&mut self) -> Maintained {
        Maintained::Unchanged
    }

    /// Drops the errors the stream reported since the last call.
    pub fn take_errors(&mut self) -> Vec<OutputError> {
        Vec::new()
    }

    /// How long the input has captured, readable from any thread.
    #[must_use]
    pub fn clock(&self) -> Clock {
        self.clock.clone()
    }

    /// The device's name.
    #[must_use]
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// The device's id.
    #[must_use]
    pub fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    /// The stream's sample rate.
    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// The stream's channel count.
    #[must_use]
    pub fn channels(&self) -> u16 {
        self.channels
    }
}

impl<C: Capture> Drop for Input<C> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The app's name in the volume mixer, for every stream opened afterwards.
pub fn set_app_info(info: AppInfo) -> Result<(), AppInfo> {
    let mut app = APP.lock().unwrap_or_else(PoisonError::into_inner);
    if app.is_some() {
        return Err(info);
    }
    *app = Some(info);
    Ok(())
}

static APP: Mutex<Option<AppInfo>> = Mutex::new(None);

/// The audio host's name.
pub fn host() -> &'static str {
    "HarmonyOS"
}

/// The output devices' names, for a device picker.
pub fn output_device_names() -> Result<Vec<String>, OpenError> {
    Ok(Vec::new())
}

/// The output devices a picker can offer.
pub fn output_devices() -> Result<Vec<DeviceInfo>, OpenError> {
    Ok(Vec::new())
}

/// The input devices a picker can offer.
pub fn input_devices() -> Result<Vec<DeviceInfo>, OpenError> {
    Ok(Vec::new())
}

/// Raises the calling thread to the audio feeder's priority.
pub fn raise_feeder_priority() {}
