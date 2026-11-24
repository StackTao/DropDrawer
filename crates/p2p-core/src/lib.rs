pub mod ffi;
mod transfers;

use transfers::{Cancelled, Transfer, Transfers, while_connected};

#[cfg(any(target_os = "windows", target_os = "macos"))]
mod relay_probe;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayUrl, SecretKey, TransportAddr,
    endpoint::{Connection, RelayMode},
};
use protocol::{P2pPathKind, P2pTransferProgress};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use uuid::Uuid;

pub const DROPDRAWER_ALPN: &[u8] = b"/dropdrawer/file/1";
const CHUNK_SIZE: usize = 256 * 1024; // 256 KiB QUIC streaming chunks

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

#[derive(Debug, Clone)]
struct SharedFileEntry {
    path: PathBuf,
    size: u64,
    blake3_hash: String,
}

#[derive(Debug, Clone)]
struct AuthorizedToken {
    item_id: String,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PullRequestHeader {
    item_id: String,
    token: String,
    offset: u64,
}

#[derive(Debug, Serialize, Deserialize)]
struct PullResponseHeader {
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
}

pub struct P2pNode {
    endpoint: Endpoint,
    shared_files: Arc<DashMap<String, SharedFileEntry>>,
    /// Map of `token -> AuthorizedToken`. If empty & `require_auth_token` is false, allows test pulls.
    authorized_tokens: Arc<DashMap<String, AuthorizedToken>>,
    require_auth_token: bool,
    transfers: Arc<Transfers>,
    accept_task: tokio::task::JoinHandle<()>,
    #[cfg(any(target_os = "windows", target_os = "macos"))]
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

        let shared_files = Arc::new(DashMap::new());
        let authorized_tokens = Arc::new(DashMap::new());
        let transfers = Arc::new(Transfers::default());
        let incoming_transfers = transfers.clone();

        let ep_clone = endpoint.clone();
        let files_clone = shared_files.clone();
        let tokens_clone = authorized_tokens.clone();
        #[cfg(any(target_os = "windows", target_os = "macos"))]
        let relay_probe = Arc::new(relay_probe::RelayProbe::new(endpoint.clone()));
        #[cfg(any(target_os = "windows", target_os = "macos"))]
        let incoming_relay_probe = relay_probe.clone();
        let accept_task = tokio::spawn(async move {
            while let Some(incoming) = ep_clone.accept().await {
                let files = files_clone.clone();
                let transfers = incoming_transfers.clone();
                let tokens = tokens_clone.clone();
                #[cfg(any(target_os = "windows", target_os = "macos"))]
                let relay_probe = incoming_relay_probe.clone();
                tokio::spawn(async move {
                    match incoming.await {
                        Ok(conn) => {
                            if let Err(err) = handle_incoming_connection(
                                conn,
                                files,
                                transfers,
                                tokens,
                                require_auth_token,
                                #[cfg(any(target_os = "windows", target_os = "macos"))]
                                &relay_probe,
                            )
                            .await
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
            shared_files,
            authorized_tokens,
            require_auth_token,
            transfers,
            accept_task,
            #[cfg(any(target_os = "windows", target_os = "macos"))]
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
        let path = path.as_ref().to_path_buf();
        let (size, blake3_hash) = compute_file_blake3(&path).await?;
        self.shared_files.insert(
            item_id.clone(),
            SharedFileEntry {
                path: path.clone(),
                size,
                blake3_hash: blake3_hash.clone(),
            },
        );
        Ok(RegisteredFileInfo {
            item_id,
            path: path.to_string_lossy().to_string(),
            size,
            blake3_hash,
        })
    }

    pub fn unregister_file(&self, item_id: &str) {
        self.shared_files.remove(item_id);
    }

    /// Authorizes an incoming one-time/short-lived pull token pushed by the control server.
    pub fn authorize_token(&self, item_id: String, token: String, expires_at: DateTime<Utc>) {
        self.authorized_tokens.insert(
            token,
            AuthorizedToken {
                item_id,
                expires_at,
            },
        );
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
            conn = self.endpoint.connect(remote_addr, DROPDRAWER_ALPN) => conn?,
        };

        let progress = &mut transfer.progress;
        progress.path_kind = detect_path_kind(&conn);
        #[cfg(any(target_os = "windows", target_os = "macos"))]
        self.relay_probe.schedule(&conn);
        let part_path = dest_path.with_extension("dropdrawer.part");
        let mut partial_file = None;
        let receive = async {
            let (mut send, mut recv) = conn.open_bi().await?;

            // Check partial file for resumable transfer
            if let Some(parent) = dest_path.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            let existing_offset = if part_path.exists() {
                tokio::fs::metadata(&part_path)
                    .await
                    .map(|m| m.len())
                    .unwrap_or(0)
            } else {
                0
            };

            let req_header = PullRequestHeader {
                item_id: progress.item_id.clone(),
                token: req.transfer_token,
                offset: existing_offset,
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
            #[cfg(any(target_os = "windows", target_os = "macos"))]
            {
                progress.path_kind = detect_path_kind(&conn);
                self.transfers.report(progress);
            }
            #[cfg(any(target_os = "windows", target_os = "macos"))]
            let mut path_poll = tokio::time::interval_at(
                tokio::time::Instant::now() + report_interval,
                report_interval,
            );

            loop {
                #[cfg(any(target_os = "windows", target_os = "macos"))]
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
                #[cfg(not(any(target_os = "windows", target_os = "macos")))]
                let read = recv.read(&mut buf).await;

                match read? {
                    Some(n) if n > 0 => {
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

            #[cfg(any(target_os = "windows", target_os = "macos"))]
            {
                let path = detect_path_kind(&conn);
                if path != P2pPathKind::Unknown {
                    progress.path_kind = path;
                }
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
        if actual_size != total_bytes || actual_hash != resp_header.blake3_hash {
            let _ = tokio::fs::remove_file(&part_path).await;
            anyhow::bail!(
                "BLAKE3 integrity mismatch (expected {} bytes / {}, got {} bytes / {})",
                total_bytes,
                resp_header.blake3_hash,
                actual_size,
                actual_hash
            );
        }

        tokio::fs::rename(&part_path, &dest_path).await?;
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
        self.require_auth_token
    }
}

async fn handle_incoming_connection(
    conn: Connection,
    shared_files: Arc<DashMap<String, SharedFileEntry>>,
    transfers: Arc<Transfers>,
    authorized_tokens: Arc<DashMap<String, AuthorizedToken>>,
    require_auth_token: bool,
    #[cfg(any(target_os = "windows", target_os = "macos"))] relay_probe: &Arc<
        relay_probe::RelayProbe,
    >,
) -> anyhow::Result<()> {
    let (mut send, mut recv) = conn.accept_bi().await?;
    let req_bytes = read_frame(&mut recv).await?;
    let req: PullRequestHeader = serde_json::from_slice(&req_bytes)?;

    if require_auth_token {
        let valid = match authorized_tokens.get(&req.token) {
            Some(entry) => entry.item_id == req.item_id && entry.expires_at > Utc::now(),
            None => false,
        };
        if !valid {
            let resp = PullResponseHeader {
                ok: false,
                error: Some("unauthorized or expired P2P transfer token".to_string()),
                size: 0,
                blake3_hash: String::new(),
            };
            write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;
            send.finish()?;
            return Ok(());
        }
    }

    let Some(entry) = shared_files.get(&req.item_id).map(|e| e.clone()) else {
        let resp = PullResponseHeader {
            ok: false,
            error: Some("file not found on source device".to_string()),
            size: 0,
            blake3_hash: String::new(),
        };
        write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;
        send.finish()?;
        return Ok(());
    };

    let mut file = match tokio::fs::File::open(&entry.path).await {
        Ok(f) => f,
        Err(err) => {
            let resp = PullResponseHeader {
                ok: false,
                error: Some(format!("source file unreadable: {err}")),
                size: 0,
                blake3_hash: String::new(),
            };
            write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;
            send.finish()?;
            return Ok(());
        }
    };

    let resp = PullResponseHeader {
        ok: true,
        error: None,
        size: entry.size,
        blake3_hash: entry.blake3_hash.clone(),
    };
    let mut transfer = transfers.begin(req.item_id, Some(conn.remote_id().to_string()));
    let progress = &mut transfer.progress;
    progress.total_bytes = entry.size;
    progress.path_kind = detect_path_kind(&conn);
    progress.bytes_transferred = req.offset.min(entry.size);
    transfers.report(progress);
    let send_file = async {
        write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;

        #[cfg(any(target_os = "windows", target_os = "macos"))]
        relay_probe.schedule(&conn);

        let start_offset = req.offset.min(entry.size);
        if start_offset > 0 {
            file.seek(std::io::SeekFrom::Start(start_offset)).await?;
        }

        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut last_report = Instant::now();
        loop {
            let n = file.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            send.write_all(&buf[..n]).await?;
            progress.bytes_transferred += n as u64;
            if last_report.elapsed() >= Duration::from_millis(200) {
                transfers.report(progress);
                last_report = Instant::now();
            }
        }
        send.finish()?;
        // Wait briefly for peer to read the FIN cleanly.
        send.stopped().await?;
        Ok(())
    };
    let result = while_connected(&conn, &mut transfer.cancel, send_file).await;
    transfer.finish(&result);
    result
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

async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> anyhow::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > 4 * 1024 * 1024 {
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
    tokio::fs::write(path, key.to_bytes()).await?;
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
            let part = dest.with_extension("dropdrawer.part");
            std::fs::File::create(&src)
                .unwrap()
                .set_len(32 * 1024 * 1024)
                .unwrap();
            let source = sender.register_file("item".into(), &src).await.unwrap();
            sender.authorize_token(
                "item".into(),
                "token".into(),
                Utc::now() + chrono::Duration::minutes(1),
            );
            let pull = |transfer| {
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
                                transfer_token: "token".into(),
                                dest_path: dest,
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

        // Authorize pull token on node A
        let token = "secret-transfer-token".to_string();
        node_a.authorize_token(
            "item-42".to_string(),
            token.clone(),
            Utc::now() + chrono::Duration::minutes(5),
        );

        let info_a = node_a.node_info();
        let dest_file = dir_b.path().join("received.bin");
        let progress = node_b
            .download_file(
                "item-42".to_string(),
                info_a.node_id,
                info_a.relay_url,
                info_a.direct_addrs,
                token,
                dest_file.clone(),
            )
            .await
            .unwrap();

        assert!(progress.finished);
        assert_eq!(progress.total_bytes, payload.len() as u64);
        #[cfg(any(target_os = "windows", target_os = "macos"))]
        assert!(
            node_b
                .drain_events()
                .iter()
                .any(|event| { !event.finished && event.path_kind == P2pPathKind::Direct })
        );
        let received = tokio::fs::read(&dest_file).await.unwrap();
        assert_eq!(received, payload);

        node_a.shutdown().await;
        node_b.shutdown().await;
    }
}
