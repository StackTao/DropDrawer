use super::{DROPDRAWER_ALPN, P2pPathKind, detect_path_kind};
use iroh::{Endpoint, endpoint::Connection};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const RELAY_PROBE_DELAY: Duration = Duration::from_secs(6);
const RELAY_PROBE_WINDOW: Duration = Duration::from_secs(6);
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

    pub(super) fn schedule(self: &Arc<Self>, conn: &Connection) {
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
            let remote_id = match conn.upgrade() {
                Some(primary) if detect_path_kind(&primary) == P2pPathKind::Relay => {
                    primary.remote_id()
                }
                _ => return,
            };

            // Limit the extra QUIC handshake when several transfers are relayed.
            {
                let mut last_probe = probe.last_probe.lock().unwrap();
                if last_probe.is_some_and(|last| last.elapsed() < RELAY_PROBE_COOLDOWN) {
                    return;
                }
                *last_probe = Some(Instant::now());
            }
            // Adding a connection prompts iroh to retry hole punching. It shares
            // discovered paths across connections to a peer, so the original
            // stream can migrate without a second file request.
            let retry = async {
                if let Ok(_auxiliary) = probe.endpoint.connect(remote_id, DROPDRAWER_ALPN).await {
                    std::future::pending::<()>().await;
                }
            };
            tokio::select! {
                _ = conn.closed() => {}
                _ = tokio::time::timeout(RELAY_PROBE_WINDOW, retry) => {}
            }
        });
    }
}
