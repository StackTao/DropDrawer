use async_trait::async_trait;
use futures_util::TryStreamExt;
use reqwest::Method;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

pub struct WebDavProvider {
    http: reqwest::Client,
    base_url: String,
    username: String,
    password: String,
}

impl WebDavProvider {
    pub fn new(
        http: reqwest::Client,
        base_url: String,
        username: String,
        password: String,
    ) -> Self {
        Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            username,
            password,
        }
    }

    fn object_url(&self, remote_key: &str) -> String {
        let encoded = remote_key
            .trim_start_matches('/')
            .split('/')
            .map(|seg| urlencoding::encode(seg).into_owned())
            .collect::<Vec<_>>()
            .join("/");
        format!("{}/{}", self.base_url, encoded)
    }
}

#[async_trait]
impl StorageProvider for WebDavProvider {
    async fn put_stream(
        &self,
        remote_key: &str,
        content_length: Option<u64>,
        stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        let url = self.object_url(remote_key);
        let counter = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter_clone = counter.clone();
        let counting_stream = stream.map_ok(move |chunk| {
            counter_clone.fetch_add(chunk.len() as u64, std::sync::atomic::Ordering::Relaxed);
            chunk
        });

        let mut req = self
            .http
            .put(&url)
            .basic_auth(&self.username, Some(&self.password))
            .header("Content-Type", "application/octet-stream");

        if let Some(len) = content_length {
            req = req.header("Content-Length", len.to_string());
        }

        let resp = req
            .body(reqwest::Body::wrap_stream(counting_stream))
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("WebDAV PUT failed ({status}): {text}");
        }

        Ok(PutResult {
            bytes_written: counter.load(std::sync::atomic::Ordering::Relaxed),
            stored_key: remote_key.to_string(),
        })
    }

    async fn resolve_download(&self, remote_key: &str) -> anyhow::Result<DownloadResolution> {
        let url = self.object_url(remote_key);
        let resp = self
            .http
            .get(&url)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await?
            .error_for_status()?;

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

    async fn object_exists(&self, remote_key: &str) -> anyhow::Result<bool> {
        let url = self.object_url(remote_key);
        let resp = self
            .http
            .head(&url)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn delete(&self, remote_key: &str) -> anyhow::Result<()> {
        let url = self.object_url(remote_key);
        let resp = self
            .http
            .delete(&url)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await?;

        if !resp.status().is_success() && resp.status().as_u16() != 404 {
            anyhow::bail!("WebDAV DELETE failed: {}", resp.status());
        }
        Ok(())
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        let method = Method::from_bytes(b"PROPFIND")?;
        let resp = self
            .http
            .request(method, format!("{}/", self.base_url))
            .basic_auth(&self.username, Some(&self.password))
            .header("Depth", "0")
            .send()
            .await?;

        if !resp.status().is_success() && resp.status().as_u16() != 207 {
            anyhow::bail!("WebDAV PROPFIND failed: {}", resp.status());
        }
        Ok(format!("WebDAV ready at {}", self.base_url))
    }
}
