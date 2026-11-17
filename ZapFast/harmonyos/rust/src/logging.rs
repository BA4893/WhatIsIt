//! Logging for the HarmonyOS app: stderr for a terminal run, and one file
//! beside the app's other state for a run from the launcher.
//!
//! The log is meant to be attached to a bug report, so it never records
//! message contents, phone numbers, keys or QR payloads: callers use the same
//! redacting filter as the desktop build, and nothing here adds any.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use log::{Level, LevelFilter, Log, Metadata, Record};

static LOGGER: OnceLock<Logger> = OnceLock::new();

/// The process start, for the relative timestamps in the log.
static START: OnceLock<Instant> = OnceLock::new();

struct Logger {
    file: Mutex<Option<std::fs::File>>,
    level: LevelFilter,
}

impl Log for Logger {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.level() <= self.level
    }

    fn log(&self, record: &Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let elapsed = START.get().map_or(0, |start| start.elapsed().as_millis());
        let line = format!(
            "{elapsed:>8}ms {:<5} {}: {}\n",
            record.level(),
            record.target(),
            record.args()
        );
        if record.level() <= Level::Warn {
            let _ = std::io::stderr().write_all(line.as_bytes());
        }
        if let Some(file) = self
            .file
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_mut()
        {
            let _ = file.write_all(line.as_bytes());
            let _ = file.flush();
        }
    }

    fn flush(&self) {
        if let Some(file) = self
            .file
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_mut()
        {
            let _ = file.flush();
        }
    }
}

/// Starts logging into `files_dir/zapfast.log`. A second call does nothing.
pub fn init(files_dir: &Path, verbose: bool) {
    let _ = START.set(Instant::now());
    let level = if verbose {
        LevelFilter::Debug
    } else {
        LevelFilter::Info
    };
    let path = log_path(files_dir);
    let file = path.and_then(|path| {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|error| log::warn!("could not open {}: {error}", path.display()))
            .ok()
    });
    let logger = LOGGER.get_or_init(|| Logger {
        file: Mutex::new(file),
        level,
    });
    if log::set_logger(logger).is_ok() {
        log::set_max_level(level);
    }
    // A panic's message may carry user data; only its place is recorded, as
    // the desktop build does.
    std::panic::set_hook(Box::new(|info| {
        let place = info
            .location()
            .map(|location| format!("{}:{}", location.file(), location.line()))
            .unwrap_or_else(|| "an unknown place".to_owned());
        log::error!("panicked at {place}");
    }));
}

fn log_path(files_dir: &Path) -> Option<PathBuf> {
    Some(files_dir.join("zapfast.log"))
}
