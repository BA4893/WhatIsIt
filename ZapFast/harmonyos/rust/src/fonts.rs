//! HarmonyOS's own fonts for egui.
//!
//! fastframe-fonts finds the interface font through fontconfig and the XDG
//! data directories on Linux; HarmonyOS keeps its fonts in `/system/fonts`
//! instead, so the lookup finds nothing and the interface would fall back to
//! the bundled Inter without any CJK glyphs. Here HarmonyOS Sans (the Latin
//! interface font) and HarmonyOS Sans SC (Simplified Chinese, and the fallback
//! that covers CJK in general) are added as egui fallbacks, so a chat in any
//! of those scripts draws with the system's own typeface. Inter stays where
//! the app chose it; these fill in what it cannot draw.

/// The fonts, in the order they are offered as fallbacks.
const FONTS: [(&str, &str); 2] = [
    ("HarmonyOS Sans", "/system/fonts/HarmonyOS_Sans.ttf"),
    ("HarmonyOS Sans SC", "/system/fonts/HarmonyOS_Sans_SC.ttf"),
];

/// Adds HarmonyOS's fonts to `ctx` as fallbacks. Cheap to call again: egui
/// skips a font whose name is already installed.
pub fn install(ctx: &egui::Context) {
    for (name, path) in FONTS {
        let path = std::path::Path::new(path);
        if !path.is_file() {
            log::info!("{} is not on this device", path.display());
            continue;
        }
        match std::fs::read(path) {
            Ok(bytes) => {
                log::info!("adding {} ({} KiB) as a fallback", name, bytes.len() / 1024);
                ctx.add_font(egui::epaint::text::FontInsert::new(
                    name,
                    egui::FontData::from_owned(bytes),
                    vec![egui::epaint::text::InsertFontFamily {
                        family: egui::FontFamily::Proportional,
                        priority: egui::epaint::text::FontPriority::Lowest,
                    }],
                ));
            }
            Err(error) => log::warn!("could not read {}: {error}", path.display()),
        }
    }
}
