pub mod ffi;
mod transfers;

use transfers::{CANCEL_CODE, Cancelled, PROBE_CODE, Transfer, Transfers, while_connected};

mod relay_probe;

use std::ffi::OsString;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use dashmap::{DashMap, DashSet};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayUrl, SecretKey, TransportAddr,
    endpoint::{Connection, ConnectionError, RelayMode, StoppedError, VarInt},
};
use protocol::{P2pPathKind, P2pTransferProgress};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::{Notify, OnceCell, Semaphore};
use uuid::Uuid;

pub const DROPDRAWER_ALPN: &[u8] = b"/dropdrawer/file/1";
const CHUNK_SIZE: usize = 256 * 1024; // 256 KiB QUIC streaming chunks
/// How long a source waits for the control server's token push to arrive when a
/// pull request races ahead of it.
const TOKEN_ARRIVAL_GRACE: Duration = Duration::from_secs(5);
/// Files hashed concurrently in the background (startup re-registers every seeded file).
const MAX_CONCURRENT_HASHES: usize = 2;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct P2pConfig {
    /// Directory where the persistent device Ed25519 key is stored.
    pub data_dir: String,
    /// Optional custom relay URL (defaults to iroh default relay infrastructure).
    #[serde(default)]
    pub custom_relay_url: Option<String>,
    /// If true, disable relay servers (useful for pure LAN / offline testing).
    #[serde(default)]
    pub disable_relay: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalNodeInfo {
    pub node_id: String,
    pub relay_url: Option<String>,
    pub direct_addrs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredFileInfo {
    pub item_id: String,
    pub path: String,
    pub size: u64,
    pub blake3_hash: String,
}

/// `(size, blake3 hex)` of a shared file, computed once in the background.
type FileDigest = (u64, String);

#[derive(Debug, Clone)]
struct SharedFileEntry {
    path: PathBuf,
    digest: Arc<OnceCell<FileDigest>>,
}

#[derive(Debug, Clone)]
struct AuthorizedToken {
    item_id: String,
    expires_at: DateTime<Utc>,
    /// When known, only this peer may redeem the token.
    requester_node_id: Option<String>,
}

/// State shared between the node and its incoming-connection handlers.
struct SourceState {
    shared_files: DashMap<String, SharedFileEntry>,
    /// Map of `token -> AuthorizedToken`. Each token is redeemed at most once.
    authorized_tokens: DashMap<String, AuthorizedToken>,
    token_added: Notify,
    hash_permits: Semaphore,
    require_auth_token: bool,
}

impl SourceState {
    async fn digest(&self, entry: &SharedFileEntry) -> anyhow::Result<FileDigest> {
        entry
            .digest
            .get_or_try_init(|| async {
                let _permit = self.hash_permits.acquire().await?;
                compute_file_blake3(&entry.path).await
            })
            .await
            .cloned()
    }

    /// Redeems `token` for `item_id`, waiting briefly in case the control server's
    /// authorization push has not reached this device yet.
    async fn redeem_token(&self, token: &str, item_id: &str, remote_node_id: &str) -> bool {
        let deadline = tokio::time::Instant::now() + TOKEN_ARRIVAL_GRACE;
        loop {
            let added = self.token_added.notified();
            tokio::pin!(added);
            added.as_mut().enable();
            let now = Utc::now();
            if self
                .authorized_tokens
                .remove_if(token, |_, t| {
                    t.item_id == item_id
                        && t.expires_at > now
                        && t.requester_node_id.as_deref().is_none_or(|r| r == remote_node_id)
                })
                .is_some()
            {
                return true;
            }
            if self.authorized_tokens.contains_key(token) {
                // Known but expired, for another item, or for another peer.
                return false;
            }
            if tokio::time::timeout_at(deadline, added).await.is_err() {
                return false;
            }
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct LegacyPrefix {
    size: u64,
    hash: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct PullRequestHeader {
    item_id: String,
    token: String,
    offset: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    legacy_prefix: Option<LegacyPrefix>,
    #[serde(default)]
    wants_receipt: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct PullResponseHeader {
    #[serde(default)]
    resumed_legacy: bool,
    #[serde(default)]
    supports_receipt: bool,
    ok: bool,
    error: Option<String>,
    size: u64,
    blake3_hash: String,
}

#[derive(Deserialize)]
struct DownloadFileReq {
    item_id: String,
    remote_node_id: String,
    #[serde(default)]
    remote_relay_url: Option<String>,
    #[serde(default)]
    remote_direct_addrs: Vec<String>,
    transfer_token: String,
    dest_path: PathBuf,
    #[serde(default)]
    skip_legacy_resume: bool,
}

pub struct P2pNode {
    endpoint: Endpoint,
    partial_paths: DashSet<PathBuf>,
    source: Arc<SourceState>,
    transfers: Arc<Transfers>,
    accept_task: tokio::task::JoinHandle<()>,
    relay_probe: Arc<relay_probe::RelayProbe>,
}

impl P2pNode {
    pub async fn start(config: P2pConfig, require_auth_token: bool) -> anyhow::Result<Arc<Self>> {
        let data_dir = PathBuf::from(&config.data_dir);
        tokio::fs::create_dir_all(&data_dir).await?;
        let secret_key = load_or_create_secret_key(&data_dir.join("iroh_secret.key")).await?;

        let relay_mode = if config.disable_relay {
            RelayMode::Disabled
        } else if let Some(url_str) = config.custom_relay_url.filter(|s| !s.trim().is_empty()) {
            let url: RelayUrl = url_str.parse()?;
            RelayMode::Custom(url.into())
        } else {
            RelayMode::Default
        };

        let endpoint = if config.disable_relay {
            Endpoint::builder(iroh::endpoint::presets::Minimal)
                .secret_key(secret_key)
                .alpns(vec![DROPDRAWER_ALPN.to_vec()])
                .relay_mode(RelayMode::Disabled)
                .bind()
                .await?
        } else {
            Endpoint::builder(iroh::endpoint::presets::N0)
                .secret_key(secret_key)
                .alpns(vec![DROPDRAWER_ALPN.to_vec()])
                .relay_mode(relay_mode)
                .bind()
                .await?
        };

        let source = Arc::new(SourceState {
            shared_files: DashMap::new(),
            authorized_tokens: DashMap::new(),
            token_added: Notify::new(),
            hash_permits: Semaphore::new(MAX_CONCURRENT_HASHES),
            require_auth_token,
        });
        let transfers = Arc::new(Transfers::default());
        let incoming_transfers = transfers.clone();

        let ep_clone = endpoint.clone();
        let source_clone = source.clone();
        let relay_probe = Arc::new(relay_probe::RelayProbe::new(endpoint.clone()));
        let accept_task = tokio::spawn(async move {
            while let Some(incoming) = ep_clone.accept().await {
                let source = source_clone.clone();
                let transfers = incoming_transfers.clone();
                tokio::spawn(async move {
                    match incoming.await {
                        Ok(conn) => {
                            if let Err(err) =
                                handle_incoming_connection(conn, source, transfers).await
                            {
                                tracing::warn!("incoming P2P connection error: {err}");
                            }
                        }
                        Err(err) => {
                            tracing::warn!("failed accepting P2P connection: {err}");
                        }
                    }
                });
            }
        });

        Ok(Arc::new(Self {
            endpoint,
            partial_paths: DashSet::new(),
            source,
            transfers,
            accept_task,
            relay_probe,
        }))
    }

    /// Returns this node's EndpointId, active relay URL, and direct socket addresses.
    pub fn node_info(&self) -> LocalNodeInfo {
        let addr = self.endpoint.addr();
        let relay_url = addr.relay_urls().next().map(|u| u.to_string());
        let direct_addrs = addr.ip_addrs().map(|a| a.to_string()).collect();
        LocalNodeInfo {
            node_id: self.endpoint.id().to_string(),
            relay_url,
            direct_addrs,
        }
    }

    /// Registers a local file by reference (zero disk duplication) and computes its BLAKE3 hash.
    pub async fn register_file(
        &self,
        item_id: String,
        path: impl AsRef<Path>,
    ) -> anyhow::Result<RegisteredFileInfo> {
        let mut info = self.register_file_deferred(item_id, path)?;
        let (size, blake3_hash) = self.ensure_hashed(&info.item_id).await?;
        info.size = size;
        info.blake3_hash = blake3_hash;
        Ok(info)
    }

    /// Registers a local file without reading it. The BLAKE3 hash is computed later by
    /// [`Self::ensure_hashed`] or by the first incoming pull; `blake3_hash` is empty here.
    pub fn register_file_deferred(
        &self,
        item_id: String,
        path: impl AsRef<Path>,
    ) -> anyhow::Result<RegisteredFileInfo> {
        let path = path.as_ref().to_path_buf();
        let meta = std::fs::metadata(&path)?;
        anyhow::ensure!(meta.is_file(), "not a regular file: {}", path.display());
        self.source.shared_files.insert(
            item_id.clone(),
            SharedFileEntry {
                path: path.clone(),
                digest: Arc::new(OnceCell::new()),
            },
        );
        Ok(RegisteredFileInfo {
            item_id,
            path: path.to_string_lossy().to_string(),
            size: meta.len(),
            blake3_hash: String::new(),
        })
    }

    /// Computes (once) and returns the registered file's size and BLAKE3 hash.
    pub async fn ensure_hashed(&self, item_id: &str) -> anyhow::Result<(u64, String)> {
        let entry = self
            .source
            .shared_files
            .get(item_id)
            .map(|e| e.clone())
            .ok_or_else(|| anyhow::anyhow!("file not registered: {item_id}"))?;
        self.source.digest(&entry).await
    }

    pub fn unregister_file(&self, item_id: &str) {
        self.source.shared_files.remove(item_id);
    }

    /// Authorizes a single-use, short-lived pull token pushed by the control server.
    pub fn authorize_token(&self, item_id: String, token: String, expires_at: DateTime<Utc>) {
        self.authorize_token_for(item_id, token, expires_at, None);
    }

    /// Like [`Self::authorize_token`], optionally restricted to one requesting peer.
    pub fn authorize_token_for(
        &self,
        item_id: String,
        token: String,
        expires_at: DateTime<Utc>,
        requester_node_id: Option<String>,
    ) {
        let now = Utc::now();
        self.source
            .authorized_tokens
            .retain(|_, t| t.expires_at > now);
        self.source.authorized_tokens.insert(
            token,
            AuthorizedToken {
                item_id,
                expires_at,
                requester_node_id: requester_node_id.filter(|id| !id.is_empty()),
            },
        );
        self.source.token_added.notify_waiters();
    }

    pub fn drain_events(&self) -> Vec<P2pTransferProgress> {
        self.transfers.drain()
    }

    /// Pulls a file from a remote peer directly via QUIC (with automatic NAT hole-punching & relay fallback).
    /// Supports resuming from an existing `.part` file and verifies the final BLAKE3 hash.
    pub async fn download_file(
        self: &Arc<Self>,
        item_id: String,
        remote_node_id: String,
        remote_relay_url: Option<String>,
        remote_direct_addrs: Vec<String>,
        transfer_token: String,
        dest_path: PathBuf,
    ) -> anyhow::Result<P2pTransferProgress> {
        let transfer = self.transfers.begin(item_id.clone(), None);
        self.run_download(
            transfer,
            DownloadFileReq {
                item_id,
                remote_node_id,
                remote_relay_url,
                remote_direct_addrs,
                transfer_token,
                dest_path,
                skip_legacy_resume: false,
            },
        )
        .await
    }

    async fn run_download(
        &self,
        mut transfer: Transfer,
        req: DownloadFileReq,
    ) -> anyhow::Result<P2pTransferProgress> {
        let result = self.receive_file(&mut transfer, req).await;
        transfer.finish(&result);
        result.map(|()| transfer.progress.clone())
    }

    async fn receive_file(
        &self,
        transfer: &mut Transfer,
        req: DownloadFileReq,
    ) -> anyhow::Result<()> {
        let endpoint_id: EndpointId = req.remote_node_id.parse()?;
        let dest_path = req.dest_path;
        let mut transport_addrs = Vec::new();
        if let Some(r) = req.remote_relay_url.filter(|s| !s.is_empty()) {
            if let Ok(relay_url) = r.parse::<RelayUrl>() {
                transport_addrs.push(TransportAddr::Relay(relay_url));
            }
        }
        for s in &req.remote_direct_addrs {
            if let Ok(sock) = s.parse::<SocketAddr>() {
                transport_addrs.push(TransportAddr::Ip(sock));
            }
        }

        let remote_addr = EndpointAddr::from_parts(endpoint_id, transport_addrs);
        let conn = tokio::select! {
            biased;
            _ = &mut transfer.cancel => return Err(Cancelled.into()),
            conn = self.endpoint.connect(remote_addr.clone(), DROPDRAWER_ALPN) => conn?,
        };

        let progress = &mut transfer.progress;
        progress.path_kind = detect_path_kind(&conn);
        self.relay_probe.schedule(&conn, Some(remote_addr));
        let part_path = part_path_for(&dest_path);
        let owner_path = part_owner_path_for(&part_path);
        let _destination = PartialLease::acquire(&self.partial_paths, &part_path)
            .ok_or_else(|| anyhow::anyhow!("download destination is already in use"))?;
        let legacy = dest_path.with_extension("dropdrawer.part");
        let mut partial_file = None;
        let receive = async {
            let (mut send, mut recv) = conn.open_bi().await?;

            // Check partial file for resumable transfer
            if let Some(parent) = dest_path.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            let existing = tokio::fs::metadata(&part_path).await;
            let mut existing_offset = match existing {
                Ok(meta) => meta.len(),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0,
                Err(e) => return Err(e.into()),
            };
            // Another item saved under the same file name may have left this partial.
            // Resuming it would append this item's bytes to that item's prefix.
            if existing_offset > 0 && !partial_belongs_to(&owner_path, &progress.item_id).await {
                tokio::fs::remove_file(&part_path).await?;
                existing_offset = 0;
            }
            tokio::fs::write(&owner_path, progress.item_id.as_bytes()).await?;
            let legacy_lease = if !req.skip_legacy_resume
                && existing_offset == 0
                && legacy != part_path
                && legacy.is_file()
            {
                PartialLease::acquire(&self.partial_paths, &legacy)
            } else {
                None
            };
            let legacy_prefix = if legacy_lease.is_some()
                && tokio::fs::symlink_metadata(&legacy)
                    .await
                    .is_ok_and(|m| m.is_file())
            {
                let (size, hash) = compute_file_blake3(&legacy).await?;
                Some(LegacyPrefix { size, hash })
            } else {
                None
            };
            // Release the old name before connecting if no candidate survived inspection.
            let legacy_lease = legacy_lease.filter(|_| legacy_prefix.is_some());
            let req_header = PullRequestHeader {
                item_id: progress.item_id.clone(),
                token: req.transfer_token,
                offset: existing_offset,
                wants_receipt: true,
                legacy_prefix,
            };
            write_frame(&mut send, &serde_json::to_vec(&req_header)?).await?;
            send.finish()?;

            let resp_bytes = read_frame(&mut recv).await?;
            let resp_header: PullResponseHeader = serde_json::from_slice(&resp_bytes)?;
            if !resp_header.ok {
                anyhow::bail!(
                    "remote peer rejected P2P pull: {}",
                    resp_header.error.unwrap_or_else(|| "unknown error".into())
                );
            }

            if resp_header.resumed_legacy {
                let prefix = req_header
                    .legacy_prefix
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("unexpected legacy resume offset"))?;
                // Both endpoints verified the old prefix against the requested source.
                // The leases keep another local transfer from moving either path.
                std::fs::rename(&legacy, &part_path)?;
                existing_offset = prefix.size;
            }
            drop(legacy_lease);
            let total_bytes = resp_header.size;
            let mut offset = if existing_offset <= total_bytes {
                existing_offset
            } else {
                0
            };

            let file = partial_file.insert(if offset > 0 {
                let mut f = tokio::fs::OpenOptions::new()
                    .write(true)
                    .open(&part_path)
                    .await?;
                f.seek(std::io::SeekFrom::Start(offset)).await?;
                f
            } else {
                tokio::fs::File::create(&part_path).await?
            });

            let mut buf = vec![0u8; CHUNK_SIZE];
            let mut last_report = Instant::now();
            let mut bytes_since_report = 0u64;
            let report_interval = Duration::from_millis(200);
            progress.bytes_transferred = offset;
            progress.total_bytes = total_bytes;
            progress.path_kind = detect_path_kind(&conn);
            self.transfers.report(progress);
            let mut path_poll = tokio::time::interval_at(
                tokio::time::Instant::now() + report_interval,
                report_interval,
            );

            loop {
                let read = tokio::select! {
                    biased;
                    // A route can change while the receive stream is waiting for data.
                    _ = path_poll.tick() => {
                        let path = detect_path_kind(&conn);
                        if path != progress.path_kind {
                            progress.path_kind = path;
                            progress.bytes_transferred = offset;
                            self.transfers.report(progress);
                        }
                        continue;
                    }
                    // QUIC's read future is cancel-safe.
                    read = recv.read(&mut buf) => read,
                };

                match read? {
                    Some(n) if n > 0 => {
                        anyhow::ensure!(
                            offset + n as u64 <= total_bytes,
                            "peer sent more data than the announced {total_bytes} bytes"
                        );
                        file.write_all(&buf[..n]).await?;
                        offset += n as u64;
                        bytes_since_report += n as u64;

                        let elapsed = last_report.elapsed();
                        if elapsed >= report_interval {
                            progress.bytes_transferred = offset;
                            progress.speed_bps = (bytes_since_report as f64
                                / elapsed.as_secs_f64().max(0.001))
                                as u64;
                            self.transfers.report(progress);
                            last_report = Instant::now();
                            bytes_since_report = 0;
                        }
                    }
                    _ => break,
                }
            }

            let path = detect_path_kind(&conn);
            if path != P2pPathKind::Unknown {
                progress.path_kind = path;
            }
            Ok(resp_header)
        };
        let received = while_connected(&conn, &mut transfer.cancel, receive).await;
        // A Tokio file can still have a pending write when its read loop is cancelled.
        // Finish that write before reporting completion and allowing a retry.
        if let Some(mut file) = partial_file {
            let flush = file.flush().await;
            if received.is_ok() {
                flush?;
            }
        }
        let resp_header = received?;
        let total_bytes = resp_header.size;

        // Verify BLAKE3 integrity on the completed file before renaming.
        let (actual_size, actual_hash) = compute_file_blake3(&part_path).await?;
        if transfer.cancel.try_recv().is_ok() {
            conn.close(transfers::CANCEL_CODE.into(), b"transfer cancelled");
            return Err(Cancelled.into());
        }
        if matches!(conn.close_reason(), Some(ConnectionError::ApplicationClosed(reason))
            if reason.error_code == CANCEL_CODE.into())
        {
            return Err(Cancelled.into());
        }
        if actual_size != total_bytes || actual_hash != resp_header.blake3_hash {
            let _ = tokio::fs::remove_file(&part_path).await;
            let _ = tokio::fs::remove_file(&owner_path).await;
            anyhow::bail!(
                "BLAKE3 integrity mismatch (expected {} bytes / {}, got {} bytes / {})",
                total_bytes,
                resp_header.blake3_hash,
                actual_size,
                actual_hash
            );
        }

        tokio::fs::rename(&part_path, &dest_path).await?;
        let _ = tokio::fs::remove_file(&owner_path).await;
        if resp_header.supports_receipt {
            conn.close(DELIVERED_CODE.into(), b"file verified and saved");
        }
        progress.bytes_transferred = total_bytes;
        progress.speed_bps = 0;
        progress.saved_path = Some(dest_path.to_string_lossy().to_string());
        Ok(())
    }

    pub async fn shutdown(&self) {
        self.accept_task.abort();
        self.endpoint.close().await;
    }

    pub fn requires_auth_token(&self) -> bool {
        self.source.require_auth_token
    }
}

async fn handle_incoming_connection(
    conn: Connection,
    source: Arc<SourceState>,
    transfers: Arc<Transfers>,
) -> anyhow::Result<()> {
    let (mut send, mut recv) = match conn.accept_bi().await {
        Ok(streams) => streams,
        Err(ConnectionError::ApplicationClosed(reason))
            if reason.error_code == PROBE_CODE.into() =>
        {
            return Ok(());
        }
        Err(err) => return Err(err.into()),
    };
    let req_bytes = read_frame(&mut recv).await?;
    let req: PullRequestHeader = serde_json::from_slice(&req_bytes)?;

    if source.require_auth_token {
        let remote = conn.remote_id().to_string();
        if !source.redeem_token(&req.token, &req.item_id, &remote).await {
            return reject_pull(&conn, &mut send, "unauthorized or expired P2P transfer token").await;
        }
    }

    let Some(entry) = source.shared_files.get(&req.item_id).map(|e| e.clone()) else {
        return reject_pull(&conn, &mut send, "file not found on source device").await;
    };

    let opened = match source.digest(&entry).await {
        Ok(digest) => tokio::fs::File::open(&entry.path)
            .await
            .map(|f| (f, digest))
            .map_err(anyhow::Error::from),
        Err(err) => Err(err),
    };
    let (mut file, (entry_size, entry_hash)) = match opened {
        Ok(opened) => opened,
        Err(err) => {
            return reject_pull(&conn, &mut send, &format!("source file unreadable: {err}")).await;
        }
    };

    let mut transfer = transfers.begin(req.item_id, Some(conn.remote_id().to_string()));
    let progress = &mut transfer.progress;
    progress.total_bytes = entry_size;
    progress.path_kind = detect_path_kind(&conn);
    progress.bytes_transferred = req.offset.min(entry_size);
    transfers.report(progress);
    let send_file = async {
        let mut start_offset = if req.offset <= entry_size {
            req.offset
        } else {
            0
        };
        let mut resumed_legacy = false;
        if let Some(prefix) = req.legacy_prefix {
            if req.offset == 0 && prefix.size > 0 && prefix.size <= entry_size {
                let mut reader = (&mut file).take(prefix.size);
                let mut hasher = blake3::Hasher::new();
                let mut buf = vec![0; CHUNK_SIZE];
                loop {
                    let n = reader.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    hasher.update(&buf[..n]);
                }
                resumed_legacy = hasher.finalize().to_hex().as_str() == prefix.hash;
                if resumed_legacy {
                    start_offset = prefix.size;
                }
            }
        }
        file.seek(std::io::SeekFrom::Start(start_offset)).await?;
        let resp = PullResponseHeader {
            ok: true,
            error: None,
            size: entry_size,
            blake3_hash: entry_hash,
            resumed_legacy,
            supports_receipt: req.wants_receipt,
        };
        write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;
        progress.bytes_transferred = start_offset;
        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut last_report = Instant::now();
        let mut bytes_since_report = 0u64;
        loop {
            let n = file.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            send.write_all(&buf[..n]).await?;
            progress.bytes_transferred += n as u64;
            bytes_since_report += n as u64;
            let elapsed = last_report.elapsed();
            if elapsed >= Duration::from_millis(200) {
                progress.speed_bps =
                    (bytes_since_report as f64 / elapsed.as_secs_f64().max(0.001)) as u64;
                let path = detect_path_kind(&conn);
                if path != P2pPathKind::Unknown {
                    progress.path_kind = path;
                }
                transfers.report(progress);
                last_report = Instant::now();
                bytes_since_report = 0;
            }
        }
        anyhow::ensure!(
            progress.bytes_transferred == entry_size,
            "source size changed while sending"
        );
        send.finish()?;
        confirm_sent(send.stopped().await)?;
        if req.wants_receipt {
            let reason = conn.closed().await;
            return confirm_sent(Err(StoppedError::ConnectionLost(reason)));
        }
        Ok(())
    };
    let result = while_connected(&conn, &mut transfer.cancel, send_file).await;
    transfer.finish(&result);
    result
}

const DELIVERED_CODE: u32 = 0x4444;
/// How long a rejecting source keeps the connection open for the requester to read why.
const REJECTION_LINGER: Duration = Duration::from_secs(10);

/// Sends a failed `PullResponseHeader`. Returning straight away would drop the
/// connection and could discard the response, so wait for the requester to close it.
async fn reject_pull(
    conn: &Connection,
    send: &mut iroh::endpoint::SendStream,
    error: &str,
) -> anyhow::Result<()> {
    let resp = PullResponseHeader {
        resumed_legacy: false,
        supports_receipt: false,
        ok: false,
        error: Some(error.to_string()),
        size: 0,
        blake3_hash: String::new(),
    };
    write_frame(send, &serde_json::to_vec(&resp)?).await?;
    send.finish()?;
    let _ = tokio::time::timeout(REJECTION_LINGER, conn.closed()).await;
    Ok(())
}

fn confirm_sent(result: Result<Option<VarInt>, StoppedError>) -> anyhow::Result<()> {
    match result {
        Ok(None) => Ok(()),
        Ok(Some(code)) if code == CANCEL_CODE.into() => Err(Cancelled.into()),
        Ok(Some(code)) => anyhow::bail!("receiver stopped the stream ({code})"),
        Err(StoppedError::ConnectionLost(ConnectionError::ApplicationClosed(close)))
            if close.error_code == DELIVERED_CODE.into() =>
        {
            Ok(())
        }
        Err(StoppedError::ConnectionLost(ConnectionError::ApplicationClosed(close)))
            if close.error_code == CANCEL_CODE.into() =>
        {
            Err(Cancelled.into())
        }
        Err(e) => Err(anyhow::anyhow!("delivery unconfirmed: {e}")),
    }
}

struct PartialLease<'a> {
    paths: &'a DashSet<PathBuf>,
    path: &'a Path,
}

impl<'a> PartialLease<'a> {
    fn acquire(paths: &'a DashSet<PathBuf>, path: &'a Path) -> Option<Self> {
        paths.insert(path.to_owned()).then(|| Self { paths, path })
    }
}

impl Drop for PartialLease<'_> {
    fn drop(&mut self) {
        self.paths.remove(self.path);
    }
}

fn part_path_for(dest_path: &Path) -> PathBuf {
    let mut os = OsString::from(dest_path.as_os_str());
    os.push(".dropdrawer.part");
    PathBuf::from(os)
}

/// Records which drawer item a `.dropdrawer.part` file belongs to.
fn part_owner_path_for(part_path: &Path) -> PathBuf {
    let mut os = OsString::from(part_path.as_os_str());
    os.push(".owner");
    PathBuf::from(os)
}

/// Partials written before owners were recorded have no owner file; keep resuming
/// those as before. Otherwise the partial must belong to `item_id`.
async fn partial_belongs_to(owner_path: &Path, item_id: &str) -> bool {
    match tokio::fs::read_to_string(owner_path).await {
        Ok(owner) => owner.trim() == item_id,
        Err(_) => true,
    }
}

fn detect_path_kind(conn: &Connection) -> P2pPathKind {
    for p in conn.paths().iter() {
        if p.is_selected() {
            return match p.remote_addr() {
                TransportAddr::Ip(_) => P2pPathKind::Direct,
                TransportAddr::Relay(_) => P2pPathKind::Relay,
                _ => P2pPathKind::Unknown,
            };
        }
    }
    P2pPathKind::Unknown
}

async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, data: &[u8]) -> anyhow::Result<()> {
    let len = data.len() as u32;
    w.write_all(&len.to_be_bytes()).await?;
    w.write_all(data).await?;
    Ok(())
}

const MAX_FRAME_LEN: usize = 64 * 1024;

async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> anyhow::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    // Headers are small JSON documents; this is read before the token is checked.
    if len > MAX_FRAME_LEN {
        anyhow::bail!("protocol frame too large: {len}");
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    Ok(buf)
}

pub async fn compute_file_blake3(path: &Path) -> anyhow::Result<(u64, String)> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let mut file = std::fs::File::open(&path)?;
        let mut hasher = blake3::Hasher::new();
        let mut buf = vec![0u8; 256 * 1024];
        let mut total = 0u64;
        loop {
            let n = std::io::Read::read(&mut file, &mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            total += n as u64;
        }
        Ok((total, hasher.finalize().to_hex().to_string()))
    })
    .await?
}

async fn load_or_create_secret_key(path: &Path) -> anyhow::Result<SecretKey> {
    if path.exists() {
        let bytes = tokio::fs::read(path).await?;
        if bytes.len() == 32 {
            let arr: [u8; 32] = bytes.try_into().unwrap();
            return Ok(SecretKey::from_bytes(&arr));
        }
    }
    let mut raw = [0u8; 32];
    raw[..16].copy_from_slice(Uuid::new_v4().as_bytes());
    raw[16..].copy_from_slice(Uuid::new_v4().as_bytes());
    let key = SecretKey::from_bytes(&raw);
    let bytes = key.to_bytes();
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        // The node identity key must not be readable by other local users.
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        options.open(&path)?.write_all(&bytes)
    })
    .await??;
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn either_peer_can_cancel_a_pull_and_retry() {
        tokio::time::timeout(Duration::from_secs(30), async {
            let dir = TempDir::new().unwrap();
            let start = |name: &str| {
                P2pNode::start(
                    P2pConfig {
                        data_dir: dir.path().join(name).display().to_string(),
                        custom_relay_url: None,
                        disable_relay: true,
                    },
                    true,
                )
            };
            let sender = start("sender").await.unwrap();
            let receiver = start("receiver").await.unwrap();
            let src = dir.path().join("source.bin");
            let dest = dir.path().join("received.bin");
            let part = part_path_for(&dest);
            std::fs::File::create(&src)
                .unwrap()
                .set_len(32 * 1024 * 1024)
                .unwrap();
            let source = sender.register_file("item".into(), &src).await.unwrap();
            // Tokens are single-use: every retry gets a fresh one from the server.
            let pull = |transfer| {
                let token = Uuid::new_v4().to_string();
                sender.authorize_token(
                    "item".into(),
                    token.clone(),
                    Utc::now() + chrono::Duration::minutes(1),
                );
                let info = sender.node_info();
                let dest = dest.clone();
                let receiver = receiver.clone();
                tokio::spawn(async move {
                    receiver
                        .run_download(
                            transfer,
                            DownloadFileReq {
                                item_id: "item".into(),
                                remote_node_id: info.node_id,
                                remote_relay_url: info.relay_url,
                                remote_direct_addrs: info.direct_addrs,
                                transfer_token: token,
                                dest_path: dest,
                                skip_legacy_resume: false,
                            },
                        )
                        .await
                })
            };

            // Cancellation is registered synchronously, even before connect runs.
            let first = receiver.transfers.begin("item".into(), None);
            receiver.transfers.cancel(&first.progress.transfer_id);
            assert!(pull(first).await.unwrap().unwrap_err().is::<Cancelled>());
            assert!(!part.exists());

            for cancel_at_sender in [true, false] {
                let previous = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
                let handle = receiver.transfers.begin("item".into(), None);
                let download_id = handle.progress.transfer_id.clone();
                let download = pull(handle);
                let upload_id = loop {
                    if let Some(event) = sender.drain_events().into_iter().find(|e| !e.finished) {
                        assert_eq!(event.sending_to, Some(receiver.node_info().node_id));
                        break event.transfer_id;
                    }
                    tokio::task::yield_now().await;
                };
                while !std::fs::metadata(&part).is_ok_and(|m| m.len() > previous) {
                    tokio::task::yield_now().await;
                }
                if cancel_at_sender {
                    sender.transfers.cancel(&upload_id);
                } else {
                    receiver.transfers.cancel(&download_id);
                }
                assert!(download.await.unwrap().unwrap_err().is::<Cancelled>());
                assert!(
                    receiver
                        .drain_events()
                        .iter()
                        .any(|e| e.transfer_id == download_id
                            && e.finished
                            && e.cancelled
                            && e.error.is_none())
                );
                loop {
                    if let Some(end) = sender
                        .drain_events()
                        .into_iter()
                        .find(|e| e.finished && e.transfer_id == upload_id)
                    {
                        assert!(end.cancelled && end.error.is_none(), "{end:?}");
                        break;
                    }
                    tokio::task::yield_now().await;
                }
                assert!(!dest.exists());
                assert!(std::fs::metadata(&part).unwrap().len() < source.size);
            }

            let complete = pull(receiver.transfers.begin("item".into(), None))
                .await
                .unwrap()
                .unwrap();
            assert!(complete.finished && !complete.cancelled);
            assert_eq!(
                compute_file_blake3(&dest).await.unwrap(),
                (source.size, source.blake3_hash)
            );
            sender.shutdown().await;
            receiver.shutdown().await;
        })
        .await
        .expect("cancelled transfers must terminate on both peers");
    }

    #[tokio::test]
    async fn test_p2p_end_to_end_transfer_with_blake3_verification() {
        let dir_a = TempDir::new().unwrap();
        let dir_b = TempDir::new().unwrap();

        let node_a = P2pNode::start(
            P2pConfig {
                data_dir: dir_a.path().to_string_lossy().to_string(),
                custom_relay_url: None,
                disable_relay: true,
            },
            true,
        )
        .await
        .unwrap();

        let node_b = P2pNode::start(
            P2pConfig {
                data_dir: dir_b.path().to_string_lossy().to_string(),
                custom_relay_url: None,
                disable_relay: true,
            },
            true,
        )
        .await
        .unwrap();

        // Create a 1.5 MB test file on node A
        let src_file = dir_a.path().join("sample.bin");
        let payload: Vec<u8> = (0..(1500 * 1024)).map(|i| (i % 251) as u8).collect();
        tokio::fs::write(&src_file, &payload).await.unwrap();

        let info = node_a
            .register_file("item-42".to_string(), &src_file)
            .await
            .unwrap();
        assert_eq!(info.size, payload.len() as u64);

        let dest_file = dir_b.path().join("received.bin");
        let legacy = dest_file.with_extension("dropdrawer.part");
        for matches in [false, true] {
            let prefix = if matches {
                &payload[..65536]
            } else {
                b"another file"
            };
            tokio::fs::write(&legacy, prefix).await.unwrap();
            // Authorize a single-use pull token on node A.
            let token = format!("secret-transfer-token-{matches}");
            node_a.authorize_token(
                "item-42".to_string(),
                token.clone(),
                Utc::now() + chrono::Duration::minutes(5),
            );
            let info_a = node_a.node_info();
            let progress = node_b
                .download_file(
                    "item-42".into(),
                    info_a.node_id,
                    info_a.relay_url,
                    info_a.direct_addrs,
                    token.clone(),
                    dest_file.clone(),
                )
                .await
                .unwrap();
            assert!(progress.finished);
            assert_eq!(progress.total_bytes, payload.len() as u64);
            assert!(
                node_b
                    .drain_events()
                    .iter()
                    .any(|e| !e.finished && e.path_kind == P2pPathKind::Direct)
            );
            assert_eq!(tokio::fs::read(&dest_file).await.unwrap(), payload);
            if matches {
                assert!(!legacy.exists());
            } else {
                assert_eq!(tokio::fs::read(&legacy).await.unwrap(), prefix);
            }
        }

        node_a.shutdown().await;
        node_b.shutdown().await;
    }

    async fn lan_node(dir: &Path, name: &str) -> Arc<P2pNode> {
        P2pNode::start(
            P2pConfig {
                data_dir: dir.join(name).display().to_string(),
                custom_relay_url: None,
                disable_relay: true,
            },
            true,
        )
        .await
        .unwrap()
    }

    async fn pull(
        receiver: &Arc<P2pNode>,
        sender: &Arc<P2pNode>,
        item_id: &str,
        token: &str,
        dest: &Path,
    ) -> anyhow::Result<P2pTransferProgress> {
        let info = sender.node_info();
        receiver
            .download_file(
                item_id.into(),
                info.node_id,
                info.relay_url,
                info.direct_addrs,
                token.into(),
                dest.to_path_buf(),
            )
            .await
    }

    #[tokio::test]
    async fn tokens_are_single_use_bound_to_peer_and_tolerate_late_push() {
        tokio::time::timeout(Duration::from_secs(60), async {
            let dir = TempDir::new().unwrap();
            let sender = lan_node(dir.path(), "sender").await;
            let receiver = lan_node(dir.path(), "receiver").await;
            let other = lan_node(dir.path(), "other").await;
            let src = dir.path().join("src.bin");
            std::fs::write(&src, vec![7u8; 300 * 1024]).unwrap();

            // Registration does not read the file; the first pull hashes it.
            let info = sender.register_file_deferred("item".into(), &src).unwrap();
            assert_eq!(info.size, 300 * 1024);
            assert!(info.blake3_hash.is_empty());

            // The pull may reach the source before the control server's token push.
            let late = {
                let sender = sender.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    sender.authorize_token(
                        "item".into(),
                        "late".into(),
                        Utc::now() + chrono::Duration::minutes(1),
                    );
                })
            };
            let dest = dir.path().join("a.bin");
            pull(&receiver, &sender, "item", "late", &dest).await.unwrap();
            late.await.unwrap();
            assert_eq!(std::fs::read(&dest).unwrap(), vec![7u8; 300 * 1024]);

            // A redeemed token cannot be replayed.
            let replay = pull(&receiver, &sender, "item", "late", &dir.path().join("b.bin")).await;
            assert!(replay.unwrap_err().to_string().contains("unauthorized"));

            // A token issued for one peer is useless to another.
            sender.authorize_token_for(
                "item".into(),
                "bound".into(),
                Utc::now() + chrono::Duration::minutes(1),
                Some(receiver.node_info().node_id),
            );
            let stolen = pull(&other, &sender, "item", "bound", &dir.path().join("c.bin")).await;
            assert!(stolen.unwrap_err().to_string().contains("unauthorized"));
            pull(&receiver, &sender, "item", "bound", &dir.path().join("d.bin"))
                .await
                .unwrap();

            // Expired tokens are rejected and pruned when new ones arrive.
            sender.authorize_token(
                "item".into(),
                "expired".into(),
                Utc::now() - chrono::Duration::seconds(1),
            );
            let expired = pull(&receiver, &sender, "item", "expired", &dir.path().join("e.bin")).await;
            assert!(expired.is_err());
            sender.authorize_token(
                "item".into(),
                "fresh".into(),
                Utc::now() + chrono::Duration::minutes(1),
            );
            assert!(!sender.source.authorized_tokens.contains_key("expired"));

            for node in [sender, receiver, other] {
                node.shutdown().await;
            }
        })
        .await
        .expect("token test must not hang");
    }

    #[tokio::test]
    async fn partial_left_by_a_same_named_item_is_not_resumed() {
        tokio::time::timeout(Duration::from_secs(30), async {
            let dir = TempDir::new().unwrap();
            let sender = lan_node(dir.path(), "sender").await;
            let receiver = lan_node(dir.path(), "receiver").await;
            let src = dir.path().join("src.bin");
            let payload: Vec<u8> = (0..(400 * 1024)).map(|i| (i % 253) as u8).collect();
            std::fs::write(&src, &payload).unwrap();
            sender.register_file("item-b".into(), &src).await.unwrap();

            let dest = dir.path().join("photo.png");
            let part = part_path_for(&dest);
            let owner = part_owner_path_for(&part);
            std::fs::write(&part, vec![0xAAu8; 100 * 1024]).unwrap();
            std::fs::write(&owner, "item-a").unwrap();

            sender.authorize_token(
                "item-b".into(),
                "t".into(),
                Utc::now() + chrono::Duration::minutes(1),
            );
            pull(&receiver, &sender, "item-b", "t", &dest).await.unwrap();
            assert_eq!(std::fs::read(&dest).unwrap(), payload);
            assert!(!part.exists() && !owner.exists());

            sender.shutdown().await;
            receiver.shutdown().await;
        })
        .await
        .expect("transfer must finish");
    }

    #[test]
    fn require_delivery_confirmation() {
        assert!(confirm_sent(Ok(None)).is_ok());
        assert!(
            confirm_sent(Ok(Some(CANCEL_CODE.into())))
                .unwrap_err()
                .is::<Cancelled>()
        );
        assert!(confirm_sent(Ok(Some(7u32.into()))).is_err());
        assert!(
            confirm_sent(Err(StoppedError::ConnectionLost(ConnectionError::TimedOut))).is_err()
        );
    }

    #[test]
    fn part_path_distinguishes_same_stem_different_extensions() {
        let dir = Path::new("/tmp/dropdrawer");
        let a = part_path_for(&dir.join("photo.png"));
        let b = part_path_for(&dir.join("photo.jpg"));
        assert_ne!(a, b);
        assert_eq!(a, dir.join("photo.png.dropdrawer.part"));
        assert_eq!(b, dir.join("photo.jpg.dropdrawer.part"));
    }

    #[test]
    fn transfers_preserve_terminal_events_under_queue_pressure() {
        let transfers = Arc::new(Transfers::default());
        let mut t0 = transfers.begin("done-item".into(), None);
        t0.finish(&Ok(()));
        let done_id = t0.progress.transfer_id.clone();

        for i in 0..300 {
            let t = transfers.begin(format!("live-{i}"), None);
            transfers.report(&t.progress);
        }

        for i in 0..1100 {
            transfers.begin(format!("done-{i}"), None).finish(&Ok(()));
        }
        let drained = transfers.drain();
        assert_eq!(drained.iter().filter(|e| e.finished).count(), 1101);
        assert!(
            drained
                .iter()
                .any(|e| e.transfer_id == done_id && e.finished),
            "terminal event must not be evicted by live progress updates"
        );
    }
}
