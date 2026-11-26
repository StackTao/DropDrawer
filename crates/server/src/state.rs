use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock, Weak};
use std::time::{Duration, Instant};

use dashmap::DashMap;
use protocol::{DeviceInfo, DrawerItem, StorageBackendConfig, WsEvent};
use tokio::sync::{mpsc, Mutex, OwnedMutexGuard};

use crate::admin::AdminAuthConfig;
use crate::db::{hydrate_drawer_item, Database, StorageBackendRecord};
use crate::google_login::{GoogleLogin, GoogleLoginConfig};
use crate::mailer::{EmailSender, OutgoingEmail, SmtpEmailSender};
use crate::net_guard::PrivateNetworkGuard;
use crate::settings::{
    GoogleProviderSettings, RUNTIME_SETTINGS_KEY, RegistrationMode, RuntimeSettings, SmtpSettings,
};
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
    pub expires_at: Instant,
}

pub struct AppState {
    pub db: Database,
    pub http: reqwest::Client,
    pub jwt_secret: String,
    pub default_local_storage_dir: PathBuf,
    /// Active WebSocket connections keyed by `(user_id, device_id)`.
    pub connections: DashMap<(String, String), mpsc::UnboundedSender<WsEvent>>,
    pub(crate) ready_files: DashMap<(String, String), std::collections::BTreeMap<String, String>>,
    // Order connection replacement, removal and the corresponding presence events.
    pub(crate) presence_changes: Mutex<()>,
    item_mutations: DashMap<String, Weak<Mutex<()>>>,
    storage_locks: DashMap<(String, String), Weak<Mutex<()>>>,
    settings: RwLock<RuntimeSettings>,
    google_login: RwLock<Option<Arc<GoogleLogin>>>,
    email_sender: RwLock<Arc<dyn EmailSender>>,
    has_custom_email_sender: AtomicBool,
    pub admin_auth: Option<AdminAuthConfig>,
    /// Short-lived Google OAuth2 authorization flows keyed by `state` nonce.
    pub pending_google_oauth: DashMap<String, PendingGoogleOAuth>,
    /// Failed logins per client IP and normalized username.
    pub failed_logins: AttemptLimiter,
    /// Public share lookups that found no matching code, per client IP.
    pub failed_share_lookups: AttemptLimiter,
    /// Failed passcode attempts per share code.
    pub failed_passcodes: AttemptLimiter,
    /// Failed admin token attempts per client IP.
    pub failed_admin_logins: AttemptLimiter,
    /// Server-wide ceiling on failed admin token attempts (all IPs together).
    pub failed_admin_logins_global: AttemptLimiter,
    /// Generation of admin sessions; bumping it signs every admin out.
    admin_epoch: AtomicU64,
    /// Mirrors `storage_policy.block_private_endpoints` into the HTTP client.
    network_guard: PrivateNetworkGuard,
    /// Serializes read-modify-write updates of the runtime settings.
    pub(crate) settings_update: Mutex<()>,
    pub started_at: Instant,
    /// Email verification send attempts per email.
    pub email_send_limiter: AttemptLimiter,
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
        Self::with_google_login(db, jwt_secret, default_local_storage_dir, None, None)
    }

    pub fn with_google_login(
        db: Database,
        jwt_secret: String,
        default_local_storage_dir: PathBuf,
        google_config: Option<GoogleLoginConfig>,
        local_max_file_bytes: Option<u64>,
    ) -> Arc<Self> {
        let mut initial = RuntimeSettings {
            local_max_file_bytes,
            ..RuntimeSettings::default()
        };
        if let Some(cfg) = &google_config {
            initial.google = GoogleProviderSettings::from_google_config(cfg);
        }
        Self::with_full_config(db, jwt_secret, default_local_storage_dir, initial, None)
    }

    pub fn with_full_config(
        db: Database,
        jwt_secret: String,
        default_local_storage_dir: PathBuf,
        env_defaults: RuntimeSettings,
        admin_auth: Option<AdminAuthConfig>,
    ) -> Arc<Self> {
        // Persisted admin settings take precedence over env defaults once saved.
        let effective_settings = db
            .get_setting(RUNTIME_SETTINGS_KEY)
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<RuntimeSettings>(&raw).ok())
            .unwrap_or(env_defaults);
        let google_login = effective_settings
            .google
            .to_google_config()
            .ok()
            .flatten()
            .map(|cfg| Arc::new(GoogleLogin::new(cfg)));
        let network_guard =
            PrivateNetworkGuard::new(effective_settings.storage_policy.block_private_endpoints);
        let http = network_guard.build_client();
        Arc::new(Self {
            network_guard,
            db,
            http,
            jwt_secret,
            default_local_storage_dir,
            connections: DashMap::new(),
            ready_files: DashMap::new(),
            presence_changes: Mutex::new(()),
            item_mutations: DashMap::new(),
            storage_locks: DashMap::new(),
            settings: RwLock::new(effective_settings),
            google_login: RwLock::new(google_login),
            email_sender: RwLock::new(Arc::new(SmtpEmailSender)),
            has_custom_email_sender: AtomicBool::new(false),
            admin_auth,
            pending_google_oauth: DashMap::new(),
            failed_logins: AttemptLimiter::new(10, Duration::from_secs(15 * 60)),
            failed_share_lookups: AttemptLimiter::new(60, Duration::from_secs(60)),
            failed_passcodes: AttemptLimiter::new(10, Duration::from_secs(15 * 60)),
            failed_admin_logins: AttemptLimiter::new(8, Duration::from_secs(15 * 60)),
            failed_admin_logins_global: AttemptLimiter::new(60, Duration::from_secs(15 * 60)),
            admin_epoch: AtomicU64::new(rand_epoch()),
            settings_update: Mutex::new(()),
            started_at: Instant::now(),
            email_send_limiter: AttemptLimiter::new(10, Duration::from_secs(15 * 60)),
        })
    }

    pub fn admin_epoch(&self) -> u64 {
        self.admin_epoch.load(Ordering::Relaxed)
    }

    /// Invalidate every admin session issued so far.
    pub fn revoke_admin_sessions(&self) {
        self.admin_epoch.fetch_add(1, Ordering::Relaxed);
    }

    pub fn runtime_settings(&self) -> RuntimeSettings {
        self.settings
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    pub fn apply_and_persist_settings(&self, next: RuntimeSettings) -> anyhow::Result<()> {
        let google = next
            .google
            .to_google_config()?
            .map(|cfg| Arc::new(GoogleLogin::new(cfg)));
        let serialized = serde_json::to_string(&next)?;
        self.db.set_setting(RUNTIME_SETTINGS_KEY, &serialized)?;
        self.network_guard
            .set(next.storage_policy.block_private_endpoints);
        *self.settings.write().unwrap_or_else(|p| p.into_inner()) = next;
        *self.google_login.write().unwrap_or_else(|p| p.into_inner()) = google;
        Ok(())
    }

    pub(crate) fn google_login(&self) -> Option<Arc<GoogleLogin>> {
        self.google_login
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    pub fn local_max_file_bytes(&self) -> Option<u64> {
        self.runtime_settings().local_max_file_bytes
    }

    pub fn default_user_local_quota_bytes(&self) -> Option<u64> {
        self.runtime_settings().default_user_local_quota_bytes
    }

    pub fn set_email_sender(&self, sender: Arc<dyn EmailSender>) {
        *self.email_sender.write().unwrap_or_else(|p| p.into_inner()) = sender;
        self.has_custom_email_sender.store(true, Ordering::Relaxed);
    }

    pub fn has_custom_email_sender(&self) -> bool {
        self.has_custom_email_sender.load(Ordering::Relaxed)
    }

    pub async fn send_email(&self, email: &OutgoingEmail) -> anyhow::Result<()> {
        let smtp = self.runtime_settings().smtp;
        if !smtp.is_usable() && !self.has_custom_email_sender() {
            anyhow::bail!("服务器未启用 SMTP 邮件服务");
        }
        self.send_email_with_config(&smtp, email).await
    }

    pub async fn send_email_with_config(
        &self,
        smtp: &SmtpSettings,
        email: &OutgoingEmail,
    ) -> anyhow::Result<()> {
        let sender = self
            .email_sender
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        sender.send(smtp, email).await
    }

    pub fn registration_open(&self) -> bool {
        self.runtime_settings().registration_mode == RegistrationMode::Open
    }

    pub fn set_registration_open(&self, open: bool) {
        let mut guard = self.settings.write().unwrap_or_else(|p| p.into_inner());
        guard.registration_mode = if open {
            RegistrationMode::Open
        } else {
            RegistrationMode::Closed
        };
    }

    pub fn disconnect_user(&self, user_id: &str) {
        let keys: Vec<(String, String)> = self
            .connections
            .iter()
            .filter(|e| e.key().0 == user_id)
            .map(|e| e.key().clone())
            .collect();
        for key in keys {
            self.connections.remove(&key);
            self.ready_files.remove(&key);
        }
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

    // Serialize dedup reuse & ref-counted deletion of one `(storage_backend_id, storage_path)` blob.
    // Lock ordering invariant: always acquire `lock_drawer_item` BEFORE `lock_storage_object`.
    pub(crate) async fn lock_storage_object(
        &self,
        backend_id: &str,
        storage_path: &str,
    ) -> OwnedMutexGuard<()> {
        if self.storage_locks.len() > 1024 {
            self.storage_locks
                .retain(|_, lock| lock.strong_count() != 0);
        }
        let lock = {
            let mut entry = self
                .storage_locks
                .entry((backend_id.to_owned(), storage_path.to_owned()))
                .or_default();
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
            let _storage_lock = self.lock_storage_object(backend_id, storage_path).await;
            let other_refs = self.db.count_other_storage_refs(
                user_id,
                backend_id,
                storage_path,
                item_id,
            )?;
            if other_refs == 0 {
                let backend = self.resolve_backend(user_id, Some(backend_id))?;
                let settings = self.runtime_settings();
                if let Err(err) =
                    crate::policy::ensure_endpoints_allowed(&settings, &backend.config).await
                {
                    // The admin has since blocked this endpoint; drop the record without
                    // contacting it so the item (and TTL cleanup) is not stuck forever.
                    tracing::warn!(item_id, "skipping remote blob deletion: {err}");
                } else {
                    self.build_storage_provider(&backend)?
                        .delete(storage_path)
                        .await?;
                }
            }
            self.db.delete_drawer_item(item_id, user_id)?;
        } else {
            self.db.delete_drawer_item(item_id, user_id)?;
        }
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

    pub(crate) fn fill_device_presence(&self, device: &mut DeviceInfo) {
        device.online = self.is_device_online(&device.user_id, &device.id);
        device.replica_items = self
            .ready_files
            .get(&(device.user_id.clone(), device.id.clone()))
            .map(|files| files.keys().cloned().collect())
            .unwrap_or_default();
    }

    pub fn list_devices_with_presence(&self, user_id: &str) -> anyhow::Result<Vec<DeviceInfo>> {
        let mut devices = self.db.list_devices(user_id)?;
        for d in &mut devices {
            self.fill_device_presence(d);
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

    pub fn broadcast_all(&self, event: WsEvent) {
        for entry in self.connections.iter() {
            let _ = entry.value().send(event.clone());
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
        // The admin quota is applied when the provider is built, so it can change later.
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
            let effective_quota =
                crate::policy::effective_local_quota(self, &record.user_id, *max_bytes);
            return Ok(Box::new(
                LocalProvider::new(root, effective_quota)?
                    .with_max_file_bytes(self.local_max_file_bytes())
                    .restrict_keys_to(record.user_id.clone()),
            ));
        }
        build_provider(&record.config, self.http.clone())
    }

    /// Build a provider for a request handler, refusing endpoints blocked by the storage policy.
    pub async fn storage_provider(
        &self,
        record: &StorageBackendRecord,
    ) -> anyhow::Result<Box<dyn StorageProvider>> {
        crate::policy::ensure_endpoints_allowed(&self.runtime_settings(), &record.config).await?;
        self.build_storage_provider(record)
    }
}

fn rand_epoch() -> u64 {
    use rand::RngCore;
    // Keep it small enough to round-trip through JSON numbers exactly.
    rand::rngs::OsRng.next_u64() >> 12
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
