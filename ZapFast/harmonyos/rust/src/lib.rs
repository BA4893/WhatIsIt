//! The HarmonyOS host for ZapFast.
//!
//! ZapFast is a Rust and egui application. On the desktop, eframe and winit
//! own the window. On HarmonyOS there is no winit backend, so this crate owns
//! the window instead: an ArkUI `XComponent` hands over its native window, an
//! EGL surface is made from it, `egui_glow` paints the frames, and the input
//! events ArkUI reports are translated into the events egui's `RawInput`
//! expects. The same `zapfast::app::App` and the same views draw, so the
//! interface, its state and its behaviour stay the desktop's.
//!
//! The C ABI at the bottom is what the app's C++ NAPI module calls: it
//! receives the surface, input and lifecycle events from ArkTS and turns them
//! into work for the render thread. Nothing here uses NAPI directly, so the
//! whole host is an ordinary Rust library.
//!
//! Rust's target for HarmonyOS is `aarch64-unknown-linux-ohos`: it reports
//! `target_os = "linux"` with `target_env = "ohos"`, and every gate in this
//! crate is on the environment, which is what tells HarmonyOS from a desktop
//! Linux.

#![cfg(target_env = "ohos")]

pub mod egl;
pub mod fonts;
pub mod host;
pub mod input;
pub mod logging;

use std::ffi::{CStr, c_char};
use std::sync::{Mutex, OnceLock};

use input::{KeyAction, MouseAction, MouseButton, OsEvent, TouchAction};

/// Where the host was built from, for the log.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The running host, if the app has started one.
static HOST: OnceLock<Mutex<Option<host::Host>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<host::Host>> {
    HOST.get_or_init(|| Mutex::new(None))
}

fn with_host(use_host: impl FnOnce(&host::Host)) {
    let guard = slot()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(host) = guard.as_ref() {
        use_host(host);
    }
}

fn with_host_result<T>(read: impl FnOnce(&host::Host) -> T) -> Option<T> {
    let guard = slot()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    guard.as_ref().map(read)
}

fn string_at(pointer: *const c_char) -> String {
    if pointer.is_null() {
        return String::new();
    }
    // SAFETY: the caller passes a NUL-terminated string that outlives the call.
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}

/// Copies `text` into a caller's buffer: the byte length including the final
/// NUL, 0 when there is nothing, or the negative needed length when it does
/// not fit.
fn copy_out(text: &str, out: *mut c_char, capacity: i32) -> i32 {
    let bytes = text.as_bytes();
    let needed = i32::try_from(bytes.len() + 1).unwrap_or(i32::MAX);
    if out.is_null() || capacity < needed {
        return -needed;
    }
    // SAFETY: the caller promised a buffer of `capacity` bytes.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), bytes.len());
        *out.add(bytes.len()) = 0;
    }
    needed
}

/// Starts the app: `files_dir` is the app's private directory, `density` the
/// display's pixels per vp, and `demo` starts the offline sample chats.
///
/// Called on the ArkTS thread once, before the XComponent has a surface.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_start(
    files_dir: *const c_char,
    cache_dir: *const c_char,
    density: f32,
    demo: i32,
) {
    let files_dir = string_at(files_dir);
    if files_dir.is_empty() {
        return;
    }
    logging::init(std::path::Path::new(&files_dir), false);
    log::info!("zapfast-ohos {VERSION} starting in {files_dir}");
    let cache_dir = string_at(cache_dir);
    let mut guard = slot()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    // The page may be made again (a rotation, a new window stage): the old
    // host has to have stopped before the new one opens the same archive.
    if let Some(mut old) = guard.take() {
        old.stop();
    }
    *guard = Some(host::Host::start(files_dir, cache_dir, density, demo != 0));
}

/// Stops the app, saving its state before the process ends.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_stop() {
    let mut guard = slot()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(mut host) = guard.take() {
        host.stop();
    }
}

/// A surface arrived: `window` is its `OHNativeWindow*` and the size is in
/// pixels.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_surface_created(
    window: *mut std::ffi::c_void,
    width: i32,
    height: i32,
) {
    if window.is_null() {
        log::warn!("the XComponent reported no native window");
        return;
    }
    let width = u32::try_from(width).unwrap_or(0);
    let height = u32::try_from(height).unwrap_or(0);
    with_host(|host| host.surface(window as usize, width, height));
}

/// The surface changed size, or was recreated on the same window.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_surface_changed() {
    with_host(host::Host::surface_changed);
}

/// The surface went away (the page or the app was hidden). The app stays
/// alive; a later `surface_created` brings the picture back.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_surface_destroyed() {
    with_host(host::Host::surface_destroyed);
}

/// The display's pixels per vp changed, for example on another monitor.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_set_density(density: f32) {
    with_host(|host| host.density(density));
}

/// A finger went down, moved, lifted or was cancelled.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_touch(action: i32, id: i32, x: f32, y: f32, force: f32) {
    let action = match action {
        0 => TouchAction::Down,
        1 => TouchAction::Up,
        2 => TouchAction::Move,
        _ => TouchAction::Cancel,
    };
    with_host(|host| {
        host.event(OsEvent::Touch {
            action,
            id,
            x,
            y,
            force,
        });
    });
}

/// A mouse button went down or up, or the pointer moved.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_mouse(action: i32, button: i32, x: f32, y: f32) {
    let action = match action {
        0 => MouseAction::Press,
        1 => MouseAction::Release,
        2 => MouseAction::Move,
        3 => MouseAction::Hover,
        _ => MouseAction::Cancel,
    };
    let button = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        3 => MouseButton::Back,
        _ => MouseButton::Forward,
    };
    with_host(|host| {
        host.event(OsEvent::Mouse {
            action,
            x,
            y,
            button,
        });
    });
}

/// A key went down or up. `code` is ArkUI's `KeyEvent.keyCode`, which uses
/// the same values as `OH_NativeXComponent_KeyCode`.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_key(action: i32, code: i32) {
    let action = if action == 0 {
        KeyAction::Down
    } else {
        KeyAction::Up
    };
    with_host(|host| host.event(OsEvent::Key { action, code }));
}

/// Text committed by the keyboard or the input method, in UTF-8.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_text(text: *const c_char) {
    let text = string_at(text);
    if text.is_empty() {
        return;
    }
    with_host(|host| host.event(OsEvent::Text(text)));
}

/// A wheel notch or a two-finger swipe. `scroll_step` is zero for a touchpad;
/// `mouse` says the source was the mouse wheel.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_axis(horizontal: f32, vertical: f32, scroll_step: f32, mouse: i32) {
    with_host(|host| {
        host.event(OsEvent::Axis {
            horizontal,
            vertical,
            scroll_step,
            mouse: mouse != 0,
        });
    });
}

/// The XComponent gained or lost focus.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_focus(focused: i32) {
    with_host(|host| host.focus(focused != 0));
}

/// The app went to the background: no frame is drawn until `resume`.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_pause() {
    with_host(host::Host::pause);
}

/// The app came back to the foreground.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_resume() {
    with_host(host::Host::resume);
}

/// Text read from the system clipboard when the person pasted, for egui's
/// text fields.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_paste(text: *const c_char) {
    let text = string_at(text);
    if text.is_empty() {
        return;
    }
    with_host(|host| host.paste(text));
}

/// Whether the app is editing text now, so ArkTS shows the soft keyboard.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_text_input_wanted() -> i32 {
    if host::text_input_wanted() { 1 } else { 0 }
}

/// Copies the string egui asked to put on the clipboard into `out`. Returns
/// the byte length including the NUL, 0 when there is nothing, or the
/// negative length needed when the buffer is too small.
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_take_clipboard(out: *mut c_char, capacity: i32) -> i32 {
    match with_host_result(host::Host::pending_clipboard).flatten() {
        Some(text) => {
            let copied = copy_out(&text, out, capacity);
            if copied > 0 {
                with_host(host::Host::clear_clipboard);
            }
            copied
        }
        None => 0,
    }
}

/// Copies a URL egui asked to open into `out`, with the same return value as
/// [`zapfast_ohos_take_clipboard`].
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_take_open_url(out: *mut c_char, capacity: i32) -> i32 {
    match with_host_result(host::Host::pending_open_url).flatten() {
        Some(text) => {
            let copied = copy_out(&text, out, capacity);
            if copied > 0 {
                with_host(host::Host::clear_open_url);
            }
            copied
        }
        None => 0,
    }
}

/// Copies the host's version into `out`, with the same return value as
/// [`zapfast_ohos_take_clipboard`].
#[unsafe(no_mangle)]
pub extern "C" fn zapfast_ohos_version(out: *mut c_char, capacity: i32) -> i32 {
    copy_out(VERSION, out, capacity)
}
