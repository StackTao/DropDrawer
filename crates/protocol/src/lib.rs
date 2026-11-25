use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Client operating system platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DevicePlatform {
    Macos,
    Windows,
    Linux,
    Android,
    Ios,
    Web,
}

/// How a drawer item's payload is currently stored / available.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferMode {
    /// File remains on source device; pulled via end-to-end P2P (QUIC / relay fallback).
    P2pOnly,
    /// File is stored on a configured server/cloud storage backend (downloadable even if sender is offline).
    CloudCached,
    /// Available both via P2P when sender is online and via cloud backend when offline.
    Hybrid,
}

/// Kind of content held in a drawer slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DrawerItemKind {
    File,
    Text,
}

/// Supported native server-side / cloud storage backend types (zero external sidecars required).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StorageBackendKind {
    /// Local disk on the DropDrawer server.
    Local,
    /// Native Google Drive API v3 (OAuth2 refresh token + Resumable Upload).
    GoogleDrive,
    /// Native Quark Cloud Drive (drive-pc.quark.cn Cookie + OSS direct upload).
    Quark,
    /// Native Baidu Netdisk OpenAPI xpan (OAuth2 + precreate/superfile2/create).
    BaiduNetdisk,
    /// Standard WebDAV server.
    WebDav,
    /// S3-compatible object storage (AWS S3, Cloudflare R2, Aliyun OSS, MinIO) with Presigned URLs.
    S3,
}

/// Transport path actually used during a P2P transfer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum P2pPathKind {
    Direct,
    Relay,
    Unknown,
}

// ============================================================================
// Auth & User Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserProfile {
    pub id: String,
    pub username: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: UserProfile,
}

// ============================================================================
// Device Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterDeviceRequest {
    pub device_id: Option<String>,
    pub name: String,
    pub platform: DevicePlatform,
    pub iroh_node_id: Option<String>,
    pub iroh_relay_url: Option<String>,
    #[serde(default)]
    pub direct_addrs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub id: String,
    pub user_id: String,
    pub name: String,
    pub platform: DevicePlatform,
    pub iroh_node_id: Option<String>,
    pub iroh_relay_url: Option<String>,
    #[serde(default)]
    pub direct_addrs: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub replica_items: Vec<String>,
    pub online: bool,
    pub last_seen_at: DateTime<Utc>,
}

// ============================================================================
// Storage Backend Configuration Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StorageBackendConfig {
    Local {
        root_dir: String,
        #[serde(default)]
        max_bytes: Option<u64>,
    },
    GoogleDrive {
        client_id: String,
        client_secret: String,
        refresh_token: String,
        /// Optional Google Drive folder ID (defaults to "root").
        #[serde(default = "default_gdrive_folder")]
        folder_id: String,
        /// Optional override for API base URL (used in tests / custom proxies).
        #[serde(default)]
        api_base_url: Option<String>,
        /// Optional override for OAuth2 token URL (used in tests).
        #[serde(default)]
        token_url: Option<String>,
    },
    Quark {
        /// Cookie captured from pan.quark.cn.
        cookie: String,
        /// Target folder fid inside Quark Drive (defaults to "0" = root).
        #[serde(default = "default_quark_folder")]
        root_folder_id: String,
        #[serde(default)]
        api_base_url: Option<String>,
    },
    BaiduNetdisk {
        /// Either supply refresh_token + client_id + client_secret (auto-refreshes), or a direct access_token.
        #[serde(default)]
        client_id: String,
        #[serde(default)]
        client_secret: String,
        #[serde(default)]
        refresh_token: String,
        #[serde(default)]
        access_token: String,
        /// Target path under Baidu app sandbox, e.g. "/apps/dropdrawer".
        #[serde(default = "default_baidu_root")]
        root_path: String,
        #[serde(default)]
        api_base_url: Option<String>,
    },
    WebDav {
        /// Base WebDAV URL, e.g. "https://dav.example.com/dav/dropdrawer".
        base_url: String,
        username: String,
        password: String,
    },
    S3 {
        /// S3 API endpoint, e.g. "https://s3.amazonaws.com" or "https://<account>.r2.cloudflarestorage.com".
        endpoint: String,
        region: String,
        bucket: String,
        access_key_id: String,
        secret_access_key: String,
        #[serde(default)]
        prefix: String,
        #[serde(default)]
        force_path_style: bool,
    },
}

fn default_gdrive_folder() -> String {
    "root".to_string()
}

fn default_quark_folder() -> String {
    "0".to_string()
}

fn default_baidu_root() -> String {
    "/apps/dropdrawer".to_string()
}

impl StorageBackendConfig {
    pub fn kind(&self) -> StorageBackendKind {
        match self {
            Self::Local { .. } => StorageBackendKind::Local,
            Self::GoogleDrive { .. } => StorageBackendKind::GoogleDrive,
            Self::Quark { .. } => StorageBackendKind::Quark,
            Self::BaiduNetdisk { .. } => StorageBackendKind::BaiduNetdisk,
            Self::WebDav { .. } => StorageBackendKind::WebDav,
            Self::S3 { .. } => StorageBackendKind::S3,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateStorageBackendRequest {
    pub name: String,
    pub config: StorageBackendConfig,
    #[serde(default)]
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageBackendSummary {
    pub id: String,
    pub name: String,
    pub kind: StorageBackendKind,
    pub is_default: bool,
    pub created_at: DateTime<Utc>,
    /// Non-secret summary fields for UI display (e.g. mount path / bucket / endpoint).
    pub display_target: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageHealthResponse {
    pub ok: bool,
    pub message: String,
}

// ============================================================================
// Drawer Item Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDrawerItemRequest {
    pub device_id: String,
    pub kind: DrawerItemKind,
    pub name: String,
    pub size: u64,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub blake3_hash: Option<String>,
    #[serde(default)]
    pub text_content: Option<String>,
    #[serde(default)]
    pub thumbnail_base64: Option<String>,
    pub transfer_mode: TransferMode,
    /// Optional explicit storage backend to use if uploading to cloud.
    #[serde(default)]
    pub storage_backend_id: Option<String>,
    /// Optional time-to-live in hours before automatic cleanup.
    #[serde(default)]
    pub ttl_hours: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DrawerItem {
    pub id: String,
    pub user_id: String,
    pub owner_device_id: String,
    pub owner_device_name: Option<String>,
    pub owner_online: bool,
    pub owner_iroh_node_id: Option<String>,
    pub owner_iroh_relay_url: Option<String>,
    #[serde(default)]
    pub owner_direct_addrs: Vec<String>,
    pub kind: DrawerItemKind,
    pub name: String,
    pub size: u64,
    pub mime_type: Option<String>,
    pub blake3_hash: Option<String>,
    pub text_content: Option<String>,
    pub thumbnail_base64: Option<String>,
    pub transfer_mode: TransferMode,
    pub storage_backend_id: Option<String>,
    pub storage_backend_name: Option<String>,
    pub cloud_ready: bool,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Response returned when a client requests to upload a drawer item to cloud storage.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "strategy", rename_all = "snake_case")]
pub enum UploadPlan {
    /// Client should PUT directly to the returned presigned URL (S3/R2/OSS), then call /confirm.
    DirectPresignedPut {
        url: String,
        #[serde(default)]
        headers: Vec<(String, String)>,
        storage_backend_id: String,
        remote_key: String,
    },
    /// Client should stream bytes to the server proxy endpoint, which streams directly to Local/OpenList/WebDAV without disk buffering.
    ServerStreamPut {
        url: String,
        storage_backend_id: String,
    },
}

/// Response returned when a client wants to download an item.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadPlan {
    pub item_id: String,
    /// Present when source device is online and P2P transfer is available.
    pub p2p: Option<P2pSourceInfo>,
    /// Present when the item is cached on a storage backend.
    pub cloud: Option<CloudDownloadInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct P2pSourceInfo {
    pub device_id: String,
    pub iroh_node_id: String,
    pub iroh_relay_url: Option<String>,
    #[serde(default)]
    pub direct_addrs: Vec<String>,
    /// Short-lived token that receiver presents to sender over QUIC to authorize pulling this item.
    pub transfer_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replica_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudDownloadInfo {
    /// Either a direct CDN/presigned/OpenList 302 URL or server streaming download URL.
    pub url: String,
    pub is_direct_url: bool,
    pub backend_name: String,
}

// ============================================================================
// Public Share Link Models
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateShareRequest {
    /// Optional passcode required to access/download the shared item.
    #[serde(default)]
    pub passcode: Option<String>,
    /// Optional expiration in hours (None = never expires until item is deleted).
    #[serde(default)]
    pub expires_hours: Option<u64>,
    /// Optional max download count (e.g. Some(1) for burn-after-download).
    #[serde(default)]
    pub max_downloads: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateBatchShareRequest {
    pub item_ids: Vec<String>,
    /// Optional custom title for multi-item bundle shares.
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub passcode: Option<String>,
    #[serde(default)]
    pub expires_hours: Option<u64>,
    #[serde(default)]
    pub max_downloads: Option<u64>,
}

fn default_share_item_count() -> u64 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShareLinkInfo {
    pub code: String,
    pub item_id: String,
    pub item_name: String,
    pub item_kind: DrawerItemKind,
    pub item_size: u64,
    #[serde(default = "default_share_item_count")]
    pub item_count: u64,
    pub has_passcode: bool,
    pub max_downloads: Option<u64>,
    pub download_count: u64,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    /// Relative public URL path, e.g. "/s/a8k2m9xq".
    pub share_path: String,
}

// ============================================================================
// WebSocket Real-Time Events
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum WsEvent {
    /// Initial snapshot sent immediately after WebSocket authentication.
    Snapshot {
        devices: Vec<DeviceInfo>,
        items: Vec<DrawerItem>,
    },
    DeviceUpdated(DeviceInfo),
    ItemAdded(DrawerItem),
    ItemUpdated(DrawerItem),
    ItemDeleted {
        item_id: String,
    },
    /// Sent by server to source device to pre-authorize an incoming P2P pull token.
    AuthorizeP2pToken {
        item_id: String,
        token: String,
        requester_device_id: String,
        expires_at: DateTime<Utc>,
        /// iroh node id of the requesting device, when known; the source only
        /// accepts the token from this peer.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        requester_node_id: Option<String>,
    },
    Pong,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum WsClientCommand {
    Ping,
    UpdateReadyFiles {
        files: std::collections::BTreeMap<String, String>,
    },
    UpdateNodeAddr {
        iroh_node_id: String,
        iroh_relay_url: Option<String>,
        direct_addrs: Vec<String>,
    },
}

// ============================================================================
// P2P Progress & Transfer Events (shared with FFI / UI)
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct P2pTransferProgress {
    /// Remote recipient for outgoing transfers; absent on downloads.
    #[serde(default)]
    pub sending_to: Option<String>,
    #[serde(default)]
    pub cancelled: bool,
    pub transfer_id: String,
    pub item_id: String,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub speed_bps: u64,
    pub path_kind: P2pPathKind,
    pub finished: bool,
    pub saved_path: Option<String>,
    pub error: Option<String>,
}
