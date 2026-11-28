use std::path::{Component, PathBuf};
use std::sync::{Arc, OnceLock};

use async_trait::async_trait;
use dashmap::DashMap;
use futures_util::{StreamExt, TryStreamExt};
use tokio::io::AsyncWriteExt;
use tokio_util::io::ReaderStream;

use super::{ByteStream, DownloadResolution, PutResult, StorageProvider};

struct QuotaSlot {
    /// Serializes quota check/reserve and final commit (`rename` + release)
    /// for one directory so concurrent uploads never race past the quota or
    /// fail each other after finishing.
    gate: tokio::sync::Mutex<()>,
    /// Bytes reserved by in-flight `.uploading` streams for this directory.
    inflight: std::sync::Mutex<u64>,
}

/// How much an upload without a declared size reserves at a time (never more
/// than the quota has left), so the directory is rescanned once per step.
const RESERVATION_STEP: u64 = 8 * 1024 * 1024;

#[cfg(test)]
thread_local! {
    /// Directory scans on this test thread (tokio tests run on their own thread).
    static USAGE_SCANS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

static QUOTA_SLOTS: OnceLock<DashMap<PathBuf, Arc<QuotaSlot>>> = OnceLock::new();

fn quota_slot_for(dir: &std::path::Path) -> Arc<QuotaSlot> {
    let map = QUOTA_SLOTS.get_or_init(DashMap::new);
    if map.len() > 1024 {
        map.retain(|_, slot| {
            Arc::strong_count(slot) > 1
                || *slot.inflight.lock().unwrap_or_else(|e| e.into_inner()) > 0
        });
    }
    map.entry(dir.to_path_buf())
        .or_insert_with(|| {
            Arc::new(QuotaSlot {
                gate: tokio::sync::Mutex::new(()),
                inflight: std::sync::Mutex::new(0),
            })
        })
        .clone()
}

struct QuotaReservation {
    slot: Arc<QuotaSlot>,
    reserved: u64,
}

impl QuotaReservation {
    fn add(&mut self, delta: u64) {
        if delta == 0 {
            return;
        }
        let mut inflight = self.slot.inflight.lock().unwrap_or_else(|e| e.into_inner());
        *inflight = inflight.saturating_add(delta);
        self.reserved = self.reserved.saturating_add(delta);
    }

    fn release(&mut self) {
        if self.reserved == 0 {
            return;
        }
        let mut inflight = self.slot.inflight.lock().unwrap_or_else(|e| e.into_inner());
        *inflight = inflight.saturating_sub(self.reserved);
        self.reserved = 0;
    }
}

impl Drop for QuotaReservation {
    fn drop(&mut self) {
        self.release();
    }
}

/// Removes an unfinished `.uploading` file on error, panic, or client cancel.
struct TempFileGuard(Option<PathBuf>);

impl TempFileGuard {
    fn new(path: PathBuf) -> Self {
        Self(Some(path))
    }

    fn disarm(&mut self) {
        self.0 = None;
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[derive(Debug)]
pub(crate) struct LocalUploadTooLarge(u64);

impl std::fmt::Display for LocalUploadTooLarge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let limit = self.0;
        f.write_str(&tf!(
            "文件超过服务器本地盘的单文件上传上限（{limit} 字节）",
            "The file exceeds the server's local storage upload limit ({limit} bytes)"
        ))
    }
}

impl std::error::Error for LocalUploadTooLarge {}

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

    /// Directory whose contents count against the quota. A per-user root holds
    /// only that user's data; the legacy shared root holds every account, so
    /// only the owner's `<root>/<user id>` subtree is counted there.
    fn usage_dir(&self) -> PathBuf {
        match &self.key_prefix {
            Some(prefix) if self.root_dir.file_name().is_none_or(|name| name != prefix.as_str()) => {
                self.root_dir.join(prefix)
            }
            _ => self.root_dir.clone(),
        }
    }

    /// Bytes of committed files stored under [`Self::usage_dir`], excluding
    /// in-flight `.uploading` temp files tracked via `QuotaSlot::inflight`.
    async fn used_bytes(&self) -> u64 {
        fn walk(dir: &std::path::Path) -> u64 {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return 0;
            };
            let mut total = 0u64;
            for entry in entries.flatten() {
                let Ok(kind) = entry.file_type() else { continue };
                if kind.is_dir() {
                    total += walk(&entry.path());
                } else if kind.is_file() {
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("uploading") {
                        continue;
                    }
                    if let Ok(meta) = entry.metadata() {
                        total += meta.len();
                    }
                }
            }
            total
        }
        #[cfg(test)]
        USAGE_SCANS.with(|n| n.set(n.get() + 1));
        let dir = self.usage_dir();
        tokio::task::spawn_blocking(move || walk(&dir))
            .await
            .unwrap_or(0)
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
        let slot = quota_slot_for(&self.usage_dir());
        let mut reservation = QuotaReservation {
            slot: slot.clone(),
            reserved: 0,
        };
        if let Some(limit) = self.max_bytes {
            let _gate = slot.gate.lock().await;
            let used = self.used_bytes().await;
            let inflight = *slot.inflight.lock().unwrap_or_else(|e| e.into_inner());
            let expected = content_length.unwrap_or(0);
            let projected = used.saturating_add(inflight).saturating_add(expected);
            if projected > limit {
                anyhow::bail!(
                    "local storage quota exceeded ({used} + {inflight} + {expected} > {limit})"
                );
            }
            reservation.add(expected);
        }

        let target = self.safe_path(remote_key)?;
        if let Some(parent) = target.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let tmp = target.with_extension("uploading");
        let mut tmp_guard = TempFileGuard::new(tmp.clone());
        let mut file = tokio::fs::File::create(&tmp).await?;
        let mut total = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            total += chunk.len() as u64;
            LocalUploadTooLarge::check(self.max_file_bytes, total)?;
            if let Some(limit) = self.max_bytes
                && total > reservation.reserved
            {
                // Grow the reservation in steps: a body without a declared
                // length would otherwise rescan the directory for every chunk.
                let needed = total - reservation.reserved;
                let _gate = slot.gate.lock().await;
                let used = self.used_bytes().await;
                let inflight = *slot.inflight.lock().unwrap_or_else(|e| e.into_inner());
                let room = limit.saturating_sub(used.saturating_add(inflight));
                if needed > room {
                    anyhow::bail!("upload exceeded local storage quota ({limit} bytes)");
                }
                reservation.add(needed.max(RESERVATION_STEP).min(room));
            }
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        drop(file);

        // Commit rename and release the inflight reservation atomically under
        // the directory gate so concurrent quota checks never double-count or miss it.
        if self.max_bytes.is_some() {
            let _gate = slot.gate.lock().await;
            tokio::fs::rename(&tmp, &target).await?;
            tmp_guard.disarm();
            reservation.release();
        } else {
            tokio::fs::rename(&tmp, &target).await?;
            tmp_guard.disarm();
        }
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
        let used = self.used_bytes().await;
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

    fn body(bytes: &'static [u8]) -> ByteStream {
        Box::pin(futures_util::stream::iter([Ok(bytes::Bytes::from_static(bytes))]))
    }

    #[tokio::test]
    async fn chunked_uploads_count_existing_usage() {
        let dir = tempfile::TempDir::new().unwrap();
        let provider = LocalProvider::new(dir.path(), Some(10))
            .unwrap()
            .restrict_keys_to("alice");
        // No declared length, as with a chunked request body.
        provider.put_stream("alice/a", None, body(b"123456")).await.unwrap();
        assert!(provider.put_stream("alice/b", None, body(b"123456")).await.is_err());
        assert!(!dir.path().join("alice/b").exists());
        assert!(!dir.path().join("alice/b.uploading").exists());
        provider.put_stream("alice/c", None, body(b"1234")).await.unwrap();
    }

    #[tokio::test]
    async fn shared_root_counts_only_the_owner() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::create_dir_all(dir.path().join("bob")).unwrap();
        std::fs::write(dir.path().join("bob/big"), [0u8; 64]).unwrap();
        let provider = LocalProvider::new(dir.path(), Some(10))
            .unwrap()
            .restrict_keys_to("alice");
        provider.put_stream("alice/a", Some(8), body(b"12345678")).await.unwrap();
    }

    #[tokio::test]
    async fn concurrent_uploads_enforce_quota_and_aborts_clean_temp_files() {
        let dir = tempfile::TempDir::new().unwrap();
        let provider = Arc::new(
            LocalProvider::new(dir.path(), Some(10))
                .unwrap()
                .restrict_keys_to("alice"),
        );

        // Hold an upload open mid-stream, then cancel (drop) its future.
        let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, anyhow::Error>>(2);
        let stream: ByteStream = Box::pin(futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        }));
        let p_abort = provider.clone();
        let handle = tokio::spawn(async move { p_abort.put_stream("alice/aborted", Some(6), stream).await });
        tx.send(Ok(bytes::Bytes::from_static(b"123"))).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(30)).await;

        // While the 6-byte reservation is active, a concurrent 6-byte upload
        // must be rejected instead of writing past the 10-byte quota.
        assert!(provider.put_stream("alice/other", Some(6), body(b"abcdef")).await.is_err());

        // Aborting the first upload cleans up `.uploading` and releases its reservation.
        handle.abort();
        let _ = handle.await;
        assert!(!dir.path().join("alice/aborted.uploading").exists());
        provider.put_stream("alice/final", Some(10), body(b"0123456789")).await.unwrap();
    }

    #[tokio::test]
    async fn chunked_upload_reserves_in_steps_not_per_chunk() {
        let dir = tempfile::TempDir::new().unwrap();
        let provider = LocalProvider::new(dir.path(), Some(64 * 1024 * 1024))
            .unwrap()
            .restrict_keys_to("alice");
        // 1000 chunks of 1 KiB with no declared length.
        let chunks = (0..1000).map(|_| Ok(bytes::Bytes::from(vec![7u8; 1024])));
        let body: ByteStream = Box::pin(futures_util::stream::iter(chunks));
        USAGE_SCANS.with(|n| n.set(0));
        let put = provider.put_stream("alice/chunked", None, body).await.unwrap();
        assert_eq!(put.bytes_written, 1000 * 1024);
        // One scan up front and one for the first step, not one per chunk.
        assert!(USAGE_SCANS.with(|n| n.get()) <= 2);
        let slot = quota_slot_for(&provider.usage_dir());
        assert_eq!(*slot.inflight.lock().unwrap(), 0, "the reservation is released on commit");
    }
}
