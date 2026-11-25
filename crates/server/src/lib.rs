pub mod auth;
pub mod db;
pub mod google_login;
pub mod routes;
pub mod state;
pub mod storage;

use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use protocol::WsEvent;

use crate::state::AppState;

/// Spawns the periodic background task that cleans up expired drawer items and their cloud blobs.
pub fn spawn_ttl_cleanup_task(state: Arc<AppState>, interval_secs: u64) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(interval_secs.max(10)));
        loop {
            ticker.tick().await;
            if let Err(err) = run_ttl_cleanup_once(&state).await {
                tracing::warn!("TTL cleanup cycle failed: {err}");
            }
        }
    });
}

pub async fn run_ttl_cleanup_once(state: &Arc<AppState>) -> anyhow::Result<usize> {
    let expired = state.db.list_expired_items(Utc::now())?;
    let mut cleaned = 0usize;
    for item in expired {
        if let (Some(backend_id), Some(storage_path)) =
            (item.storage_backend_id.as_deref(), item.storage_path.as_deref())
        {
            if let Ok(Some(backend)) = state.db.get_storage_backend(backend_id, &item.user_id) {
                if let Ok(provider) = state.build_storage_provider(&backend) {
                    if let Err(err) = provider.delete(storage_path).await {
                        tracing::warn!("failed deleting expired blob {}: {err}", storage_path);
                    }
                }
            }
        }
        if state.db.delete_drawer_item(&item.id, &item.user_id)? {
            state.broadcast_user(
                &item.user_id,
                WsEvent::ItemDeleted {
                    item_id: item.id.clone(),
                },
            );
            cleaned += 1;
        }
    }
    Ok(cleaned)
}
