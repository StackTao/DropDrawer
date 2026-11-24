use std::path::PathBuf;
use std::sync::Arc;

use dashmap::DashMap;
use protocol::{DeviceInfo, DrawerItem, StorageBackendConfig, WsEvent};
use tokio::sync::mpsc;

use crate::db::{hydrate_drawer_item, Database, StorageBackendRecord};
use crate::storage::{build_provider, StorageProvider};

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
    /// Short-lived Google OAuth2 authorization flows keyed by `state` nonce.
    pub pending_google_oauth: DashMap<String, PendingGoogleOAuth>,
}

impl AppState {
    pub fn new(db: Database, jwt_secret: String, default_local_storage_dir: PathBuf) -> Arc<Self> {
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
            pending_google_oauth: DashMap::new(),
        })
    }

    pub fn is_device_online(&self, user_id: &str, device_id: &str) -> bool {
        self.connections
            .contains_key(&(user_id.to_string(), device_id.to_string()))
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
        let mut dead = Vec::new();
        for entry in self.connections.iter() {
            if entry.key().0 == user_id {
                if entry.value().send(event.clone()).is_err() {
                    dead.push(entry.key().clone());
                }
            }
        }
        for key in dead {
            self.connections.remove(&key);
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
        let user_dir = self.default_local_storage_dir.join(user_id);
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
        build_provider(&record.config, self.http.clone())
    }
}
