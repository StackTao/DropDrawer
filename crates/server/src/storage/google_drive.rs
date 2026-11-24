use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures_util::TryStreamExt;
use serde::Deserialize;
use serde_json::json;
use tokio::sync::Mutex;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

#[derive(Debug, Clone)]
pub struct GoogleDriveConfig {
    pub client_id: String,
    pub client_secret: String,
    pub refresh_token: String,
    pub folder_id: String,
    pub api_base_url: Option<String>,
    pub token_url: Option<String>,
}

struct CachedToken {
    access_token: String,
    expires_at: Instant,
}

/// Native Google Drive API v3 storage provider (OAuth2 refresh token + Resumable Upload).
/// Zero external sidecars required.
pub struct GoogleDriveProvider {
    http: reqwest::Client,
    cfg: GoogleDriveConfig,
    token_cache: Arc<Mutex<Option<CachedToken>>>,
}

#[derive(Debug, Deserialize)]
struct OAuthTokenResp {
    access_token: String,
    #[serde(default = "default_expires")]
    expires_in: u64,
}

fn default_expires() -> u64 {
    3600
}

#[derive(Debug, Deserialize)]
struct DriveFileResp {
    id: String,
    #[serde(default)]
    size: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DriveAboutResp {
    user: Option<DriveAboutUser>,
    #[serde(rename = "storageQuota")]
    storage_quota: Option<DriveQuota>,
}

#[derive(Debug, Deserialize)]
struct DriveAboutUser {
    #[serde(rename = "emailAddress")]
    email_address: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DriveQuota {
    limit: Option<String>,
    usage: Option<String>,
}

impl GoogleDriveProvider {
    pub fn new(http: reqwest::Client, cfg: GoogleDriveConfig) -> Self {
        Self {
            http,
            cfg,
            token_cache: Arc::new(Mutex::new(None)),
        }
    }

    fn api_base(&self) -> String {
        self.cfg
            .api_base_url
            .as_deref()
            .unwrap_or("https://www.googleapis.com")
            .trim_end_matches('/')
            .to_string()
    }

    fn token_endpoint(&self) -> String {
        self.cfg
            .token_url
            .as_deref()
            .unwrap_or("https://oauth2.googleapis.com/token")
            .to_string()
    }

    async fn access_token(&self) -> anyhow::Result<String> {
        let mut guard = self.token_cache.lock().await;
        if let Some(cached) = guard.as_ref() {
            if cached.expires_at > Instant::now() + Duration::from_secs(60) {
                return Ok(cached.access_token.clone());
            }
        }

        let resp = self
            .http
            .post(self.token_endpoint())
            .form(&[
                ("client_id", self.cfg.client_id.as_str()),
                ("client_secret", self.cfg.client_secret.as_str()),
                ("refresh_token", self.cfg.refresh_token.as_str()),
                ("grant_type", "refresh_token"),
            ])
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Google OAuth2 token refresh failed ({status}): {text}");
        }

        let parsed: OAuthTokenResp = resp.json().await?;
        let ttl = parsed.expires_in.saturating_sub(60).max(60);
        *guard = Some(CachedToken {
            access_token: parsed.access_token.clone(),
            expires_at: Instant::now() + Duration::from_secs(ttl),
        });
        Ok(parsed.access_token)
    }
}

#[async_trait]
impl StorageProvider for GoogleDriveProvider {
    async fn put_stream(
        &self,
        remote_key: &str,
        content_length: Option<u64>,
        stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        let token = self.access_token().await?;
        let file_name = remote_key
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("file.bin");

        let folder = self.cfg.folder_id.trim();
        let metadata = if folder.is_empty() || folder == "root" {
            json!({ "name": file_name })
        } else {
            json!({ "name": file_name, "parents": [folder] })
        };

        // Step 1: Initiate Google Drive API v3 Resumable Upload Session
        let init_url = format!("{}/upload/drive/v3/files?uploadType=resumable", self.api_base());
        let mut init_req = self
            .http
            .post(&init_url)
            .bearer_auth(&token)
            .header("X-Upload-Content-Type", "application/octet-stream");
        if let Some(len) = content_length {
            init_req = init_req.header("X-Upload-Content-Length", len.to_string());
        }

        let init_resp = init_req.json(&metadata).send().await?;
        if !init_resp.status().is_success() {
            let status = init_resp.status();
            let text = init_resp.text().await.unwrap_or_default();
            anyhow::bail!("Google Drive resumable init failed ({status}): {text}");
        }

        let session_uri = init_resp
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| anyhow::anyhow!("Google Drive resumable init missing Location header"))?
            .to_string();

        // Step 2: Stream file body directly to Google Drive resumable session URI (zero local disk buffering)
        let counter = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter_clone = counter.clone();
        let counting_stream = stream.map_ok(move |chunk| {
            counter_clone.fetch_add(chunk.len() as u64, std::sync::atomic::Ordering::Relaxed);
            chunk
        });

        let mut put_req = self
            .http
            .put(&session_uri)
            .header("Content-Type", "application/octet-stream");
        if let Some(len) = content_length {
            put_req = put_req.header("Content-Length", len.to_string());
        }

        let upload_resp = put_req
            .body(reqwest::Body::wrap_stream(counting_stream))
            .send()
            .await?;

        if !upload_resp.status().is_success() {
            let status = upload_resp.status();
            let text = upload_resp.text().await.unwrap_or_default();
            anyhow::bail!("Google Drive upload stream failed ({status}): {text}");
        }

        let created: DriveFileResp = upload_resp.json().await?;
        let written = counter.load(std::sync::atomic::Ordering::Relaxed);
        let size = created
            .size
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(written);

        Ok(PutResult {
            bytes_written: size,
            stored_key: created.id,
        })
    }

    async fn resolve_download(&self, stored_key: &str) -> anyhow::Result<DownloadResolution> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/drive/v3/files/{}?alt=media",
            self.api_base(),
            urlencoding::encode(stored_key)
        );

        let resp = self.http.get(&url).bearer_auth(&token).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Google Drive download failed ({status}): {text}");
        }

        let content_length = resp.content_length();
        let content_type = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let stream = resp.bytes_stream().map_err(anyhow::Error::from);

        Ok(DownloadResolution::Stream {
            stream: Box::pin(stream),
            content_length,
            content_type,
        })
    }

    async fn delete(&self, stored_key: &str) -> anyhow::Result<()> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/drive/v3/files/{}",
            self.api_base(),
            urlencoding::encode(stored_key)
        );
        let resp = self.http.delete(&url).bearer_auth(&token).send().await?;
        if !resp.status().is_success() && resp.status().as_u16() != 404 {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Google Drive delete failed ({status}): {text}");
        }
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        let token = self.access_token().await?;
        let url = format!(
            "{}/drive/v3/about?fields=user(emailAddress),storageQuota(limit,usage)",
            self.api_base()
        );
        let resp = self.http.get(&url).bearer_auth(&token).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Google Drive about check failed ({status}): {text}");
        }
        let about: DriveAboutResp = resp.json().await?;
        let email = about
            .user
            .and_then(|u| u.email_address)
            .unwrap_or_else(|| "Google Drive".to_string());
        if let Some(q) = about.storage_quota {
            let used_gb = q
                .usage
                .and_then(|s| s.parse::<f64>().ok())
                .map(|b| b / 1e9)
                .unwrap_or(0.0);
            let limit_gb = q
                .limit
                .and_then(|s| s.parse::<f64>().ok())
                .map(|b| b / 1e9)
                .unwrap_or(0.0);
            if limit_gb > 0.0 {
                return Ok(format!(
                    "Google Drive ({email}) · 已用 {used_gb:.2} GB / {limit_gb:.1} GB"
                ));
            }
        }
        Ok(format!("Google Drive ({email}) 已连接"))
    }
}
