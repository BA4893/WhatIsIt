//! ZapFast's credential store on HarmonyOS.
//!
//! ZapFast keeps each archive's SQLCipher key in the OS keyring. HarmonyOS
//! has no keyring API of the shape `keyring-core` expects, so this store
//! keeps the same entries in one private file inside the app's own sandbox,
//! written atomically with mode 0600. Nothing leaves the app: the file has
//! the same protection as the encrypted archive beside it, and HarmonyOS
//! keeps an app's sandbox away from other apps.
//!
//! This is deliberately a small, auditable stand-in. The asset store
//! (`libasset_ndk.z.so`, `OH_Asset_Add` and friends) is hardware-backed and
//! is the intended home for these secrets; when it is bound here, only the
//! contents of [`write_all`] and [`read_all`] change, and every caller stays
//! the same. Until then, do not describe the archive key as hardware-backed
//! in the interface.
//!
//! The file is a tab-separated list of `hex(service)`, `hex(user)` and
//! `hex(secret)` lines: no JSON dependency, and no escaping questions. A
//! record is looked up by service and user, exactly as an OS keyring entry is.

use std::collections::HashMap;
use std::fmt::Debug;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use keyring_core::api::{CredentialApi, CredentialPersistence, CredentialStoreApi};
use keyring_core::{Credential, Entry, Error, Result};

/// The name of the private file inside the sandbox directory.
const FILE: &str = "keyring";

static ROOT: OnceLock<PathBuf> = OnceLock::new();
static STORE: OnceLock<Arc<Store>> = OnceLock::new();

/// Points the store at its directory and makes it the default store.
///
/// Call once at startup, after the app's `filesDir` is known and before the
/// archive opens. A second call is ignored: the first directory wins, so two
/// accounts can never write their keys elsewhere.
pub fn init(root: impl Into<PathBuf>) {
    let Ok(()) = ROOT.set(root.into()) else {
        return;
    };
    let root = ROOT.get().expect("set just above");
    let store = Arc::new(Store::at(root));
    let _ = STORE.set(Arc::clone(&store));
    keyring_core::set_default_store(store);
}

/// The store [`init`] made, for the archive's own `platform_store`.
///
/// # Panics
///
/// Panics when called before [`init`]; the app calls it first thing.
pub fn store() -> Arc<dyn CredentialStoreApi> {
    let store = STORE
        .get()
        .expect("zapfast_ohos_keyring::init must run before the archive opens");
    Arc::clone(store) as Arc<dyn CredentialStoreApi>
}

/// A store of credentials in one file.
pub struct Store {
    path: PathBuf,
    /// Serializes reads and writes inside the process.
    lock: Arc<Mutex<()>>,
}

impl Store {
    fn at(root: &Path) -> Self {
        Self {
            path: root.join(FILE),
            lock: Arc::new(Mutex::new(())),
        }
    }
}

impl std::fmt::Debug for Store {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Store").field("path", &self.path).finish()
    }
}

impl CredentialStoreApi for Store {
    fn vendor(&self) -> String {
        "zapfast-ohos-keyring".to_owned()
    }

    fn id(&self) -> String {
        "zapfast-ohos-keyring 1".to_owned()
    }

    fn build(
        &self,
        service: &str,
        user: &str,
        _modifiers: Option<&HashMap<&str, &str>>,
    ) -> Result<Entry> {
        if service.is_empty() || user.is_empty() {
            return Err(Error::Invalid(
                "service and user".to_owned(),
                "must not be empty".to_owned(),
            ));
        }
        let credential: Arc<Credential> = Arc::new(Cred {
            path: self.path.clone(),
            lock: Arc::clone(&self.lock),
            service: service.to_owned(),
            user: user.to_owned(),
        });
        Ok(Entry::new_with_credential(credential))
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn persistence(&self) -> CredentialPersistence {
        CredentialPersistence::UntilDelete
    }

    fn debug_fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}

/// One entry: a service and a user in the store above.
struct Cred {
    path: PathBuf,
    lock: Arc<Mutex<()>>,
    service: String,
    user: String,
}

impl Cred {
    fn locked(&self) -> std::sync::MutexGuard<'_, ()> {
        self.lock.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl CredentialApi for Cred {
    fn set_secret(&self, secret: &[u8]) -> Result<()> {
        let _guard = self.locked();
        let mut all = read_all(&self.path)?;
        all.insert((self.service.clone(), self.user.clone()), secret.to_vec());
        write_all(&self.path, &all)
    }

    fn get_secret(&self) -> Result<Vec<u8>> {
        let _guard = self.locked();
        let all = read_all(&self.path)?;
        all.get(&(self.service.clone(), self.user.clone()))
            .cloned()
            .ok_or(Error::NoEntry)
    }

    fn delete_credential(&self) -> Result<()> {
        let _guard = self.locked();
        let mut all = read_all(&self.path)?;
        if all
            .remove(&(self.service.clone(), self.user.clone()))
            .is_none()
        {
            return Err(Error::NoEntry);
        }
        write_all(&self.path, &all)
    }

    fn get_credential(&self) -> Result<Option<Arc<Credential>>> {
        Ok(None)
    }

    fn get_specifiers(&self) -> Option<(String, String)> {
        Some((self.service.clone(), self.user.clone()))
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn debug_fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cred")
            .field("service", &self.service)
            .field("user", &self.user)
            .finish_non_exhaustive()
    }
}

type Key = (String, String);

fn read_all(path: &Path) -> Result<HashMap<Key, Vec<u8>>> {
    let contents = match std::fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(error) => return Err(Error::PlatformFailure(Box::new(error))),
    };
    let mut all = HashMap::new();
    for line in contents.lines().filter(|line| !line.is_empty()) {
        let mut fields = line.split('\t');
        let (Some(service), Some(user), Some(secret), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            log::warn!("keyring: skipping a malformed line");
            continue;
        };
        let (Some(service), Some(user), Some(secret)) =
            (unhex(service), unhex(user), unhex(secret))
        else {
            log::warn!("keyring: skipping a malformed line");
            continue;
        };
        let (Ok(service), Ok(user)) = (String::from_utf8(service), String::from_utf8(user)) else {
            log::warn!("keyring: skipping a record whose names are not UTF-8");
            continue;
        };
        all.insert((service, user), secret);
    }
    Ok(all)
}

fn write_all(path: &Path, all: &HashMap<Key, Vec<u8>>) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| Error::PlatformFailure(Box::new(error)))?;
    }
    let mut contents = String::new();
    // Stable order, so a file diff reads as the entries that changed.
    let mut records: Vec<_> = all.iter().collect();
    records.sort_by(|a, b| a.0.cmp(b.0));
    for ((service, user), secret) in records {
        contents.push_str(&hex(service.as_bytes()));
        contents.push('\t');
        contents.push_str(&hex(user.as_bytes()));
        contents.push('\t');
        contents.push_str(&hex(secret));
        contents.push('\n');
    }
    let staging = path.with_extension("new");
    let write = || -> std::io::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&staging)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&staging, path)?;
        Ok(())
    };
    write().map_err(|error| Error::PlatformFailure(Box::new(error)))
}

fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(&mut text, "{byte:02x}");
    }
    text
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    let mut bytes = Vec::with_capacity(text.len() / 2);
    let raw = text.as_bytes();
    for pair in raw.chunks_exact(2) {
        let high = (pair[0] as char).to_digit(16)?;
        let low = (pair[1] as char).to_digit(16)?;
        bytes.push(u8::try_from(high * 16 + low).ok()?);
    }
    Some(bytes)
}

impl Debug for Cred {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cred")
            .field("service", &self.service)
            .field("user", &self.user)
            .finish_non_exhaustive()
    }
}
