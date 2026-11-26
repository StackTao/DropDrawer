//! Account management: status, sessions, per-user policy and the user's devices,
//! storage backends, drawer items and share links.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use super::{audit, internal_err, not_found, AdminSession, ApiResult};
use crate::auth::hash_password;
use crate::db::{AdminDeviceRow, AdminItemRow, AdminUserSummary, UserPolicy};
use crate::state::AppState;
use protocol::StorageBackendSummary;

const DETAIL_ITEM_LIMIT: u32 = 300;

fn online_devices(state: &AppState, user_id: &str) -> usize {
    state
        .connections
        .iter()
        .filter(|e| e.key().0 == user_id && !e.value().is_closed())
        .count()
}

fn require_user(state: &AppState, id: &str) -> ApiResult<AdminUserSummary> {
    let mut user = state
        .db
        .admin_user_summary(id)
        .map_err(internal_err)?
        .ok_or_else(|| not_found("user"))?;
    user.online_devices = online_devices(state, id);
    Ok(user)
}

pub(super) async fn list(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Vec<AdminUserSummary>>> {
    let mut users = state.db.list_users_admin_summary().map_err(internal_err)?;
    for user in &mut users {
        user.online_devices = online_devices(&state, &user.id);
    }
    Ok(Json(users))
}

#[derive(Debug, Serialize)]
pub(super) struct AdminShareBrief {
    code: String,
    title: Option<String>,
    has_passcode: bool,
    download_count: u64,
    max_downloads: Option<u64>,
    expires_at: Option<chrono::DateTime<chrono::Utc>>,
    created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Serialize)]
pub(super) struct UserDetail {
    user: AdminUserSummary,
    policy: UserPolicy,
    /// Local quota that actually applies (per-user override, else the server default).
    effective_local_quota_bytes: Option<u64>,
    devices: Vec<AdminDeviceRow>,
    backends: Vec<StorageBackendSummary>,
    items: Vec<AdminItemRow>,
    shares: Vec<AdminShareBrief>,
}

pub(super) async fn detail(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<Json<UserDetail>> {
    let user = require_user(&state, &id)?;
    let policy = state.db.user_policy(&id).map_err(internal_err)?;
    let devices = state
        .list_devices_with_presence(&id)
        .map_err(internal_err)?
        .into_iter()
        .map(|d| AdminDeviceRow {
            has_p2p: d.iroh_node_id.is_some(),
            app_version: d.app_version,
            id: d.id,
            name: d.name,
            platform: d.platform,
            online: d.online,
            last_seen_at: d.last_seen_at,
        })
        .collect();
    let backends = state
        .db
        .list_storage_backends(&id)
        .map_err(internal_err)?
        .iter()
        .map(|b| b.to_summary())
        .collect();
    let items = state
        .db
        .list_items_admin(&id, DETAIL_ITEM_LIMIT)
        .map_err(internal_err)?;
    let shares = state
        .db
        .list_share_links(&id)
        .map_err(internal_err)?
        .into_iter()
        .map(|s| AdminShareBrief {
            code: s.code,
            title: s.title,
            has_passcode: s.passcode_hash.is_some(),
            download_count: s.download_count,
            max_downloads: s.max_downloads,
            expires_at: s.expires_at,
            created_at: s.created_at,
        })
        .collect();
    Ok(Json(UserDetail {
        effective_local_quota_bytes: policy
            .local_quota_bytes
            .or_else(|| state.default_user_local_quota_bytes()),
        user,
        policy,
        devices,
        backends,
        items,
        shares,
    }))
}

#[derive(Debug, Deserialize)]
pub(super) struct SetUserDisabledRequest {
    disabled: bool,
}

pub(super) async fn set_disabled(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<SetUserDisabledRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let user = require_user(&state, &id)?;
    if !state
        .db
        .set_user_disabled(&id, req.disabled)
        .map_err(internal_err)?
    {
        return Err(not_found("user"));
    }
    if req.disabled {
        state.disconnect_user(&id);
    }
    let action = if req.disabled { "user.disable" } else { "user.enable" };
    audit(&state, &admin, action, Some(&user.username), None);
    Ok(Json(serde_json::json!({ "id": id, "disabled": req.disabled })))
}

#[derive(Debug, Deserialize)]
pub(super) struct AdminResetPasswordRequest {
    new_password: String,
}

pub(super) async fn reset_password(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<AdminResetPasswordRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    if req.new_password.len() < 6 {
        return Err((StatusCode::BAD_REQUEST, "密码长度至少 6 位".to_string()));
    }
    let user = require_user(&state, &id)?;
    let password = req.new_password;
    let hash = tokio::task::spawn_blocking(move || hash_password(&password))
        .await
        .map_err(internal_err)?
        .map_err(internal_err)?;
    if !state
        .db
        .update_user_password(&id, &hash)
        .map_err(internal_err)?
    {
        return Err(not_found("user"));
    }
    // Sessions opened with the old password end with it.
    state.db.bump_token_version(&id).map_err(internal_err)?;
    state.disconnect_user(&id);
    state.failed_logins.reset(&user.username.to_lowercase());
    audit(&state, &admin, "user.reset_password", Some(&user.username), None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

/// Revoke every session token of the user and drop their live connections.
pub(super) async fn sign_out(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let user = require_user(&state, &id)?;
    state.db.bump_token_version(&id).map_err(internal_err)?;
    state.disconnect_user(&id);
    audit(&state, &admin, "user.sign_out", Some(&user.username), None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn update_policy(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(mut policy): Json<UserPolicy>,
) -> ApiResult<Json<UserPolicy>> {
    let user = require_user(&state, &id)?;
    policy.local_quota_bytes = policy.local_quota_bytes.filter(|&v| v > 0);
    if policy.note.as_deref().is_some_and(|n| n.chars().count() > 500) {
        return Err((StatusCode::BAD_REQUEST, "备注最长 500 个字符".to_string()));
    }
    let before = state.db.user_policy(&id).map_err(internal_err)?;
    if !state.db.set_user_policy(&id, &policy).map_err(internal_err)? {
        return Err(not_found("user"));
    }
    let saved = state.db.user_policy(&id).map_err(internal_err)?;
    if saved != before {
        state.broadcast_user(&id, protocol::WsEvent::ConfigChanged);
        let detail = format!(
            "quota={:?} upload_blocked={} share_blocked={}",
            saved.local_quota_bytes, saved.upload_blocked, saved.share_blocked
        );
        audit(&state, &admin, "user.policy", Some(&user.username), Some(&detail));
    }
    Ok(Json(saved))
}

pub(super) async fn delete_user(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let user = require_user(&state, &id)?;
    state.disconnect_user(&id);
    let items = state.db.list_drawer_items(&id).map_err(internal_err)?;
    let mut failed = 0usize;
    for item in items {
        if state.delete_drawer_item(&id, &item.id).await.is_err() {
            failed += 1;
        }
    }
    if !state.db.delete_user(&id).map_err(internal_err)? {
        return Err(not_found("user"));
    }
    let detail = (failed > 0).then(|| format!("blob_delete_failures={failed}"));
    audit(&state, &admin, "user.delete", Some(&user.username), detail.as_deref());
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn revoke_shares(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let user = require_user(&state, &id)?;
    let revoked = state
        .db
        .delete_share_links_for_user(&id)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "user.revoke_shares",
        Some(&user.username),
        Some(&format!("count={revoked}")),
    );
    Ok(Json(serde_json::json!({ "revoked": revoked })))
}

pub(super) async fn remove_device(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path((id, device_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let user = require_user(&state, &id)?;
    let device = state
        .db
        .get_device(&device_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| not_found("device"))?;
    let key = (id.clone(), device_id.clone());
    state.connections.remove(&key);
    state.ready_files.remove(&key);
    state
        .db
        .remove_device_by_admin(&device_id, &id)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "device.remove",
        Some(&user.username),
        Some(&device.name),
    );
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn remove_backend(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path((id, backend_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let user = require_user(&state, &id)?;
    let backend = state
        .db
        .get_storage_backend(&backend_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| not_found("storage backend"))?;
    state
        .db
        .delete_storage_backend(&backend_id, &id)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "backend.remove",
        Some(&user.username),
        Some(&backend.name),
    );
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn remove_item(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path((id, item_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let user = require_user(&state, &id)?;
    let item = state
        .db
        .get_drawer_item(&item_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| not_found("item"))?;
    let deleted = state
        .delete_drawer_item(&id, &item_id)
        .await
        .map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                "无法删除云端文件，请稍后重试".to_string(),
            )
        })?;
    if !deleted {
        return Err(not_found("item"));
    }
    audit(&state, &admin, "item.remove", Some(&user.username), Some(&item.name));
    Ok(StatusCode::NO_CONTENT)
}
