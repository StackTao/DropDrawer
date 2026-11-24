use std::path::{Component, PathBuf};

use async_trait::async_trait;
use futures_util::{StreamExt, TryStreamExt};
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

pub struct LocalProvider {
    root_dir: PathBuf,
    max_bytes: Option<u64>,
}

impl LocalProvider {
    pub fn new(root_dir: impl Into<PathBuf>, max_bytes: Option<u64>) -> anyhow::Result<Self> {
        let root_dir = root_dir.into();
        std::fs::create_dir_all(&root_dir)?;
        Ok(Self {
            root_dir,
            max_bytes,
        })
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
        let mut total = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            total += chunk.len() as u64;
            if let Some(limit) = self.max_bytes {
                if total > limit {
                    drop(file);
                    let _ = tokio::fs::remove_file(&tmp).await;
                    anyhow::bail!("upload exceeded local storage quota ({limit} bytes)");
                }
            }
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        drop(file);
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

    async fn delete(&self, remote_key: &str) -> anyhow::Result<()> {
        let target = self.safe_path(remote_key)?;
        if target.exists() {
            tokio::fs::remove_file(target).await?;
        }
        Ok(())
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
