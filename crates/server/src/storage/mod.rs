pub mod baidu;
pub mod google_drive;
pub mod local;
pub mod quark;
pub mod s3;
pub mod webdav;

use std::pin::Pin;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::Stream;
use protocol::StorageBackendConfig;

pub type ByteStream = Pin<Box<dyn Stream<Item = Result<Bytes, anyhow::Error>> + Send + 'static>>;

/// Result returned by a storage provider after storing an object.
/// `stored_key` is persisted on the drawer item (e.g. a Google Drive fileId, Quark fid, Baidu fs_id|path, or S3 key).
#[derive(Debug, Clone)]
pub struct PutResult {
    pub bytes_written: u64,
    pub stored_key: String,
}

pub enum DownloadResolution {
    /// Direct URL (e.g. S3 presigned GET URL) that clients can pull without server bandwidth.
    DirectUrl(String),
    /// Streamed proxy response from server.
    Stream {
        stream: ByteStream,
        content_length: Option<u64>,
        content_type: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub struct PresignedUpload {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

#[async_trait]
pub trait StorageProvider: Send + Sync {
    /// Optional direct client-to-storage presigned PUT (used by S3-compatible backends).
    fn presign_upload(&self, _remote_key: &str, _expires_secs: u64) -> Option<PresignedUpload> {
        None
    }

    /// Stream bytes into the storage backend.
    async fn put_stream(
        &self,
        remote_key: &str,
        content_length: Option<u64>,
        stream: ByteStream,
    ) -> anyhow::Result<PutResult>;

    /// Resolve a download either as a direct URL or as a server stream.
    async fn resolve_download(&self, stored_key: &str) -> anyhow::Result<DownloadResolution>;

    /// Delete a stored object (used for manual removal and TTL expiration).
    async fn delete(&self, stored_key: &str) -> anyhow::Result<()>;

    /// Verify connectivity & credentials.
    async fn health_check(&self) -> anyhow::Result<String>;
}

pub fn build_provider(
    config: &StorageBackendConfig,
    http: reqwest::Client,
) -> anyhow::Result<Box<dyn StorageProvider>> {
    match config {
        StorageBackendConfig::Local {
            root_dir,
            max_bytes,
        } => Ok(Box::new(local::LocalProvider::new(
            root_dir.clone(),
            *max_bytes,
        )?)),
        StorageBackendConfig::GoogleDrive {
            client_id,
            client_secret,
            refresh_token,
            folder_id,
            api_base_url,
            token_url,
        } => Ok(Box::new(google_drive::GoogleDriveProvider::new(
            http,
            google_drive::GoogleDriveConfig {
                client_id: client_id.clone(),
                client_secret: client_secret.clone(),
                refresh_token: refresh_token.clone(),
                folder_id: folder_id.clone(),
                api_base_url: api_base_url.clone(),
                token_url: token_url.clone(),
            },
        ))),
        StorageBackendConfig::Quark {
            cookie,
            root_folder_id,
            api_base_url,
        } => Ok(Box::new(quark::QuarkProvider::new(
            http,
            cookie.clone(),
            root_folder_id.clone(),
            api_base_url.clone(),
        ))),
        StorageBackendConfig::BaiduNetdisk {
            client_id,
            client_secret,
            refresh_token,
            access_token,
            root_path,
            api_base_url,
        } => Ok(Box::new(baidu::BaiduNetdiskProvider::new(
            http,
            baidu::BaiduNetdiskConfig {
                client_id: client_id.clone(),
                client_secret: client_secret.clone(),
                refresh_token: refresh_token.clone(),
                access_token: access_token.clone(),
                root_path: root_path.clone(),
                api_base_url: api_base_url.clone(),
            },
        ))),
        StorageBackendConfig::WebDav {
            base_url,
            username,
            password,
        } => Ok(Box::new(webdav::WebDavProvider::new(
            http,
            base_url.clone(),
            username.clone(),
            password.clone(),
        ))),
        StorageBackendConfig::S3 {
            endpoint,
            region,
            bucket,
            access_key_id,
            secret_access_key,
            prefix,
            force_path_style,
        } => Ok(Box::new(s3::S3Provider::new(
            http,
            s3::S3Config {
                endpoint: endpoint.clone(),
                region: region.clone(),
                bucket: bucket.clone(),
                access_key_id: access_key_id.clone(),
                secret_access_key: secret_access_key.clone(),
                prefix: prefix.clone(),
                force_path_style: *force_path_style,
            },
        )?)),
    }
}
