//! The outliving part of the HarmonyOS app: the frame loop, the surface, and
//! the queues between ArkUI's thread and the render thread.
//!
//! One thread owns everything that is not `Send` (the egui context, the app,
//! the GL surface). ArkUI and the C++ bridge push events into a queue; the
//! thread drains it, runs one egui pass, paints, presents, and sleeps until
//! the next event or the next frame egui asked for. The app's own background
//! wakers ring the same queue, so a message that arrives while the UI sleeps
//! draws at once.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use egui::{Event, Pos2, Rect, Vec2, ViewportId, ViewportInfo};
use zapfast::app::{App, AppOptions};
use zapfast::backend::Waker;
use zapfast::paths::AppDirs;
use zapfast::settings::Settings;

use crate::egl::GlSurface;
use crate::input::{Input, OsEvent};

/// One wake's worth of work, taken out of the queue under one lock.
#[derive(Default)]
struct Batch {
    events: Vec<OsEvent>,
    /// A new native window, its pixel width and height.
    surface: Option<(usize, u32, u32)>,
    surface_destroyed: bool,
    surface_changed: bool,
    density: Option<f32>,
    focus: Option<bool>,
    /// Text pasted from the system clipboard, to hand egui as `Paste`.
    paste: Option<String>,
}

/// The frame the app asked for later, if any.
///
/// `Waker::wake_after` reaches the loop through this, so a sound that asks
/// for a frame every 40 ms gets them without the loop waking for every
/// request: only a new, earlier deadline rings the bell.
#[derive(Default)]
struct Timers {
    at: Option<Instant>,
}

/// What the C ABI talks to: a handle whose methods only queue work.
pub struct Host {
    queue: Arc<Mutex<Batch>>,
    wake: Arc<Condvar>,
    pending: Arc<Mutex<Pending>>,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

/// What ArkTS polls for, kept apart from the frame queue so a poll never
/// wakes the renderer.
#[derive(Default)]
struct Pending {
    clipboard: Option<String>,
    open_url: Option<String>,
}

/// Whether the app is editing text now, so ArkTS can show the soft keyboard.
static TEXT_INPUT_WANTED: AtomicBool = AtomicBool::new(false);

/// Whether the app is editing text now, for ArkTS to show the soft keyboard.
pub fn text_input_wanted() -> bool {
    TEXT_INPUT_WANTED.load(Ordering::Acquire)
}

impl Host {
    /// Starts the render thread. `files_dir` is the app's private directory;
    /// `demo` shows the offline sample chats instead of linking.
    pub fn start(files_dir: String, cache_dir: String, density: f32, demo: bool) -> Self {
        let queue = Arc::new(Mutex::new(Batch::default()));
        let wake = Arc::new(Condvar::new());
        let pending = Arc::new(Mutex::new(Pending::default()));
        let paused = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let waker = Waker::default();
        let bell = Arc::clone(&wake);
        fastframe_shell::set_platform_waker(move || bell.notify_all());
        let timers = Arc::new(Mutex::new(Timers::default()));
        {
            let timers = Arc::clone(&timers);
            let bell = Arc::clone(&wake);
            fastframe_shell::set_platform_scheduler(move |delay| {
                let at = Instant::now() + delay;
                let mut timers = timers.lock().unwrap_or_else(PoisonError::into_inner);
                let sooner = timers.at.is_none_or(|current| at < current);
                if sooner {
                    timers.at = Some(at);
                }
                drop(timers);
                if sooner {
                    bell.notify_all();
                }
            });
        }
        let thread_queue = Arc::clone(&queue);
        let thread_wake = Arc::clone(&wake);
        let thread_pending = Arc::clone(&pending);
        let thread_paused = Arc::clone(&paused);
        let thread_stop = Arc::clone(&stop);
        let thread_timers = Arc::clone(&timers);
        let thread = std::thread::Builder::new()
            .name("zapfast-ui".to_owned())
            .spawn(move || {
                run(
                    thread_queue,
                    thread_wake,
                    thread_pending,
                    thread_paused,
                    thread_stop,
                    thread_timers,
                    waker,
                    files_dir,
                    cache_dir,
                    density,
                    demo,
                );
            })
            .map_err(|error| log::error!("the UI thread could not start: {error}"))
            .ok();
        Self {
            queue,
            wake,
            pending,
            paused,
            stop,
            thread,
        }
    }

    fn with_queue(&self, edit: impl FnOnce(&mut Batch)) {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        edit(&mut queue);
        drop(queue);
        self.wake.notify_all();
    }

    pub fn surface(&self, window: usize, width: u32, height: u32) {
        self.with_queue(|queue| queue.surface = Some((window, width, height)));
    }

    pub fn surface_changed(&self) {
        self.with_queue(|queue| queue.surface_changed = true);
    }

    pub fn surface_destroyed(&self) {
        self.with_queue(|queue| queue.surface_destroyed = true);
    }

    pub fn density(&self, density: f32) {
        self.with_queue(|queue| queue.density = Some(density));
    }

    pub fn focus(&self, focused: bool) {
        self.with_queue(|queue| queue.focus = Some(focused));
    }

    pub fn pause(&self) {
        self.paused.store(true, Ordering::Release);
        self.wake.notify_all();
    }

    pub fn resume(&self) {
        self.paused.store(false, Ordering::Release);
        self.wake.notify_all();
    }

    pub fn event(&self, event: OsEvent) {
        self.with_queue(|queue| queue.events.push(event));
    }

    pub fn paste(&self, text: String) {
        self.with_queue(|queue| queue.paste = Some(text));
    }

    /// The text egui asked to copy, for ArkTS to put on the pasteboard. It
    /// stays queued until [`clear_clipboard`](Self::clear_clipboard) is
    /// called, so a buffer that was too small loses nothing.
    pub fn pending_clipboard(&self) -> Option<String> {
        self.pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clipboard
            .clone()
    }

    /// Forgets the copied text after ArkTS has it.
    pub fn clear_clipboard(&self) {
        self.pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clipboard = None;
    }

    /// The URL egui asked to open, for ArkTS to open it.
    pub fn pending_open_url(&self) -> Option<String> {
        self.pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .open_url
            .clone()
    }

    /// Forgets the URL after ArkTS has opened it.
    pub fn clear_open_url(&self) {
        self.pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .open_url = None;
    }

    /// Ends the app: stops the loop, shuts the app down, and joins it.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.wake.notify_all();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The render thread: make the app, then draw until stopped.
#[expect(clippy::too_many_arguments)]
fn run(
    queue: Arc<Mutex<Batch>>,
    wake: Arc<Condvar>,
    pending: Arc<Mutex<Pending>>,
    paused: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    timers: Arc<Mutex<Timers>>,
    waker: Waker,
    files_dir: String,
    _cache_dir: String,
    density: f32,
    demo: bool,
) {
    let root = std::path::Path::new(&files_dir).join("zapfast");
    let dirs = AppDirs::under(&root);
    if let Err(error) = dirs.ensure() {
        log::error!("could not create ZapFast's folders: {error}");
    }
    if !demo {
        zapfast_ohos_keyring::init(&files_dir);
    }
    let settings = Settings::load(&dirs.settings_file());
    let ctx = egui::Context::default();
    waker.attach(&ctx);
    let mut input = Input::default();
    let mut app = match build_app(&waker, dirs, settings, demo) {
        Ok(app) => Some(app),
        Err(error) => {
            log::error!("ZapFast could not start: {error}");
            None
        }
    };
    if let Some(app) = &mut app {
        app.attach(&ctx);
        crate::fonts::install(&ctx);
    }
    let start = Instant::now();
    let mut gl: Option<GlSurface> = None;
    let mut density = if density.is_finite() && density > 0.0 {
        density
    } else {
        1.0
    };
    let mut focused = true;
    let mut surface_size = (0_u32, 0_u32);
    let mut wait = Duration::ZERO;
    // The desktop shell lets each account's backend start after the first
    // drawn frame. Nothing else releases it here, and without this the link
    // screen waits on "Starting" forever.
    let mut released_startup = false;
    loop {
        // Wait until a wake, until egui's next frame is due, or until the
        // frame the app asked for later comes round. A zero wait means a
        // frame is already due; a huge one waits for input.
        {
            let now = Instant::now();
            let mut timers = timers.lock().unwrap_or_else(PoisonError::into_inner);
            match timers.at {
                Some(at) if at <= now => timers.at = None,
                Some(at) => wait = wait.min(at.saturating_duration_since(now)),
                None => {}
            }
        }
        if !wait.is_zero() {
            let mut guard = queue.lock().unwrap_or_else(PoisonError::into_inner);
            while is_idle(&guard) {
                let (next, timed_out) = wake
                    .wait_timeout(guard, wait.min(Duration::from_secs(60)))
                    .unwrap_or_else(PoisonError::into_inner);
                guard = next;
                if timed_out.timed_out() {
                    break;
                }
            }
        }
        if stop.load(Ordering::Acquire) {
            break;
        }
        let batch = {
            let mut guard = queue.lock().unwrap_or_else(PoisonError::into_inner);
            std::mem::take(&mut *guard)
        };
        if let Some(density_now) = batch.density.filter(|d| d.is_finite() && *d > 0.0) {
            density = density_now;
            ctx.request_repaint();
        }
        if batch.surface_destroyed {
            gl = None;
            surface_size = (0, 0);
        }
        if let Some((window, width, height)) = batch.surface {
            gl = None;
            // SAFETY: C++ keeps the OHNativeWindow alive from the surface
            // callback until the destroyed one, and this runs on the thread
            // that paints.
            match unsafe { GlSurface::window(window as *mut std::ffi::c_void) } {
                Ok(made) => {
                    surface_size = made.size();
                    if surface_size == (0, 0) {
                        surface_size = (width, height);
                    }
                    gl = Some(made);
                    if let Some(app) = &mut app {
                        app.attach(&ctx);
                        crate::fonts::install(&ctx);
                    }
                    waker.attach(&ctx);
                    log::info!("the XComponent surface is up ({}x{})", width, height);
                }
                Err(error) => log::error!("the XComponent surface could not start: {error}"),
            }
        }
        if batch.surface_changed
            && let Some(surface) = &mut gl
        {
            surface_size = surface.refresh_size();
            ctx.request_repaint();
        }
        if let Some(focused_now) = batch.focus {
            focused = focused_now;
            ctx.request_repaint();
        }
        let mut events = Vec::new();
        for event in batch.events {
            input.push(event, &mut events);
        }
        if let Some(text) = batch.paste {
            events.push(Event::Paste(text));
        }
        let (Some(surface), Some(app)) = (&mut gl, &mut app) else {
            // Nothing to draw into: wait for the next surface or the stop.
            wait = Duration::from_secs(1);
            continue;
        };
        if paused.load(Ordering::Acquire) {
            wait = Duration::from_secs(60);
            continue;
        }
        let [width, height] = [surface_size.0, surface_size.1];
        if width == 0 || height == 0 {
            wait = Duration::from_millis(100);
            continue;
        }
        let points = Vec2::new(width as f32 / density, height as f32 / density);
        let screen = Rect::from_min_size(Pos2::ZERO, points);
        let viewport = ViewportInfo {
            native_pixels_per_point: Some(density),
            inner_rect: Some(screen),
            outer_rect: Some(screen),
            focused: Some(focused),
            maximized: Some(true),
            ..Default::default()
        };
        let raw = egui::RawInput {
            viewport_id: ViewportId::ROOT,
            viewports: std::iter::once((ViewportId::ROOT, viewport)).collect(),
            screen_rect: Some(screen),
            max_texture_side: Some(max_texture_side(surface)),
            time: Some(start.elapsed().as_secs_f64()),
            events,
            focused,
            ..Default::default()
        };
        let clear = zapfast::backdrop::clear_color(app.palette.window);
        let mut output = ctx.run_ui(raw, |ui| {
            app.background_frame(ui.ctx());
            app.frame_ui(ui);
        });
        if !released_startup {
            app.release_startup();
            released_startup = true;
            log::info!("the account backends are released to start");
        }
        TEXT_INPUT_WANTED.store(
            output.platform_output.mutable_text_under_cursor
                || output.platform_output.ime.is_some(),
            Ordering::Release,
        );
        for command in std::mem::take(&mut output.platform_output.commands) {
            match command {
                egui::OutputCommand::CopyText(text) => {
                    pending
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .clipboard = Some(text);
                }
                egui::OutputCommand::OpenUrl(url) => {
                    pending
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .open_url = Some(url.url);
                }
                egui::OutputCommand::CopyImage(_) => {}
            }
        }
        let primitives =
            ctx.tessellate(std::mem::take(&mut output.shapes), output.pixels_per_point);
        surface.paint(
            &primitives,
            &mut output.textures_delta,
            output.pixels_per_point,
            clear,
        );
        wait = output
            .viewport_output
            .get(&ViewportId::ROOT)
            .map(|viewport| viewport.repaint_delay)
            .unwrap_or(Duration::from_millis(16))
            .min(Duration::from_secs(60));
        // Quit in the interface ends the app: on the desktop eframe closes
        // the window; here nothing else would ever stop the loop.
        if app.quit_requested {
            log::info!("ZapFast asked to quit");
            break;
        }
    }
    if let Some(mut app) = app {
        app.shutdown();
    }
    waker.detach();
    log::info!("ZapFast's frame loop stopped");
}

/// Whether the loop should keep sleeping: no event, no surface change, no
/// stop, no paste.
fn is_idle(batch: &Batch) -> bool {
    batch.events.is_empty()
        && batch.surface.is_none()
        && !batch.surface_destroyed
        && !batch.surface_changed
        && batch.density.is_none()
        && batch.focus.is_none()
        && batch.paste.is_none()
}

fn max_texture_side(surface: &GlSurface) -> usize {
    use glow::HasContext as _;
    let gl = surface.context();
    let side = unsafe { gl.get_parameter_i32(glow::MAX_TEXTURE_SIZE) };
    usize::try_from(side).unwrap_or(2048).clamp(2048, 16_384)
}

fn build_app(waker: &Waker, dirs: AppDirs, settings: Settings, demo: bool) -> Result<App, String> {
    if demo {
        #[cfg(feature = "demo")]
        {
            let (mut app, _events) = App::headless(dirs, settings);
            zapfast::demo::populate(&mut app);
            return Ok(app);
        }
        #[cfg(not(feature = "demo"))]
        return Err("this build has no demo data".to_owned());
    }
    App::new(waker, dirs, settings, AppOptions { tray: false }).map_err(|error| error.to_string())
}
