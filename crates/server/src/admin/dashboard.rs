//! Overview statistics, system information, audit log and maintenance actions.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use super::{audit, internal_err, AdminSession, ApiResult};
use crate::db::{AdminBackendKindCount, AdminOverviewStats, AdminVersionCount, AuditEntry};
use crate::state::AppState;

#[derive(Debug, Serialize)]
pub(super) struct Overview {
    #[serde(flatten)]
    stats: AdminOverviewStats,
    online_connections: usize,
    online_users: usize,
    backend_kinds: Vec<AdminBackendKindCount>,
    recent_audit: Vec<AuditEntry>,
}

pub(super) async fn overview(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Overview>> {
    let online_users: HashSet<String> = state
        .connections
        .iter()
        .filter(|e| !e.value().is_closed())
        .map(|e| e.key().0.clone())
        .collect();
    Ok(Json(Overview {
        stats: state.db.admin_overview_stats().map_err(internal_err)?,
        online_connections: state.connections.len(),
        online_users: online_users.len(),
        backend_kinds: state.db.backend_kind_counts().map_err(internal_err)?,
        recent_audit: state.db.list_audit(8).map_err(internal_err)?,
    }))
}

#[derive(Debug, Serialize)]
pub(super) struct SystemInfo {
    version: &'static str,
    os: &'static str,
    arch: &'static str,
    uptime_secs: u64,
    database_bytes: u64,
    local_storage_dir: String,
    local_storage_bytes: Option<u64>,
    local_storage_files: Option<u64>,
    admin_token_hashed: bool,
    smtp_ready: bool,
    google_ready: bool,
}

pub(super) async fn system(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<SystemInfo>> {
    let dir = state.default_local_storage_dir.clone();
    let usage = tokio::task::spawn_blocking(move || dir_usage(&dir, 500_000))
        .await
        .ok()
        .flatten();
    let settings = state.runtime_settings();
    Ok(Json(SystemInfo {
        version: env!("CARGO_PKG_VERSION"),
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        uptime_secs: state.started_at.elapsed().as_secs(),
        database_bytes: state.db.database_size_bytes().map_err(internal_err)?,
        local_storage_dir: state.default_local_storage_dir.to_string_lossy().to_string(),
        local_storage_bytes: usage.map(|(bytes, _)| bytes),
        local_storage_files: usage.map(|(_, files)| files),
        admin_token_hashed: state.admin_auth.as_ref().is_some_and(|a| a.is_hashed()),
        smtp_ready: settings.smtp.is_usable() || state.has_custom_email_sender(),
        google_ready: state.google_login().is_some(),
    }))
}

/// Total bytes and file count below `root`; `None` if the walk exceeds `max_entries`.
fn dir_usage(root: &Path, max_entries: u64) -> Option<(u64, u64)> {
    let mut stack = vec![root.to_path_buf()];
    let (mut bytes, mut files, mut seen) = (0u64, 0u64, 0u64);
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            seen += 1;
            if seen > max_entries {
                return None;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else if meta.is_file() {
                bytes += meta.len();
                files += 1;
            }
        }
    }
    Some((bytes, files))
}

#[derive(Debug, Deserialize)]
pub(super) struct AuditQuery {
    #[serde(default = "default_audit_limit")]
    limit: u32,
}

fn default_audit_limit() -> u32 {
    300
}

pub(super) async fn audit_log(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Query(q): Query<AuditQuery>,
) -> ApiResult<Json<Vec<AuditEntry>>> {
    Ok(Json(state.db.list_audit(q.limit).map_err(internal_err)?))
}

pub(super) async fn cleanup_expired(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<serde_json::Value>> {
    let cleaned = crate::run_ttl_cleanup_once(&state)
        .await
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "maintenance.cleanup",
        None,
        Some(&format!("cleaned={cleaned}")),
    );
    Ok(Json(serde_json::json!({ "cleaned": cleaned })))
}

pub(super) async fn client_versions(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Vec<AdminVersionCount>>> {
    Ok(Json(state.db.client_version_counts().map_err(internal_err)?))
}
