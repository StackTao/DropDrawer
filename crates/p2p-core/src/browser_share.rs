use std::{net::IpAddr, sync::Arc, time::Duration};

use anyhow::{Context, ensure};
use bytes::Bytes;
use serde::Deserialize;
use tokio::{fs::File, io::AsyncReadExt, sync::mpsc, time::timeout};
use webrtc::{
    api::{APIBuilder, setting_engine::SettingEngine},
    data_channel::RTCDataChannel,
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription,
    },
};

use crate::P2pNode;

const CHUNK: usize = 32 * 1024;
const WINDOW: u64 = 512 * 1024;
const IDLE: Duration = Duration::from_secs(15);

#[derive(Deserialize)]
pub(crate) struct Prepare {
    item_id: String,
    size: u64,
    blake3_hash: Option<String>,
    sdp: String,
    start_token: String,
}

enum Signal {
    Start(Arc<RTCDataChannel>),
    Ack(u64),
    Received,
    Closed,
}

impl P2pNode {
    pub(crate) async fn prepare_browser_share(&self, request: Prepare) -> anyhow::Result<String> {
        let permit = self.browser_share_permits.clone().try_acquire_owned()?;
        ensure!(
            request.sdp.len() <= 48 * 1024 && uuid::Uuid::parse_str(&request.start_token).is_ok(),
            "invalid browser share offer"
        );
        ensure!(
            !self.browser_share_shutdown.is_cancelled(),
            "P2P node is stopped"
        );
        let path = self
            .source
            .shared_files
            .get(&request.item_id)
            .map(|entry| entry.path.clone())
            .context("file is not registered")?;
        let file = File::open(path).await?;
        let meta = file.metadata().await?;
        ensure!(
            meta.is_file() && meta.len() == request.size,
            "shared file has changed"
        );

        let mut settings = SettingEngine::default();
        // The browser drives ICE checks. Do not dial candidate addresses from
        // an anonymous visitor or gather relay/public candidates.
        settings.set_lite(true);
        settings.set_ip_filter(Box::new(lan_address));
        let api = APIBuilder::new().with_setting_engine(settings).build();
        let peer = Arc::new(api.new_peer_connection(RTCConfiguration::default()).await?);

        let (signals, incoming) = mpsc::channel(16);
        let closed = signals.clone();
        peer.on_peer_connection_state_change(Box::new(move |state| {
            if matches!(
                state,
                RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed
            ) {
                let _ = closed.try_send(Signal::Closed);
            }
            Box::pin(async {})
        }));
        let start = Arc::new(format!("start:{}", request.start_token));
        peer.on_data_channel(Box::new(move |channel| {
            let start = start.clone();
            let signals = signals.clone();
            Box::pin(async move {
                if channel.label() != "dropdrawer-file" {
                    let _ = channel.close().await;
                    return;
                }
                let data = Arc::downgrade(&channel);
                let closed = signals.clone();
                channel.on_close(Box::new(move || {
                    let _ = closed.try_send(Signal::Closed);
                    Box::pin(async {})
                }));
                channel.on_message(Box::new(move |message| {
                    if message.is_string
                        && let Ok(text) = std::str::from_utf8(&message.data)
                    {
                        let signal = if text == start.as_str() {
                            data.upgrade().map(Signal::Start)
                        } else if text == "received" {
                            Some(Signal::Received)
                        } else {
                            text.strip_prefix("ack:")
                                .and_then(|bytes| bytes.parse().ok())
                                .map(Signal::Ack)
                        };
                        if let Some(signal) = signal {
                            let _ = signals.try_send(signal);
                        }
                    }
                    Box::pin(async {})
                }));
            })
        }));

        let prepared = async {
            let mut gather = peer.gathering_complete_promise().await;
            peer.set_remote_description(RTCSessionDescription::offer(request.sdp)?)
                .await?;
            let answer = peer.create_answer(None).await?;
            peer.set_local_description(answer).await?;
            let _ = timeout(Duration::from_secs(4), gather.recv()).await?;
            let answer = peer
                .local_description()
                .await
                .context("missing connection answer")?
                .sdp;
            ensure!(
                answer.lines().any(|line| line.starts_with("a=candidate:")),
                "no available LAN interface"
            );
            Ok::<String, anyhow::Error>(answer)
        }
        .await;
        let answer = match prepared {
            Ok(answer) => answer,
            Err(error) => {
                let _ = peer.close().await;
                return Err(error);
            }
        };

        let shutdown = self.browser_share_shutdown.clone();
        tokio::spawn(async move {
            let _permit = permit;
            tokio::select! {
                _ = shutdown.cancelled() => {}
                result = send_file(file, request.size, request.blake3_hash.as_deref(), incoming) => {
                    if let Err(error) = result {
                        tracing::debug!(%error, "browser share ended before receipt");
                    }
                }
            }
            let _ = peer.close().await;
        });
        Ok(answer)
    }
}

fn lan_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_link_local(),
        IpAddr::V6(ip) => ip.is_unique_local() || ip.is_unicast_link_local(),
    }
}

async fn signal(rx: &mut mpsc::Receiver<Signal>, wait: Duration) -> anyhow::Result<Signal> {
    match timeout(wait, rx.recv()).await? {
        Some(Signal::Closed) | None => anyhow::bail!("browser disconnected"),
        Some(other) => Ok(other),
    }
}

async fn send_file(
    mut file: File,
    size: u64,
    expected_hash: Option<&str>,
    mut incoming: mpsc::Receiver<Signal>,
) -> anyhow::Result<()> {
    let Signal::Start(channel) = signal(&mut incoming, Duration::from_secs(25)).await? else {
        anyhow::bail!("missing browser download grant")
    };
    let mut sent = 0;
    let mut buffer = vec![0; CHUNK];
    let mut hash = blake3::Hasher::new();
    while sent < size {
        let length = (size - sent).min(CHUNK as u64) as usize;
        file.read_exact(&mut buffer[..length]).await?;
        hash.update(&buffer[..length]);
        let written = timeout(
            IDLE,
            channel.send(&Bytes::copy_from_slice(&buffer[..length])),
        )
        .await??;
        ensure!(written == length, "short data channel write");
        sent += length as u64;
        if sent % WINDOW == 0 {
            ensure!(
                matches!(signal(&mut incoming, IDLE).await?, Signal::Ack(bytes) if bytes == sent),
                "browser did not acknowledge the transfer window"
            );
        }
    }
    ensure!(
        expected_hash.is_none_or(|expected| hash.finalize().to_hex().as_str() == expected),
        "shared file contents have changed"
    );
    timeout(IDLE, channel.send_text("done")).await??;
    ensure!(
        matches!(signal(&mut incoming, IDLE).await?, Signal::Received),
        "browser did not confirm the download"
    );
    Ok(())
}
