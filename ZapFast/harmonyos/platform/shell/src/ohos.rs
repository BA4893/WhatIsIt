//! The part of fastframe-shell ZapFast's app layer uses, for HarmonyOS.
//!
//! On the desktop, fastframe-shell owns the window: it runs eframe, recreates
//! a window from the tray, and keeps the app alive between windows. On
//! HarmonyOS the window belongs to the ArkUI XComponent, and
//! `zapfast-ohos` runs the frame loop itself. The app layer still needs the
//! pieces it shares with the desktop shell:
//!
//! - [`Waker`], which asks the UI for a new frame from any thread. This
//!   version also rings the platform's frame-loop bell (see
//!   [`set_platform_waker`]), so a backend event wakes a sleeping render
//!   thread instead of waiting for the next scheduled frame.
//! - [`window::Geometry`], the remembered window geometry in the settings.
//! - [`Resident`], [`Closed`] and [`Headless`], so the same app-level
//!   decisions compile and can be tested; the HarmonyOS host decides when to
//!   stop the app from the ability's lifecycle instead.
//!
//! Nothing here opens a window. The crate is a target-specific stand-in for
//! `fastframe-shell`, never shipped on the desktop.

use std::sync::{Arc, Mutex, PoisonError};

/// What a HarmonyOS host installs to wake its frame loop.
type PlatformWake = Arc<dyn Fn() + Send + Sync>;
/// What it installs to hear about a frame that is due later.
type PlatformSchedule = Arc<dyn Fn(std::time::Duration) + Send + Sync>;

static PLATFORM_WAKE: Mutex<Option<PlatformWake>> = Mutex::new(None);
static PLATFORM_SCHEDULE: Mutex<Option<PlatformSchedule>> = Mutex::new(None);

/// Installs the frame loop's bell, rung by [`Waker::wake`] after asking egui
/// for a repaint. Called once by the host before the app is made.
pub fn set_platform_waker(wake: impl Fn() + Send + Sync + 'static) {
    *PLATFORM_WAKE.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(wake));
}

/// Installs the timer the frame loop sleeps against, told how long from now a
/// frame is due. The loop shortens its sleep to the soonest one, so a sound
/// that asks for a frame every 40 ms gets them without the loop waking for
/// every request.
pub fn set_platform_scheduler(schedule: impl Fn(std::time::Duration) + Send + Sync + 'static) {
    *PLATFORM_SCHEDULE
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(schedule));
}

/// Asks the window, if there is one, for a new frame, and rings the host's
/// bell so its loop stops sleeping.
#[derive(Clone, Default)]
pub struct Waker {
    inner: Arc<Mutex<WakerState>>,
}

#[derive(Default)]
struct WakerState {
    context: Option<egui::Context>,
}

impl std::fmt::Debug for Waker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Waker")
            .field("attached", &self.context().is_some())
            .finish()
    }
}

impl Waker {
    /// Repaints `ctx` from now on.
    pub fn attach(&self, ctx: &egui::Context) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .context = Some(ctx.clone());
    }

    /// Stops repainting: the surface is gone.
    pub fn detach(&self) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .context = None;
    }

    /// Asks for a frame `delay` from now, as an animation's next step does.
    pub fn wake_after(&self, delay: std::time::Duration) {
        if let Some(ctx) = self.context() {
            ctx.request_repaint_after(delay);
        }
        if let Some(schedule) = PLATFORM_SCHEDULE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            schedule(delay);
        } else {
            self.wake();
        }
    }

    /// Asks for a frame from any thread.
    pub fn wake(&self) {
        if let Some(ctx) = self.context() {
            ctx.request_repaint();
        }
        if let Some(wake) = PLATFORM_WAKE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
        {
            wake();
        }
    }

    fn context(&self) -> Option<egui::Context> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .context
            .clone()
    }
}

/// Geometry a window is remembered with. HarmonyOS keeps its window state in
/// the window stage, so ZapFast only reads and writes the settings fields.
pub mod window {
    /// A window's size and position, in points.
    #[derive(Clone, Copy, Debug, Default, PartialEq)]
    pub struct Geometry {
        /// Width and height, when both are known.
        pub size: Option<[f32; 2]>,
        /// X and Y, when both are known.
        pub position: Option<[f32; 2]>,
        /// Whether the window was maximized.
        pub maximized: bool,
    }

    impl Geometry {
        /// Folds the window's current state in and says whether anything
        /// changed. HarmonyOS's window belongs to the window stage, not to
        /// the app: its size, position and maximized state are the system's
        /// to keep, so nothing here changes and the settings are not written.
        pub fn remember(&mut self, _ctx: &egui::Context) -> bool {
            false
        }
    }

    /// Whether a compositor brought an existing window forward (niri on
    /// Wayland). HarmonyOS raises its own windows, so never.
    pub fn raise_on_compositor() -> bool {
        false
    }
}

/// How long a headless stretch waits between ticks.
pub const HEADLESS_TICK: std::time::Duration = std::time::Duration::from_millis(150);

/// What an app that outlives its window tells the shell. The trait is kept
/// so the app's decisions stay testable; the HarmonyOS host never calls it.
pub trait Resident {
    /// What to do once the window has closed.
    fn closed(&self) -> Closed;

    /// The window is gone; drop per-window state.
    fn window_gone(&mut self);

    /// One headless tick, for tests of the decisions above.
    fn headless_frame(&mut self, ctx: &egui::Context) -> Headless;

    /// Starts without a window. There is no tray on HarmonyOS.
    fn start_hidden(&mut self) -> bool {
        false
    }

    /// The app is about to end.
    fn shutdown(&mut self);
}

/// What happens after a window closes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Closed {
    /// End the app.
    Quit,
    /// Keep running without a window.
    Hide,
    /// Open a new window at once.
    Reopen,
}

/// What a headless tick asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Headless {
    /// Keep running in the background.
    Wait,
    /// Keep running with nothing due for this long.
    WaitFor(std::time::Duration),
    /// Open a window.
    Show,
    /// End the app.
    Quit,
}
