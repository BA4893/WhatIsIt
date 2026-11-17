//! EGL and OpenGL ES 3 on HarmonyOS, for the XComponent's native window.
//!
//! An ArkUI `XComponent` of type `surface` owns an `OHNativeWindow`. EGL makes
//! a window surface from it, a GLES 3 context is bound to that surface, and
//! `egui_glow` paints through the `glow` function table loaded from the
//! driver. The same code makes a pbuffer surface for the offscreen screenshot
//! tool, so the renderer is exercised without an ArkUI window.

use std::ffi::{CString, c_char, c_void};
use std::sync::Arc;

use glow::HasContext as _;

pub type EGLNativeDisplayType = *mut c_void;
pub type EGLNativeWindowType = *mut c_void;
pub type EGLDisplay = *mut c_void;
pub type EGLConfig = *mut c_void;
pub type EGLSurface = *mut c_void;
pub type EGLContext = *mut c_void;
pub type EGLBoolean = u32;
pub type EGLint = i32;

#[link(name = "EGL")]
unsafe extern "C" {
    fn eglGetDisplay(display_id: EGLNativeDisplayType) -> EGLDisplay;
    fn eglInitialize(display: EGLDisplay, major: *mut EGLint, minor: *mut EGLint) -> EGLBoolean;
    fn eglChooseConfig(
        display: EGLDisplay,
        attrib_list: *const EGLint,
        configs: *mut EGLConfig,
        config_size: EGLint,
        num_config: *mut EGLint,
    ) -> EGLBoolean;
    fn eglBindAPI(api: u32) -> EGLBoolean;
    fn eglCreateWindowSurface(
        display: EGLDisplay,
        config: EGLConfig,
        native_window: EGLNativeWindowType,
        attrib_list: *const EGLint,
    ) -> EGLSurface;
    fn eglCreatePbufferSurface(
        display: EGLDisplay,
        config: EGLConfig,
        attrib_list: *const EGLint,
    ) -> EGLSurface;
    fn eglCreateContext(
        display: EGLDisplay,
        config: EGLConfig,
        share_context: EGLContext,
        attrib_list: *const EGLint,
    ) -> EGLContext;
    fn eglMakeCurrent(
        display: EGLDisplay,
        draw: EGLSurface,
        read: EGLSurface,
        context: EGLContext,
    ) -> EGLBoolean;
    fn eglDestroySurface(display: EGLDisplay, surface: EGLSurface) -> EGLBoolean;
    fn eglDestroyContext(display: EGLDisplay, context: EGLContext) -> EGLBoolean;
    fn eglTerminate(display: EGLDisplay) -> EGLBoolean;
    fn eglSwapBuffers(display: EGLDisplay, surface: EGLSurface) -> EGLBoolean;
    fn eglSwapInterval(display: EGLDisplay, interval: EGLint) -> EGLBoolean;
    fn eglQuerySurface(
        display: EGLDisplay,
        surface: EGLSurface,
        attribute: EGLint,
        value: *mut EGLint,
    ) -> EGLBoolean;
    fn eglGetProcAddress(name: *const c_char) -> *const c_void;
    fn eglGetError() -> EGLint;
}

const EGL_DEFAULT_DISPLAY: EGLNativeDisplayType = std::ptr::null_mut();
const EGL_NO_SURFACE: EGLSurface = std::ptr::null_mut();
const EGL_NO_CONTEXT: EGLContext = std::ptr::null_mut();

const EGL_SURFACE_TYPE: EGLint = 0x3033;
const EGL_WINDOW_BIT: EGLint = 0x0004;
const EGL_PBUFFER_BIT: EGLint = 0x0001;
const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
const EGL_OPENGL_ES3_BIT: EGLint = 0x0040;
const EGL_RED_SIZE: EGLint = 0x3024;
const EGL_GREEN_SIZE: EGLint = 0x3023;
const EGL_BLUE_SIZE: EGLint = 0x3022;
const EGL_ALPHA_SIZE: EGLint = 0x3021;
const EGL_DEPTH_SIZE: EGLint = 0x3025;
const EGL_NONE: EGLint = 0x3038;
const EGL_WIDTH: EGLint = 0x3057;
const EGL_HEIGHT: EGLint = 0x3056;
const EGL_CONTEXT_CLIENT_VERSION: EGLint = 0x3098;
const EGL_OPENGL_ES_API: u32 = 0x30A0;

/// A GLES 3 context painting into one surface.
pub struct GlSurface {
    display: EGLDisplay,
    surface: EGLSurface,
    context: EGLContext,
    gl: Arc<glow::Context>,
    painter: egui_glow::Painter,
    width: u32,
    height: u32,
}

impl GlSurface {
    /// A surface over the XComponent's native window.
    ///
    /// # Safety
    ///
    /// `window` must be the live `OHNativeWindow` the XComponent handed over,
    /// and this must run on the thread that will paint, with the window not
    /// destroyed meanwhile.
    pub unsafe fn window(window: EGLNativeWindowType) -> Result<Self, String> {
        let (display, config) = unsafe { display_and_config(true) }?;
        let surface =
            unsafe { eglCreateWindowSurface(display, config, window, [EGL_NONE].as_ptr()) };
        if surface.is_null() {
            unsafe {
                eglTerminate(display);
            }
            return Err(format!(
                "EGL could not make a window surface ({:#x})",
                unsafe { eglGetError() }
            ));
        }
        unsafe { Self::finish(display, config, surface) }
    }

    /// A pbuffer surface, for offscreen rendering and screenshots.
    pub fn pbuffer(width: u32, height: u32) -> Result<Self, String> {
        let (display, config) = unsafe { display_and_config(false) }?;
        let attribs = [
            EGL_WIDTH,
            EGLint::try_from(width).map_err(|_| "surface too wide")?,
            EGL_HEIGHT,
            EGLint::try_from(height).map_err(|_| "surface too tall")?,
            EGL_NONE,
        ];
        let surface = unsafe { eglCreatePbufferSurface(display, config, attribs.as_ptr()) };
        if surface.is_null() {
            unsafe {
                eglTerminate(display);
            }
            return Err(format!("EGL could not make a pbuffer ({:#x})", unsafe {
                eglGetError()
            }));
        }
        unsafe { Self::finish(display, config, surface) }
    }

    unsafe fn finish(
        display: EGLDisplay,
        config: EGLConfig,
        surface: EGLSurface,
    ) -> Result<Self, String> {
        let context = unsafe {
            eglCreateContext(
                display,
                config,
                EGL_NO_CONTEXT,
                [EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE].as_ptr(),
            )
        };
        if context.is_null() {
            unsafe {
                eglDestroySurface(display, surface);
                eglTerminate(display);
            }
            return Err("EGL could not make a GLES 3 context".to_owned());
        }
        if unsafe { eglMakeCurrent(display, surface, surface, context) } == 0 {
            unsafe {
                eglDestroyContext(display, context);
                eglDestroySurface(display, surface);
                eglTerminate(display);
            }
            return Err("EGL could not bind the GLES 3 context".to_owned());
        }
        unsafe {
            eglSwapInterval(display, 1);
        }
        let gl = Arc::new(unsafe { glow::Context::from_loader_function(load) });
        let version = egui_glow::ShaderVersion::get(&gl);
        log::info!(
            "GL {} / {} ({version:?})",
            unsafe { gl.get_parameter_string(glow::VERSION) },
            unsafe { gl.get_parameter_string(glow::RENDERER) },
        );
        let painter = egui_glow::Painter::new(
            Arc::clone(&gl),
            "",
            Some(egui_glow::ShaderVersion::Es300),
            false,
        )
        .map_err(|error| format!("the egui painter could not start: {error}"))?;
        let mut width = 0;
        let mut height = 0;
        unsafe {
            eglQuerySurface(display, surface, EGL_WIDTH, &mut width);
            eglQuerySurface(display, surface, EGL_HEIGHT, &mut height);
        }
        Ok(Self {
            display,
            surface,
            context,
            gl,
            painter,
            width: u32::try_from(width).unwrap_or(0),
            height: u32::try_from(height).unwrap_or(0),
        })
    }

    /// The surface's size in pixels.
    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Re-reads the surface's size after the XComponent changed it.
    pub fn refresh_size(&mut self) -> (u32, u32) {
        let mut width = 0;
        let mut height = 0;
        unsafe {
            eglQuerySurface(self.display, self.surface, EGL_WIDTH, &mut width);
            eglQuerySurface(self.display, self.surface, EGL_HEIGHT, &mut height);
        }
        if width > 0 && height > 0 {
            self.width = u32::try_from(width).unwrap_or(self.width);
            self.height = u32::try_from(height).unwrap_or(self.height);
        }
        (self.width, self.height)
    }

    /// The GL context, for paint callbacks the app registers.
    pub fn context(&self) -> Arc<glow::Context> {
        Arc::clone(&self.gl)
    }

    /// Paints one `egui` frame and presents it.
    pub fn paint(
        &mut self,
        primitives: &[egui::ClippedPrimitive],
        textures_delta: &mut egui::TexturesDelta,
        pixels_per_point: f32,
        clear: egui::Color32,
    ) {
        let [width, height] = [self.width, self.height];
        if width == 0 || height == 0 {
            return;
        }
        unsafe {
            self.gl.viewport(
                0,
                0,
                i32::try_from(width).unwrap_or(i32::MAX),
                i32::try_from(height).unwrap_or(i32::MAX),
            );
            self.gl.clear_color(
                f32::from(clear.r()) / 255.0,
                f32::from(clear.g()) / 255.0,
                f32::from(clear.b()) / 255.0,
                f32::from(clear.a()) / 255.0,
            );
            self.gl.clear(glow::COLOR_BUFFER_BIT);
        }
        self.painter.paint_and_update_textures(
            [width, height],
            pixels_per_point,
            primitives,
            textures_delta,
        );
        unsafe {
            eglSwapBuffers(self.display, self.surface);
        }
    }

    /// Reads the rendered pixels as RGBA, bottom row first, for a screenshot.
    pub fn read_pixels(&self) -> Vec<u8> {
        let mut pixels = vec![0u8; (self.width * self.height * 4) as usize];
        unsafe {
            self.gl.bind_framebuffer(glow::FRAMEBUFFER, None);
            self.gl.read_pixels(
                0,
                0,
                i32::try_from(self.width).unwrap_or(0),
                i32::try_from(self.height).unwrap_or(0),
                glow::RGBA,
                glow::UNSIGNED_BYTE,
                glow::PixelPackData::Slice(Some(&mut pixels)),
            );
        }
        pixels
    }

    /// Saves what is on the surface as a PNG, for the screenshot tool.
    pub fn save_png(&self, path: &std::path::Path) -> Result<(), String> {
        let mut pixels = self.read_pixels();
        // GL reads bottom-up; PNGs are top-down.
        let row = (self.width * 4) as usize;
        let rows = self.height as usize;
        for top in 0..rows / 2 {
            let bottom = rows - 1 - top;
            let (top_at, bottom_at) = (top * row, bottom * row);
            for i in 0..row {
                pixels.swap(top_at + i, bottom_at + i);
            }
        }
        let image = image::RgbaImage::from_raw(self.width, self.height, pixels)
            .ok_or_else(|| "the framebuffer did not match its size".to_owned())?;
        image
            .save(path)
            .map_err(|error| format!("could not write {}: {error}", path.display()))
    }
}

impl Drop for GlSurface {
    fn drop(&mut self) {
        // The painter owns GL objects, so it has to free them while the
        // context is still current, before the context and surface go.
        unsafe {
            self.gl.bind_framebuffer(glow::FRAMEBUFFER, None);
        }
        self.painter.destroy();
        unsafe {
            eglMakeCurrent(self.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface(self.display, self.surface);
            eglDestroyContext(self.display, self.context);
            eglTerminate(self.display);
        }
    }
}

unsafe fn display_and_config(windowed: bool) -> Result<(EGLDisplay, EGLConfig), String> {
    let display = unsafe { eglGetDisplay(EGL_DEFAULT_DISPLAY) };
    if display.is_null() {
        return Err("EGL found no display".to_owned());
    }
    let (mut major, mut minor) = (0, 0);
    if unsafe { eglInitialize(display, &mut major, &mut minor) } == 0 {
        return Err("EGL could not initialize".to_owned());
    }
    let surface_bit = if windowed {
        EGL_WINDOW_BIT
    } else {
        EGL_PBUFFER_BIT
    };
    let attribs = [
        EGL_SURFACE_TYPE,
        surface_bit,
        EGL_RENDERABLE_TYPE,
        EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_BLUE_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_DEPTH_SIZE,
        0,
        EGL_NONE,
    ];
    let mut config: EGLConfig = std::ptr::null_mut();
    let mut count = 0;
    if unsafe { eglChooseConfig(display, attribs.as_ptr(), &mut config, 1, &mut count) } == 0
        || count == 0
    {
        unsafe {
            eglTerminate(display);
        }
        return Err("EGL has no GLES 3 config".to_owned());
    }
    if unsafe { eglBindAPI(EGL_OPENGL_ES_API) } == 0 {
        unsafe {
            eglTerminate(display);
        }
        return Err("EGL could not bind the OpenGL ES API".to_owned());
    }
    Ok((display, config))
}

/// Resolves a GL function through EGL first, then the GLES library itself
/// (core symbols such as `glClear` are not always EGL extensions).
fn load(name: &str) -> *const c_void {
    let Ok(name) = CString::new(name) else {
        return std::ptr::null();
    };
    let address = unsafe { eglGetProcAddress(name.as_ptr()) };
    if !address.is_null() {
        return address;
    }
    static LIB: std::sync::OnceLock<usize> = std::sync::OnceLock::new();
    let library = *LIB.get_or_init(|| unsafe {
        let path = c"libGLESv3.so";
        let handle = libc::dlopen(path.as_ptr(), libc::RTLD_NOW);
        if handle.is_null() {
            log::error!("libGLESv3.so could not be opened");
            return 0;
        }
        handle as usize
    });
    if library == 0 {
        return std::ptr::null();
    }
    unsafe { libc::dlsym(library as *mut c_void, name.as_ptr()).cast_const() }
}
