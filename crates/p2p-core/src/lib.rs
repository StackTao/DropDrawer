pub mod ffi;

#[cfg(target_os = "windows")]
mod windows;

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use iroh::{
    endpoint::{Connection, RelayMode},
    Endpoint, EndpointAddr, EndpointId, RelayUrl, SecretKey, TransportAddr,
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

pub struct P2pNode {
    endpoint: Endpoint,
    shared_files: Arc<DashMap<String, SharedFileEntry>>,
    /// Map of `token -> AuthorizedToken`. If empty & `require_auth_token` is false, allows test pulls.
    authorized_tokens: Arc<DashMap<String, AuthorizedToken>>,
    require_auth_token: bool,
    events: Arc<Mutex<VecDeque<P2pTransferProgress>>>,
    accept_task: tokio::task::JoinHandle<()>,
    #[cfg(target_os = "windows")]
    relay_probe: Arc<windows::RelayProbe>,
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
        let events = Arc::new(Mutex::new(VecDeque::new()));

        let ep_clone = endpoint.clone();
        let files_clone = shared_files.clone();
        let tokens_clone = authorized_tokens.clone();
        #[cfg(target_os = "windows")]
        let relay_probe = Arc::new(windows::RelayProbe::new(endpoint.clone()));
        #[cfg(target_os = "windows")]
        let incoming_relay_probe = relay_probe.clone();
        let accept_task = tokio::spawn(async move {
            while let Some(incoming) = ep_clone.accept().await {
                let files = files_clone.clone();
                let tokens = tokens_clone.clone();
                #[cfg(target_os = "windows")]
                let relay_probe = incoming_relay_probe.clone();
                tokio::spawn(async move {
                    match incoming.await {
                        Ok(conn) => {
                            if let Err(err) = handle_incoming_connection(
                                conn,
                                files,
                                tokens,
                                require_auth_token,
                                #[cfg(target_os = "windows")]
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
            events,
            accept_task,
            #[cfg(target_os = "windows")]
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
        self.authorized_tokens
            .insert(token, AuthorizedToken { item_id, expires_at });
    }

    pub fn push_event(&self, event: P2pTransferProgress) {
        if let Ok(mut q) = self.events.lock() {
            q.push_back(event);
            while q.len() > 256 {
                q.pop_front();
            }
        }
    }

    pub fn drain_events(&self) -> Vec<P2pTransferProgress> {
        if let Ok(mut q) = self.events.lock() {
            q.drain(..).collect()
        } else {
            Vec::new()
        }
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
        let transfer_id = Uuid::new_v4().to_string();
        let endpoint_id: EndpointId = remote_node_id.parse()?;

        let mut transport_addrs = Vec::new();
        if let Some(r) = remote_relay_url.filter(|s| !s.is_empty()) {
            if let Ok(relay_url) = r.parse::<RelayUrl>() {
                transport_addrs.push(TransportAddr::Relay(relay_url));
            }
        }
        for s in &remote_direct_addrs {
            if let Ok(sock) = s.parse::<SocketAddr>() {
                transport_addrs.push(TransportAddr::Ip(sock));
            }
        }

        let remote_addr = EndpointAddr::from_parts(endpoint_id, transport_addrs);
        let conn = self.endpoint.connect(remote_addr, DROPDRAWER_ALPN).await?;

        let path_kind = detect_path_kind(&conn);
        #[cfg(target_os = "windows")]
        self.relay_probe.schedule(&conn);
        let (mut send, mut recv) = conn.open_bi().await?;

        // Check partial file for resumable transfer
        if let Some(parent) = dest_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let part_path = dest_path.with_extension("dropdrawer.part");
        let existing_offset = if part_path.exists() {
            tokio::fs::metadata(&part_path)
                .await
                .map(|m| m.len())
                .unwrap_or(0)
        } else {
            0
        };

        let req_header = PullRequestHeader {
            item_id: item_id.clone(),
            token: transfer_token,
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

        let mut file = if offset > 0 {
            let mut f = tokio::fs::OpenOptions::new()
                .write(true)
                .open(&part_path)
                .await?;
            f.seek(std::io::SeekFrom::Start(offset)).await?;
            f
        } else {
            tokio::fs::File::create(&part_path).await?
        };

        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut last_report = Instant::now();
        let mut bytes_since_report = 0u64;
        let report_interval = Duration::from_millis(200);
        let mut progress = P2pTransferProgress {
            transfer_id,
            item_id,
            bytes_transferred: offset,
            total_bytes,
            speed_bps: 0,
            path_kind,
            finished: false,
            saved_path: None,
            error: None,
        };

        #[cfg(target_os = "windows")]
        {
            progress.path_kind = detect_path_kind(&conn);
            self.push_event(progress.clone());
        }
        #[cfg(target_os = "windows")]
        let mut path_poll = tokio::time::interval_at(
            tokio::time::Instant::now() + report_interval,
            report_interval,
        );

        loop {
            #[cfg(target_os = "windows")]
            let read = tokio::select! {
                biased;
                // A route can change while the receive stream is waiting for data.
                _ = path_poll.tick() => {
                    let path = detect_path_kind(&conn);
                    if path != progress.path_kind {
                        progress.path_kind = path;
                        progress.bytes_transferred = offset;
                        self.push_event(progress.clone());
                    }
                    continue;
                }
                // QUIC's read future is cancel-safe.
                read = recv.read(&mut buf) => read,
            };
            #[cfg(not(target_os = "windows"))]
            let read = recv.read(&mut buf).await;

            match read? {
                Some(n) if n > 0 => {
                    file.write_all(&buf[..n]).await?;
                    offset += n as u64;
                    bytes_since_report += n as u64;

                    let elapsed = last_report.elapsed();
                    if elapsed >= report_interval {
                        progress.bytes_transferred = offset;
                        progress.speed_bps =
                            (bytes_since_report as f64 / elapsed.as_secs_f64().max(0.001)) as u64;
                        self.push_event(progress.clone());
                        last_report = Instant::now();
                        bytes_since_report = 0;
                    }
                }
                _ => break,
            }
        }

        #[cfg(target_os = "windows")]
        {
            let path = detect_path_kind(&conn);
            if path != P2pPathKind::Unknown {
                progress.path_kind = path;
            }
        }
        file.flush().await?;
        drop(file);

        // Verify BLAKE3 integrity on the completed file before renaming.
        let (actual_size, actual_hash) = compute_file_blake3(&part_path).await?;
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
        progress.finished = true;
        progress.saved_path = Some(dest_path.to_string_lossy().to_string());
        self.push_event(progress.clone());
        Ok(progress)
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
    authorized_tokens: Arc<DashMap<String, AuthorizedToken>>,
    require_auth_token: bool,
    #[cfg(target_os = "windows")] relay_probe: &Arc<windows::RelayProbe>,
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
    write_frame(&mut send, &serde_json::to_vec(&resp)?).await?;

    #[cfg(target_os = "windows")]
    relay_probe.schedule(&conn);

    let start_offset = req.offset.min(entry.size);
    if start_offset > 0 {
        file.seek(std::io::SeekFrom::Start(start_offset)).await?;
    }

    let mut buf = vec![0u8; CHUNK_SIZE];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        send.write_all(&buf[..n]).await?;
    }
    send.finish()?;
    // Wait briefly for peer to read the FIN cleanly.
    let _ = send.stopped().await;
    Ok(())
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
        #[cfg(target_os = "windows")]
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
