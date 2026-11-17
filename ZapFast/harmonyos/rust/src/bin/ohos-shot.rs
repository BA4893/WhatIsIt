//! Renders ZapFast's screens into PNG files on the device, without ArkUI.
//!
//! This is the port's visual test: it uses the same `App`, the same
//! `zapfast::ui` tree and the same `egui_glow` painter as the XComponent
//! host, but draws into an EGL pbuffer instead of a window. It runs as an
//! ordinary HarmonyOS binary (`cargo run --bin zapfast-ohos-shot`), so the
//! interface can be inspected on a machine where the HAP cannot be installed.
//!
//! ```text
//! zapfast-ohos-shot --out /data/.../shot.png --size 1440x900 --page chat --frames 4
//! ```

#![cfg(target_env = "ohos")]

use egui::{Pos2, Rect, Vec2, ViewportId};
use zapfast::app::App;
use zapfast::paths::AppDirs;
use zapfast::settings::Settings;

use zapfast_ohos::egl::GlSurface;

struct Args {
    out: std::path::PathBuf,
    size: (u32, u32),
    page: Option<String>,
    frames: u32,
    density: f32,
    open_chat: bool,
}

fn main() {
    let args = parse();
    let root = std::env::temp_dir().join(format!("zapfast-ohos-shot-{}", std::process::id()));
    let dirs = AppDirs::under(&root);
    let settings = Settings::default();
    let (mut app, _events) = App::headless(dirs, settings);
    zapfast::demo::populate(&mut app);
    zapfast::demo::apply_flags(&mut app, args.page.as_deref());
    if args.open_chat
        && let Some(chat) = app.chats.first().map(|chat| chat.id.clone())
    {
        app.open_chat = Some(chat);
    }
    let ctx = egui::Context::default();
    app.attach(&ctx);
    zapfast_ohos::fonts::install(&ctx);
    let mut surface = match GlSurface::pbuffer(args.size.0, args.size.1) {
        Ok(surface) => surface,
        Err(error) => {
            eprintln!("could not make a pbuffer: {error}");
            std::process::exit(1);
        }
    };
    let _ = std::fs::create_dir_all(args.out.parent().unwrap_or(&root));
    let start = std::time::Instant::now();
    let points = Vec2::new(
        args.size.0 as f32 / args.density,
        args.size.1 as f32 / args.density,
    );
    let screen = Rect::from_min_size(Pos2::ZERO, points);
    for frame in 0..args.frames {
        let raw = egui::RawInput {
            viewport_id: ViewportId::ROOT,
            screen_rect: Some(screen),
            max_texture_side: Some(8192),
            time: Some(start.elapsed().as_secs_f64()),
            ..Default::default()
        };
        let mut output = ctx.run_ui(raw, |ui| {
            app.background_frame(ui.ctx());
            app.frame_ui(ui);
        });
        let primitives =
            ctx.tessellate(std::mem::take(&mut output.shapes), output.pixels_per_point);
        surface.paint(
            &primitives,
            &mut output.textures_delta,
            args.density,
            zapfast::backdrop::clear_color(app.palette.window),
        );
        eprintln!("frame {frame} painted");
    }
    match surface.save_png(&args.out) {
        Ok(()) => eprintln!("wrote {}", args.out.display()),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
    let _ = std::fs::remove_dir_all(&root);
}

fn parse() -> Args {
    let mut args = Args {
        out: std::path::PathBuf::from("zapfast-ohos-shot.png"),
        size: (1440, 900),
        page: None,
        frames: 4,
        density: 1.0,
        open_chat: false,
    };
    let mut arguments = std::env::args().skip(1);
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--out" => {
                if let Some(value) = arguments.next() {
                    args.out = value.into();
                }
            }
            "--page" => args.page = arguments.next(),
            "--frames" => {
                if let Some(value) = arguments.next().and_then(|v| v.parse().ok()) {
                    args.frames = value;
                }
            }
            "--density" => {
                if let Some(value) = arguments.next().and_then(|v| v.parse().ok()) {
                    args.density = value;
                }
            }
            "--chat" => args.open_chat = true,
            "--size" => {
                if let Some(value) = arguments.next()
                    && let Some((width, height)) = value.split_once('x')
                    && let (Ok(width), Ok(height)) = (width.parse(), height.parse())
                {
                    args.size = (width, height);
                }
            }
            other => eprintln!("ignoring {other}"),
        }
    }
    args
}
