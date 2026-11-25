use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use dashmap::DashMap;
use protocol::{DeviceInfo, DrawerItem, StorageBackendConfig, WsEvent};
use tokio::sync::{mpsc, Mutex, OwnedMutexGuard};

use crate::db::{hydrate_drawer_item, Database, StorageBackendRecord};
use crate::google_login::{GoogleLogin, GoogleLoginConfig};
use crate::storage::{build_provider, local::LocalProvider, StorageProvider};

#[derive(Clone)]
pub struct ConnectionHandle {
    pub user_id: String,
    pub device_id: String,
    pub tx: mpsc::UnboundedSender<WsEvent>,
}

#[derive(Debug, Clone)]
pub struct PendingGoogleOAuth {
    pub user_id: String,
    pub name: String,
    pub client_id: String,
    pub client_secret: String,
    pub folder_id: String,
    pub is_default: bool,
    pub redirect_uri: String,
}

pub struct AppState {
    pub db: Database,
    pub http: reqwest::Client,
    pub jwt_secret: String,
    pub default_local_storage_dir: PathBuf,
    /// Active WebSocket connections keyed by `(user_id, device_id)`.
    pub connections: DashMap<(String, String), mpsc::UnboundedSender<WsEvent>>,
    // Order connection replacement, removal and the corresponding presence events.
    pub(crate) presence_changes: Mutex<()>,
    item_mutations: DashMap<String, Weak<Mutex<()>>>,
    pub(crate) google_login: Option<GoogleLogin>,
    /// Short-lived Google OAuth2 authorization flows keyed by `state` nonce.
    pub pending_google_oauth: DashMap<String, PendingGoogleOAuth>,
    /// Whether `POST /api/auth/register` accepts new accounts (`DROPDRAWER_ALLOW_REGISTRATION`).
    registration_open: AtomicBool,
    /// Failed logins per username.
    pub failed_logins: AttemptLimiter,
    /// Failed passcode attempts per share code.
    pub failed_passcodes: AttemptLimiter,
}

/// Fixed-window counter of failed attempts per key (username, share code, ...).
/// Keys over the limit are refused before any password hash is computed, which
/// bounds both guessing and Argon2 CPU cost.
pub struct AttemptLimiter {
    attempts: DashMap<String, (u32, Instant)>,
    max_failures: u32,
    window: Duration,
}

impl AttemptLimiter {
    pub fn new(max_failures: u32, window: Duration) -> Self {
        Self {
            attempts: DashMap::new(),
            max_failures,
            window,
        }
    }

    pub fn is_blocked(&self, key: &str) -> bool {
        self.attempts
            .get(key)
            .is_some_and(|e| e.1.elapsed() < self.window && e.0 >= self.max_failures)
    }

    pub fn record_failure(&self, key: &str) {
        if self.attempts.len() > 10_000 {
            let window = self.window;
            self.attempts.retain(|_, e| e.1.elapsed() < window);
        }
        let mut entry = self
            .attempts
            .entry(key.to_string())
            .or_insert((0, Instant::now()));
        if entry.1.elapsed() >= self.window {
            *entry = (0, Instant::now());
        }
        entry.0 += 1;
    }

    pub fn reset(&self, key: &str) {
        self.attempts.remove(key);
    }
}

impl AppState {
    pub fn new(db: Database, jwt_secret: String, default_local_storage_dir: PathBuf) -> Arc<Self> {
        Self::with_google_login(db, jwt_secret, default_local_storage_dir, None)
    }

    pub fn with_google_login(
        db: Database,
        jwt_secret: String,
        default_local_storage_dir: PathBuf,
        google_config: Option<GoogleLoginConfig>,
    ) -> Arc<Self> {
        let http = reqwest::Client::builder()
            .pool_idle_timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("failed to build reqwest client");
        Arc::new(Self {
            db,
            http,
            jwt_secret,
            default_local_storage_dir,
            connections: DashMap::new(),
            presence_changes: Mutex::new(()),
            item_mutations: DashMap::new(),
            google_login: google_config.map(GoogleLogin::new),
            pending_google_oauth: DashMap::new(),
            registration_open: AtomicBool::new(true),
            failed_logins: AttemptLimiter::new(10, Duration::from_secs(15 * 60)),
            failed_passcodes: AttemptLimiter::new(10, Duration::from_secs(15 * 60)),
        })
    }

    pub fn registration_open(&self) -> bool {
        self.registration_open.load(Ordering::Relaxed)
    }

    pub fn set_registration_open(&self, open: bool) {
        self.registration_open.store(open, Ordering::Relaxed);
    }

    // Serialize storage changes for one item without holding a map guard across an await.
    pub(crate) async fn lock_drawer_item(&self, item_id: &str) -> OwnedMutexGuard<()> {
        if self.item_mutations.len() > 1024 {
            self.item_mutations
                .retain(|_, lock| lock.strong_count() != 0);
        }
        let lock = {
            let mut entry = self.item_mutations.entry(item_id.to_owned()).or_default();
            match entry.upgrade() {
                Some(lock) => lock,
                None => {
                    let lock = Arc::new(Mutex::new(()));
                    *entry = Arc::downgrade(&lock);
                    lock
                }
            }
        };
        lock.lock_owned().await
    }

    pub(crate) async fn delete_drawer_item(
        &self,
        user_id: &str,
        item_id: &str,
    ) -> anyhow::Result<bool> {
        let _item_lock = self.lock_drawer_item(item_id).await;
        let Some(item) = self.db.get_drawer_item(item_id, user_id)? else {
            return Ok(false);
        };
        if let Some(storage_path) = item.storage_path.as_deref() {
            let backend_id = item
                .storage_backend_id
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("missing storage backend for drawer file"))?;
            let backend = self.resolve_backend(user_id, Some(backend_id))?;
            self.build_storage_provider(&backend)?
                .delete(storage_path)
                .await?;
        }
        self.db.delete_drawer_item(item_id, user_id)?;
        self.broadcast_user(
            user_id,
            WsEvent::ItemDeleted {
                item_id: item_id.to_owned(),
            },
        );
        Ok(true)
    }

    /// The only directory a user's server-local storage may live in.
    pub fn user_local_storage_dir(&self, user_id: &str) -> PathBuf {
        self.default_local_storage_dir.join(user_id)
    }

    pub fn is_device_online(&self, user_id: &str, device_id: &str) -> bool {
        self.connections
            .get(&(user_id.to_string(), device_id.to_string()))
            .is_some_and(|tx| !tx.is_closed())
    }

    pub fn list_devices_with_presence(&self, user_id: &str) -> anyhow::Result<Vec<DeviceInfo>> {
        let mut devices = self.db.list_devices(user_id)?;
        for d in &mut devices {
            d.online = self.is_device_online(user_id, &d.id);
        }
        Ok(devices)
    }

    pub fn list_hydrated_items(&self, user_id: &str) -> anyhow::Result<Vec<DrawerItem>> {
        let devices = self.list_devices_with_presence(user_id)?;
        let backends = self.db.list_storage_backends(user_id)?;
        let rows = self.db.list_drawer_items(user_id)?;
        Ok(rows
            .iter()
            .map(|r| hydrate_drawer_item(r, &devices, &backends))
            .collect())
    }

    pub fn hydrate_single_item(
        &self,
        user_id: &str,
        item_id: &str,
    ) -> anyhow::Result<Option<DrawerItem>> {
        let Some(row) = self.db.get_drawer_item(item_id, user_id)? else {
            return Ok(None);
        };
        let devices = self.list_devices_with_presence(user_id)?;
        let backends = self.db.list_storage_backends(user_id)?;
        Ok(Some(hydrate_drawer_item(&row, &devices, &backends)))
    }

    pub fn broadcast_user(&self, user_id: &str, event: WsEvent) {
        for entry in self.connections.iter() {
            if entry.key().0 == user_id {
                let _ = entry.value().send(event.clone());
            }
        }
    }

    pub fn send_to_device(&self, user_id: &str, device_id: &str, event: WsEvent) -> bool {
        if let Some(tx) = self
            .connections
            .get(&(user_id.to_string(), device_id.to_string()))
        {
            return tx.send(event).is_ok();
        }
        false
    }

    pub fn resolve_backend(
        &self,
        user_id: &str,
        backend_id: Option<&str>,
    ) -> anyhow::Result<StorageBackendRecord> {
        if let Some(id) = backend_id {
            if let Some(rec) = self.db.get_storage_backend(id, user_id)? {
                return Ok(rec);
            }
            anyhow::bail!("storage backend '{id}' not found");
        }
        if let Some(rec) = self.db.get_default_storage_backend(user_id)? {
            return Ok(rec);
        }
        // Auto-provision a default local storage backend for the user if none is configured yet.
        let user_dir = self.user_local_storage_dir(user_id);
        let cfg = StorageBackendConfig::Local {
            root_dir: user_dir.to_string_lossy().to_string(),
            max_bytes: None,
        };
        let id = uuid::Uuid::new_v4().to_string();
        self.db
            .create_storage_backend(&id, user_id, "Server Local Disk", &cfg, true)
    }

    pub fn build_storage_provider(
        &self,
        record: &StorageBackendRecord,
    ) -> anyhow::Result<Box<dyn StorageProvider>> {
        if let StorageBackendConfig::Local {
            root_dir,
            max_bytes,
        } = &record.config
        {
            // Users must never point server-local storage at arbitrary server paths.
            // Older clients could store `root_dir` as the shared storage root itself,
            // so accept that or anything inside the owner's own directory, and pin
            // every key to the owner's namespace either way.
            let root = normalize_path(Path::new(root_dir));
            let shared = normalize_path(&self.default_local_storage_dir);
            let own = normalize_path(&self.user_local_storage_dir(&record.user_id));
            if root != shared && !root.starts_with(&own) {
                anyhow::bail!("local storage directory is outside the server storage area");
            }
            return Ok(Box::new(
                LocalProvider::new(root, *max_bytes)?.restrict_keys_to(record.user_id.clone()),
            ));
        }
        build_provider(&record.config, self.http.clone())
    }
}

/// Absolute, lexically normalized form of `path` (`.`/`..` resolved without touching the filesystem).
fn normalize_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join(path)
    };
    let mut out = PathBuf::new();
    for comp in absolute.components() {
        match comp {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limiter_blocks_after_max_failures_until_reset() {
        let limiter = AttemptLimiter::new(3, Duration::from_secs(60));
        for _ in 0..3 {
            assert!(!limiter.is_blocked("k"));
            limiter.record_failure("k");
        }
        assert!(limiter.is_blocked("k"));
        assert!(!limiter.is_blocked("other"));
        limiter.reset("k");
        assert!(!limiter.is_blocked("k"));

        let short = AttemptLimiter::new(1, Duration::from_millis(1));
        short.record_failure("k");
        std::thread::sleep(Duration::from_millis(5));
        assert!(!short.is_blocked("k"));
    }

    #[test]
    fn normalize_resolves_dot_segments() {
        assert_eq!(
            normalize_path(Path::new("/data/blobs/../blobs/./u1")),
            PathBuf::from("/data/blobs/u1")
        );
        assert_eq!(normalize_path(Path::new("/data/../../etc")), PathBuf::from("/etc"));
    }
}
