use std::path::{Component, PathBuf};

use async_trait::async_trait;
use futures_util::{StreamExt, TryStreamExt};
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

#[derive(Debug, thiserror::Error)]
#[error("文件超过服务器本地盘的单文件上传上限（{0} 字节）")]
pub(crate) struct LocalUploadTooLarge(u64);

impl LocalUploadTooLarge {
    pub(crate) fn check(max_file_bytes: Option<u64>, size: u64) -> Result<(), Self> {
        if let Some(limit) = max_file_bytes.filter(|&limit| size > limit) {
            return Err(Self(limit));
        }
        Ok(())
    }
}

pub struct LocalProvider {
    root_dir: PathBuf,
    max_bytes: Option<u64>,
    max_file_bytes: Option<u64>,
    /// When set, every storage key must live under this first path component
    /// (the owning user's id), so one account can never address another's blobs.
    key_prefix: Option<String>,
}

impl LocalProvider {
    pub fn new(root_dir: impl Into<PathBuf>, max_bytes: Option<u64>) -> anyhow::Result<Self> {
        let root_dir = root_dir.into();
        std::fs::create_dir_all(&root_dir)?;
        Ok(Self {
            root_dir,
            max_bytes,
            max_file_bytes: None,
            key_prefix: None,
        })
    }

    pub(crate) fn with_max_file_bytes(mut self, max_file_bytes: Option<u64>) -> Self {
        self.max_file_bytes = max_file_bytes;
        self
    }

    /// Restricts all keys handled by this provider to `<prefix>/...`.
    pub fn restrict_keys_to(mut self, prefix: impl Into<String>) -> Self {
        self.key_prefix = Some(prefix.into());
        self
    }

    fn safe_path(&self, remote_key: &str) -> anyhow::Result<PathBuf> {
        let mut rel = PathBuf::new();
        for comp in PathBuf::from(remote_key).components() {
            match comp {
                Component::Normal(p) => rel.push(p),
                Component::CurDir => {}
                _ => anyhow::bail!("invalid storage key path traversal: {remote_key}"),
            }
        }
        if let Some(prefix) = &self.key_prefix {
            let owned = rel
                .components()
                .next()
                .is_some_and(|c| c.as_os_str() == prefix.as_str());
            if !owned || rel.components().count() < 2 {
                anyhow::bail!("storage key is outside the owner's namespace: {remote_key}");
            }
        }
        if rel.as_os_str().is_empty() {
            anyhow::bail!("empty storage key");
        }
        Ok(self.root_dir.join(rel))
    }

    fn dir_size(&self) -> u64 {
        fn walk(dir: &PathBuf) -> u64 {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return 0;
            };
            let mut total = 0u64;
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    total += walk(&path);
                } else if let Ok(meta) = entry.metadata() {
                    total += meta.len();
                }
            }
            total
        }
        walk(&self.root_dir)
    }
}

#[async_trait]
impl StorageProvider for LocalProvider {
    async fn put_stream(
        &self,
        remote_key: &str,
        content_length: Option<u64>,
        mut stream: ByteStream,
    ) -> anyhow::Result<PutResult> {
        if let Some(size) = content_length {
            LocalUploadTooLarge::check(self.max_file_bytes, size)?;
        }
        if let (Some(limit), Some(expected)) = (self.max_bytes, content_length) {
            let used = self.dir_size();
            if used.saturating_add(expected) > limit {
                anyhow::bail!("local storage quota exceeded ({used} + {expected} > {limit})");
            }
        }

        let target = self.safe_path(remote_key)?;
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let tmp = target.with_extension("uploading");
        let mut file = tokio::fs::File::create(&tmp).await?;
        let result = async {
            let mut total = 0u64;
            while let Some(chunk) = stream.next().await {
                let chunk = chunk?;
                total += chunk.len() as u64;
                LocalUploadTooLarge::check(self.max_file_bytes, total)?;
                if let Some(limit) = self.max_bytes.filter(|&limit| total > limit) {
                    anyhow::bail!("upload exceeded local storage quota ({limit} bytes)");
                }
                file.write_all(&chunk).await?;
            }
            file.flush().await?;
            Ok(total)
        }
        .await;
        drop(file);

        let total = match result {
            Ok(total) => total,
            Err(err) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                return Err(err);
            }
        };
        tokio::fs::rename(&tmp, &target).await?;
        Ok(PutResult {
            bytes_written: total,
            stored_key: remote_key.to_string(),
        })
    }

    async fn resolve_download(&self, remote_key: &str) -> anyhow::Result<DownloadResolution> {
        let target = self.safe_path(remote_key)?;
        let file = tokio::fs::File::open(&target).await?;
        let len = file.metadata().await?.len();
        let stream = ReaderStream::new(file).map_err(anyhow::Error::from);
        Ok(DownloadResolution::Stream {
            stream: Box::pin(stream),
            content_length: Some(len),
            content_type: Some("application/octet-stream".to_string()),
        })
    }

    async fn object_exists(&self, remote_key: &str) -> anyhow::Result<bool> {
        let target = self.safe_path(remote_key)?;
        Ok(tokio::fs::try_exists(target).await?)
    }

    async fn delete(&self, remote_key: &str) -> anyhow::Result<()> {
        let target = self.safe_path(remote_key)?;
        match tokio::fs::remove_file(target).await {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err.into()),
        }
    }

    async fn health_check(&self) -> anyhow::Result<String> {
        tokio::fs::create_dir_all(&self.root_dir).await?;
        let used = self.dir_size();
        Ok(format!(
            "Local storage ready at {} (used: {} bytes)",
            self.root_dir.display(),
            used
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_must_stay_inside_root_and_owner_namespace() {
        let dir = tempfile::TempDir::new().unwrap();
        let provider = LocalProvider::new(dir.path(), None)
            .unwrap()
            .restrict_keys_to("alice");
        assert_eq!(
            provider.safe_path("alice/item_a.txt").unwrap(),
            dir.path().join("alice").join("item_a.txt")
        );
        for bad in [
            "bob/item_b.txt",
            "alice",
            "",
            "../alice/x",
            "alice/../bob/x",
            "/etc/passwd",
            "etc/passwd",
        ] {
            assert!(provider.safe_path(bad).is_err(), "{bad} must be rejected");
        }
    }
}
