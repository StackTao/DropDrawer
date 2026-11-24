use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use dashmap::DashMap;
use iroh::endpoint::{Connection, ConnectionError};
use protocol::{P2pPathKind, P2pTransferProgress};
use tokio::sync::oneshot;
use uuid::Uuid;

// Each pull opens a dedicated QUIC connection. This application close code
// distinguishes an intentional stop from a failure eligible for cloud fallback.
pub(super) const CANCEL_CODE: u32 = 0x4443;
// Auxiliary hole-punching connections close with this code so the acceptor
// can ignore them quietly instead of logging a spurious stream error.
pub(super) const PROBE_CODE: u32 = 0x4450;

#[derive(Debug, thiserror::Error)]
#[error("transfer cancelled")]
pub(super) struct Cancelled;

const MAX_BUFFERED_EVENTS: usize = 256;
const MAX_TERMINAL_EVENTS: usize = 1024;

#[derive(Default)]
pub(super) struct Transfers {
    cancellations: DashMap<String, oneshot::Sender<()>>,
    events: Mutex<VecDeque<P2pTransferProgress>>,
}

impl Transfers {
    pub fn begin(self: &Arc<Self>, item_id: String, sending_to: Option<String>) -> Transfer {
        let transfer_id = Uuid::new_v4().to_string();
        let (tx, cancel) = oneshot::channel();
        self.cancellations.insert(transfer_id.clone(), tx);
        Transfer {
            transfers: self.clone(),
            cancel,
            progress: P2pTransferProgress {
                transfer_id,
                item_id,
                sending_to,
                cancelled: false,
                bytes_transferred: 0,
                total_bytes: 0,
                speed_bps: 0,
                path_kind: P2pPathKind::Unknown,
                finished: false,
                saved_path: None,
                error: None,
            },
        }
    }

    pub fn cancel(&self, id: &str) {
        if let Some((_, tx)) = self.cancellations.remove(id) {
            let _ = tx.send(());
        }
    }

    pub fn report(&self, progress: &P2pTransferProgress) {
        let mut events = self.events.lock().unwrap_or_else(|e| e.into_inner());
        // Keep the latest live update per transfer while preserving terminal events.
        if !progress.finished {
            events.retain(|e| e.finished || e.transfer_id != progress.transfer_id);
        }
        events.push_back(progress.clone());
        while events.len() > MAX_BUFFERED_EVENTS {
            if let Some(idx) = events.iter().position(|e| !e.finished) {
                events.remove(idx);
            } else if events.len() > MAX_TERMINAL_EVENTS {
                events.pop_front();
            } else {
                break;
            }
        }
    }

    pub fn drain(&self) -> Vec<P2pTransferProgress> {
        self.events
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .drain(..)
            .collect()
    }
}

pub(super) struct Transfer {
    transfers: Arc<Transfers>,
    pub progress: P2pTransferProgress,
    pub cancel: oneshot::Receiver<()>,
}

impl Transfer {
    pub fn finish(&mut self, result: &anyhow::Result<()>) {
        self.progress.finished = true;
        self.progress.speed_bps = 0;
        if let Err(err) = result {
            self.progress.cancelled = err.is::<Cancelled>();
            if !self.progress.cancelled {
                self.progress.error = Some(err.to_string());
            }
        }
        self.transfers.report(&self.progress);
    }
}

impl Drop for Transfer {
    fn drop(&mut self) {
        self.transfers
            .cancellations
            .remove(&self.progress.transfer_id);
    }
}

pub(super) async fn while_connected<T>(
    conn: &Connection,
    cancel: &mut oneshot::Receiver<()>,
    operation: impl Future<Output = anyhow::Result<T>>,
) -> anyhow::Result<T> {
    tokio::select! {
        biased;
        _ = cancel => {
            conn.close(CANCEL_CODE.into(), b"transfer cancelled");
            Err(Cancelled.into())
        }
        result = operation => {
            if matches!(conn.close_reason(), Some(ConnectionError::ApplicationClosed(reason))
                if reason.error_code == CANCEL_CODE.into()) {
                return Err(Cancelled.into());
            }
            result
        }
    }
}
