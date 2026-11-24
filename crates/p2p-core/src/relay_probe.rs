use super::{DROPDRAWER_ALPN, P2pPathKind, detect_path_kind, transfers::PROBE_CODE};
use iroh::{Endpoint, EndpointAddr, endpoint::Connection};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

const RELAY_PROBE_DELAY: Duration = Duration::from_secs(6);
// A busy relay can delay even the auxiliary QUIC handshake.
const RELAY_PROBE_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const RELAY_PROBE_PATH_GRACE: Duration = Duration::from_secs(10);
const PATH_POLL_INTERVAL: Duration = Duration::from_millis(200);
const RELAY_PROBE_COOLDOWN: Duration = Duration::from_secs(10);

pub(super) struct RelayProbe {
    endpoint: Endpoint,
    last_probe: Mutex<Option<Instant>>,
}

impl RelayProbe {
    pub(super) fn new(endpoint: Endpoint) -> Self {
        Self {
            endpoint,
            last_probe: Mutex::new(None),
        }
    }

    pub(super) fn schedule(
        self: &Arc<Self>,
        conn: &Connection,
        remote_addr: Option<EndpointAddr>,
    ) {
        if detect_path_kind(conn) == P2pPathKind::Direct {
            return;
        }

        let conn = conn.weak_handle();
        let probe = self.clone();
        tokio::spawn(async move {
            tokio::select! {
                _ = conn.closed() => return,
                _ = tokio::time::sleep(RELAY_PROBE_DELAY) => {}
            }
            let target_addr = match conn.upgrade() {
                Some(primary) if detect_path_kind(&primary) == P2pPathKind::Relay => {
                    remote_addr.unwrap_or_else(|| EndpointAddr::from(primary.remote_id()))
                }
                _ => return,
            };

            // Keep only one auxiliary connection or handshake active per endpoint.
            let Ok(mut last_probe) = probe.last_probe.try_lock() else {
                return;
            };
            if last_probe.is_some_and(|last| last.elapsed() < RELAY_PROBE_COOLDOWN) {
                return;
            }
            *last_probe = Some(Instant::now());

            // Adding a connection prompts iroh to retry hole punching. It shares
            // discovered paths across connections to a peer, so the original
            // stream can migrate without a second file request.
            let mut auxiliary_conn: Option<Connection> = None;
            let retry = async {
                let connect = probe.endpoint.connect(target_addr, DROPDRAWER_ALPN);
                if let Ok(Ok(auxiliary)) =
                    tokio::time::timeout(RELAY_PROBE_CONNECT_TIMEOUT, connect).await
                {
                    auxiliary_conn = Some(auxiliary);
                    tokio::time::sleep(RELAY_PROBE_PATH_GRACE).await;
                }
            };
            let wait_for_direct = async {
                while conn
                    .upgrade()
                    .is_some_and(|primary| detect_path_kind(&primary) != P2pPathKind::Direct)
                {
                    tokio::time::sleep(PATH_POLL_INTERVAL).await;
                }
            };
            tokio::select! {
                _ = conn.closed() => {}
                _ = wait_for_direct => {}
                _ = retry => {}
            }
            if let Some(auxiliary) = auxiliary_conn {
                auxiliary.close(PROBE_CODE.into(), b"relay probe done");
            }
        });
    }
}
