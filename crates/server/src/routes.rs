use std::{sync::Arc, time::Duration as StdDuration};

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{header, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{Duration, Utc};
use futures_util::{SinkExt, StreamExt, TryStreamExt};
use protocol::{
    AuthResponse, CloudDownloadInfo, CreateBatchShareRequest, CreateDrawerItemRequest,
    CreateShareRequest, CreateStorageBackendRequest, DeviceInfo, DownloadPlan, DrawerItem,
    DrawerItemKind, LoginRequest, P2pSourceInfo, RegisterDeviceRequest, RegisterRequest,
    ShareLinkInfo, StorageBackendConfig, StorageBackendSummary, StorageHealthResponse,
    TransferMode, UploadPlan,
    WsClientCommand, WsEvent,
};
use serde::Deserialize;
use tokio::sync::mpsc;
use tower_http::cors::{Any, CorsLayer};
use uuid::Uuid;

use crate::auth::{create_jwt, decode_jwt, hash_password, verify_password, AuthUser};
use crate::db::DrawerItemRow;
use crate::state::AppState;
use crate::storage::DownloadResolution;

pub fn build_router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/health", get(health))
        .route("/privacy", get(crate::google_login::privacy_notice))
        // Auth
        .route("/api/auth/register", post(register))
        .route("/api/auth/login", post(login))
        .route("/api/auth/google/start", post(crate::google_login::start))
        .route("/api/auth/google/callback", get(crate::google_login::callback))
        .route("/api/auth/google/poll", post(crate::google_login::poll))
        // Devices
        .route("/api/devices", get(list_devices).post(register_device))
        // Storage backends & built-in OAuth helpers
        .route(
            "/api/storage",
            get(list_storage_backends).post(create_storage_backend),
        )
        .route("/api/storage/{id}", delete(delete_storage_backend))
        .route("/api/storage/{id}/health", post(check_storage_health))
        .route("/api/oauth/google/start", post(start_google_oauth))
        .route("/api/oauth/google/callback", get(google_oauth_callback))
        // Drawer items
        .route(
            "/api/drawer/items",
            get(list_drawer_items).post(create_drawer_item),
        )
        .route("/api/drawer/items/batch-delete", post(batch_delete_drawer_items))
        .route("/api/drawer/items/{id}", delete(delete_drawer_item))
        .route("/api/drawer/items/{id}/upload-plan", post(request_upload_plan))
        .route("/api/drawer/items/{id}/upload", put(stream_upload_item))
        .route(
            "/api/drawer/items/{id}/confirm-upload",
            post(confirm_direct_upload),
        )
        .route(
            "/api/drawer/items/{id}/download-plan",
            get(get_download_plan),
        )
        .route("/api/drawer/items/{id}/download", get(download_item_content))
        .route("/api/drawer/items/{id}/share", post(create_share_link))
        // Share link management (authenticated)
        .route("/api/shares", get(list_share_links).post(create_batch_share_link))
        .route("/api/shares/{code}", delete(delete_share_link))
        // Public share landing page & unauthenticated download API
        .route("/s/{code}", get(public_share_page))
        .route("/api/s/{code}/meta", get(public_share_meta))
        .route("/api/s/{code}/download", get(public_share_download))
        // Real-time WebSocket
        .route("/ws", get(ws_upgrade))
        .layer(cors)
        .with_state(state)
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "status": "ok", "service": "dropdrawer-server" }))
}

// ============================================================================
// Auth Handlers
// ============================================================================

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !state.registration_open() {
        return Err((
            StatusCode::FORBIDDEN,
            "registration is disabled on this server".to_string(),
        ));
    }
    let username = req.username.trim();
    if username.len() < 2 || req.password.len() < 6 {
        return Err((
            StatusCode::BAD_REQUEST,
            "username must be >= 2 chars and password >= 6 chars".to_string(),
        ));
    }

    if state
        .db
        .find_user_by_username(username)
        .map_err(internal_err)?
        .is_some()
    {
        return Err((StatusCode::CONFLICT, "username already exists".to_string()));
    }

    let hash = hash_password(&req.password).map_err(internal_err)?;
    let user_id = Uuid::new_v4().to_string();
    let user = state
        .db
        .create_user(&user_id, username, &hash)
        .map_err(internal_err)?;
    let token = create_jwt(&user.id, &user.username, &state.jwt_secret).map_err(internal_err)?;

    Ok(Json(AuthResponse { token, user }))
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let limit_key = req.username.trim().to_lowercase();
    if state.failed_logins.is_blocked(&limit_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "too many failed login attempts, try again later".to_string(),
        ));
    }
    let invalid = || {
        state.failed_logins.record_failure(&limit_key);
        (StatusCode::UNAUTHORIZED, "invalid credentials".to_string())
    };
    let user_rec = state
        .db
        .find_user_by_username(req.username.trim())
        .map_err(internal_err)?
        .ok_or_else(invalid)?;

    if !verify_password_blocking(&req.password, &user_rec.password_hash).await {
        return Err(invalid());
    }
    state.failed_logins.reset(&limit_key);

    let token =
        create_jwt(&user_rec.id, &user_rec.username, &state.jwt_secret).map_err(internal_err)?;
    Ok(Json(AuthResponse {
        token,
        user: protocol::UserProfile {
            id: user_rec.id,
            username: user_rec.username,
            created_at: user_rec.created_at,
        },
    }))
}

// ============================================================================
// Device Handlers
// ============================================================================

async fn register_device(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterDeviceRequest>,
) -> Result<Json<DeviceInfo>, (StatusCode, String)> {
    let _presence = state.presence_changes.lock().await;
    let mut device = state
        .db
        .upsert_device(
            req.device_id.as_deref(),
            &auth.user_id,
            &req.name,
            req.platform,
            req.iroh_node_id.as_deref(),
            req.iroh_relay_url.as_deref(),
            &req.direct_addrs,
        )
        .map_err(internal_err)?;
    device.online = state.is_device_online(&auth.user_id, &device.id);
    state.broadcast_user(&auth.user_id, WsEvent::DeviceUpdated(device.clone()));
    Ok(Json(device))
}

async fn list_devices(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeviceInfo>>, (StatusCode, String)> {
    let devices = state
        .list_devices_with_presence(&auth.user_id)
        .map_err(internal_err)?;
    Ok(Json(devices))
}

// ============================================================================
// Storage Backend Handlers
// ============================================================================

async fn list_storage_backends(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    let mut backends = state
        .db
        .list_storage_backends(&auth.user_id)
        .map_err(internal_err)?;
    if backends.is_empty() {
        let default_rec = state
            .resolve_backend(&auth.user_id, None)
            .map_err(internal_err)?;
        backends.push(default_rec);
    }
    Ok(Json(backends.iter().map(|b| b.to_summary()).collect()))
}

async fn create_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateStorageBackendRequest>,
) -> Result<Json<StorageBackendSummary>, (StatusCode, String)> {
    let id = Uuid::new_v4().to_string();
    let config = match req.config {
        // Server-local storage always lives in the caller's own directory under
        // `DROPDRAWER_LOCAL_STORAGE`; a client-chosen path would expose the server's disk.
        StorageBackendConfig::Local { max_bytes, .. } => StorageBackendConfig::Local {
            root_dir: state
                .user_local_storage_dir(&auth.user_id)
                .to_string_lossy()
                .to_string(),
            max_bytes,
        },
        other => other,
    };
    let rec = state
        .db
        .create_storage_backend(&id, &auth.user_id, &req.name, &config, req.is_default)
        .map_err(internal_err)?;
    Ok(Json(rec.to_summary()))
}

async fn delete_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let deleted = state
        .db
        .delete_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?;
    if !deleted {
        return Err((StatusCode::NOT_FOUND, "storage backend not found".to_string()));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn check_storage_health(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<StorageHealthResponse>, (StatusCode, String)> {
    let rec = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "storage backend not found".to_string()))?;

    let provider = state.build_storage_provider(&rec).map_err(internal_err)?;
    match provider.health_check().await {
        Ok(msg) => Ok(Json(StorageHealthResponse {
            ok: true,
            message: msg,
        })),
        Err(err) => Ok(Json(StorageHealthResponse {
            ok: false,
            message: err.to_string(),
        })),
    }
}

#[derive(Debug, Deserialize)]
struct GoogleOAuthStartRequest {
    name: String,
    client_id: String,
    client_secret: String,
    #[serde(default)]
    folder_id: String,
    #[serde(default)]
    is_default: bool,
    redirect_uri: String,
}

async fn start_google_oauth(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<GoogleOAuthStartRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let nonce = Uuid::new_v4().to_string();
    let folder_id = if req.folder_id.trim().is_empty() {
        "root".to_string()
    } else {
        req.folder_id.trim().to_string()
    };
    state.pending_google_oauth.insert(
        nonce.clone(),
        crate::state::PendingGoogleOAuth {
            user_id: auth.user_id,
            name: req.name.trim().to_string(),
            client_id: req.client_id.trim().to_string(),
            client_secret: req.client_secret.trim().to_string(),
            folder_id,
            is_default: req.is_default,
            redirect_uri: req.redirect_uri.trim().to_string(),
        },
    );

    let auth_url = format!(
        "https://accounts.google.com/o/oauth2/v2/auth?client_id={}&redirect_uri={}&response_type=code&scope={}&access_type=offline&prompt=consent&state={}",
        urlencoding::encode(req.client_id.trim()),
        urlencoding::encode(req.redirect_uri.trim()),
        urlencoding::encode("https://www.googleapis.com/auth/drive.file"),
        urlencoding::encode(&nonce)
    );

    Ok(Json(serde_json::json!({
        "auth_url": auth_url,
        "state": nonce,
    })))
}

#[derive(Debug, Deserialize)]
struct GoogleOAuthCallbackQuery {
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

async fn google_oauth_callback(
    State(state): State<Arc<AppState>>,
    Query(q): Query<GoogleOAuthCallbackQuery>,
) -> Html<String> {
    if let Some(err) = q.error {
        return Html(format!(
            "<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>授权已取消或失败</h2><p>{err}</p></body></html>"
        ));
    }
    let (Some(code), Some(nonce)) = (q.code, q.state) else {
        return Html("<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>缺少授权参数</h2></body></html>".to_string());
    };
    let Some((_, pending)) = state.pending_google_oauth.remove(&nonce) else {
        return Html("<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>授权会话已过期，请回到 DropDrawer 重新发起</h2></body></html>".to_string());
    };

    let resp = state
        .http
        .post("https://oauth2.googleapis.com/token")
        .form(&[
            ("code", code.as_str()),
            ("client_id", pending.client_id.as_str()),
            ("client_secret", pending.client_secret.as_str()),
            ("redirect_uri", pending.redirect_uri.as_str()),
            ("grant_type", "authorization_code"),
        ])
        .send()
        .await;

    let Ok(resp) = resp else {
        return Html("<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>无法连接 Google OAuth 服务器（请检查本机网络/代理）</h2></body></html>".to_string());
    };
    let status = resp.status();
    let body_text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Html(format!(
            "<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>换取 Token 失败 ({status})</h2><pre>{body_text}</pre></body></html>"
        ));
    }

    let parsed: serde_json::Value = serde_json::from_str(&body_text).unwrap_or_default();
    let Some(refresh_token) = parsed["refresh_token"].as_str().filter(|s| !s.is_empty()) else {
        return Html(format!(
            "<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>未返回 refresh_token</h2><p>请确保授权页面勾选同意权限。</p><pre>{body_text}</pre></body></html>"
        ));
    };

    let cfg = protocol::StorageBackendConfig::GoogleDrive {
        client_id: pending.client_id,
        client_secret: pending.client_secret,
        refresh_token: refresh_token.to_string(),
        folder_id: pending.folder_id,
        api_base_url: None,
        token_url: None,
    };
    let backend_id = Uuid::new_v4().to_string();
    if let Err(err) = state.db.create_storage_backend(
        &backend_id,
        &pending.user_id,
        &pending.name,
        &cfg,
        pending.is_default,
    ) {
        return Html(format!(
            "<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:40px'><h2>保存存储配置失败</h2><p>{err}</p></body></html>"
        ));
    }

    Html("<html><body style='font-family:-apple-system,sans-serif;background:#161618;color:#f5f5f7;padding:48px;text-align:center'><h2>Google Drive 已成功绑定到 DropDrawer</h2><p style='color:#a1a1aa'>可以关闭此页面，回到 DropDrawer 点击刷新即可使用。</p></body></html>".to_string())
}

// ============================================================================
// Drawer Item Handlers
// ============================================================================

async fn list_drawer_items(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DrawerItem>>, (StatusCode, String)> {
    let items = state
        .list_hydrated_items(&auth.user_id)
        .map_err(internal_err)?;
    Ok(Json(items))
}

async fn create_drawer_item(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateDrawerItemRequest>,
) -> Result<Json<DrawerItem>, (StatusCode, String)> {
    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let expires_at = req
        .ttl_hours
        .map(|h| now + Duration::hours(h as i64))
        .or_else(|| Some(now + Duration::days(7)));

    let is_text = req.kind == protocol::DrawerItemKind::Text;
    let row = DrawerItemRow {
        id: id.clone(),
        user_id: auth.user_id.clone(),
        owner_device_id: req.device_id,
        kind: req.kind,
        name: req.name,
        size: req.size,
        mime_type: req.mime_type,
        blake3_hash: req.blake3_hash,
        text_content: req.text_content,
        thumbnail_base64: req.thumbnail_base64,
        transfer_mode: req.transfer_mode,
        storage_backend_id: req.storage_backend_id,
        storage_path: None,
        cloud_ready: is_text,
        expires_at,
        created_at: now,
    };

    state.db.create_drawer_item(&row).map_err(internal_err)?;
    let hydrated = state
        .hydrate_single_item(&auth.user_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, "item missing".to_string()))?;

    state.broadcast_user(&auth.user_id, WsEvent::ItemAdded(hydrated.clone()));
    Ok(Json(hydrated))
}

async fn delete_drawer_item(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let deleted = state
        .delete_drawer_item(&auth.user_id, &id)
        .await
        .map_err(|_| {
            tracing::warn!(item_id = %id, "drawer resource deletion failed");
            (
                StatusCode::BAD_GATEWAY,
                "could not delete drawer resource; retry later".to_string(),
            )
        })?;
    if !deleted {
        return Err((StatusCode::NOT_FOUND, "item not found".to_string()));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
struct BatchDeleteRequest {
    #[serde(default)]
    item_ids: Vec<String>,
    #[serde(default)]
    clear_all: bool,
}

async fn batch_delete_drawer_items(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<BatchDeleteRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let mut targets = if req.clear_all {
        state
            .db
            .list_drawer_items(&auth.user_id)
            .map_err(internal_err)?
            .into_iter()
            .map(|item| item.id)
            .collect()
    } else {
        req.item_ids
    };
    let mut seen = std::collections::HashSet::with_capacity(targets.len());
    targets.retain(|id| seen.insert(id.clone()));

    let mut deleted_ids = Vec::with_capacity(targets.len());
    let mut failed_ids = Vec::new();
    for id in targets {
        match state.delete_drawer_item(&auth.user_id, &id).await {
            Ok(true) => deleted_ids.push(id),
            Ok(false) => {}
            Err(_) => {
                tracing::warn!(item_id = %id, "drawer resource deletion failed");
                failed_ids.push(id);
            }
        }
    }

    Ok(Json(serde_json::json!({
        "deleted": deleted_ids.len(),
        "item_ids": deleted_ids,
        "failed_item_ids": failed_ids,
    })))
}

#[derive(Debug, Deserialize)]
struct UploadPlanRequest {
    #[serde(default)]
    storage_backend_id: Option<String>,
}

async fn request_upload_plan(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UploadPlanRequest>,
) -> Result<Json<UploadPlan>, (StatusCode, String)> {
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;

    let backend_id = req
        .storage_backend_id
        .as_deref()
        .or(item.storage_backend_id.as_deref());
    let backend = state
        .resolve_backend(&auth.user_id, backend_id)
        .map_err(internal_err)?;
    let provider = state.build_storage_provider(&backend).map_err(internal_err)?;

    let remote_key = item_storage_key(&auth.user_id, &item.id, &item.name);

    if let Some(presigned) = provider.presign_upload(&remote_key, 1800) {
        return Ok(Json(UploadPlan::DirectPresignedPut {
            url: presigned.url,
            headers: presigned.headers,
            storage_backend_id: backend.id,
            remote_key,
        }));
    }

    Ok(Json(UploadPlan::ServerStreamPut {
        url: format!(
            "/api/drawer/items/{}/upload?storage_backend_id={}",
            item.id, backend.id
        ),
        storage_backend_id: backend.id,
    }))
}

#[derive(Debug, Deserialize)]
struct UploadQuery {
    #[serde(default)]
    storage_backend_id: Option<String>,
}

async fn stream_upload_item(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<UploadQuery>,
    headers: axum::http::HeaderMap,
    body: Body,
) -> Result<Json<DrawerItem>, (StatusCode, String)> {
    let _item_lock = state.lock_drawer_item(&id).await;
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;

    let backend = state
        .resolve_backend(
            &auth.user_id,
            query
                .storage_backend_id
                .as_deref()
                .or(item.storage_backend_id.as_deref()),
        )
        .map_err(internal_err)?;
    let provider = state.build_storage_provider(&backend).map_err(internal_err)?;

    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .or(if item.size > 0 { Some(item.size) } else { None });

    let remote_key = item_storage_key(&auth.user_id, &item.id, &item.name);

    let stream = body
        .into_data_stream()
        .map_err(|e| anyhow::anyhow!("request body stream error: {e}"));

    let put_res = provider
        .put_stream(&remote_key, content_length, Box::pin(stream))
        .await
        .map_err(internal_err)?;

    state
        .db
        .mark_item_cloud_ready(
            &item.id,
            &auth.user_id,
            &backend.id,
            &put_res.stored_key,
            Some(put_res.bytes_written),
            None,
        )
        .map_err(internal_err)?;

    let hydrated = state
        .hydrate_single_item(&auth.user_id, &item.id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item vanished".to_string()))?;

    state.broadcast_user(&auth.user_id, WsEvent::ItemUpdated(hydrated.clone()));
    Ok(Json(hydrated))
}

/// Storage key for an item's cached blob. Always derived server-side.
fn item_storage_key(user_id: &str, item_id: &str, name: &str) -> String {
    format!("{user_id}/{item_id}_{}", sanitize_filename(name))
}

#[derive(Debug, Deserialize)]
struct ConfirmUploadRequest {
    storage_backend_id: String,
    remote_key: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    blake3_hash: Option<String>,
}

async fn confirm_direct_upload(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ConfirmUploadRequest>,
) -> Result<Json<DrawerItem>, (StatusCode, String)> {
    let _item_lock = state.lock_drawer_item(&id).await;
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;
    let backend = state
        .db
        .get_storage_backend(&req.storage_backend_id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "storage backend not found".to_string()))?;
    // Only presigned direct uploads are confirmed by the client, and only for the
    // exact key the server handed out in the upload plan.
    if matches!(backend.config, StorageBackendConfig::Local { .. })
        || req.remote_key != item_storage_key(&auth.user_id, &item.id, &item.name)
    {
        return Err((
            StatusCode::BAD_REQUEST,
            "remote_key does not match the upload plan for this item".to_string(),
        ));
    }
    let ok = state
        .db
        .mark_item_cloud_ready(
            &id,
            &auth.user_id,
            &req.storage_backend_id,
            &req.remote_key,
            req.size,
            req.blake3_hash.as_deref(),
        )
        .map_err(internal_err)?;
    if !ok {
        return Err((StatusCode::NOT_FOUND, "item not found".to_string()));
    }
    let hydrated = state
        .hydrate_single_item(&auth.user_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;
    state.broadcast_user(&auth.user_id, WsEvent::ItemUpdated(hydrated.clone()));
    Ok(Json(hydrated))
}

#[derive(Debug, Deserialize)]
struct DownloadPlanQuery {
    #[serde(default)]
    requester_device_id: Option<String>,
}

async fn get_download_plan(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<DownloadPlanQuery>,
) -> Result<Json<DownloadPlan>, (StatusCode, String)> {
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;

    let mut p2p = None;
    if item.transfer_mode != TransferMode::CloudCached
        && state.is_device_online(&auth.user_id, &item.owner_device_id)
    {
        if let Ok(Some(owner_dev)) = state.db.get_device(&item.owner_device_id, &auth.user_id) {
            if let Some(node_id) = owner_dev.iroh_node_id {
                let token = Uuid::new_v4().to_string();
                let expires_at = Utc::now() + Duration::minutes(10);
                let requester_node_id = query.requester_device_id.as_deref().and_then(|id| {
                    state
                        .db
                        .get_device(id, &auth.user_id)
                        .ok()
                        .flatten()
                        .and_then(|d| d.iroh_node_id)
                });
                // Pre-authorize this single-use transfer token on the source device over
                // WebSocket. If the push cannot be queued the source would reject the
                // pull, so only offer P2P when it was.
                let pushed = state.send_to_device(
                    &auth.user_id,
                    &item.owner_device_id,
                    WsEvent::AuthorizeP2pToken {
                        item_id: item.id.clone(),
                        token: token.clone(),
                        requester_device_id: query
                            .requester_device_id
                            .clone()
                            .unwrap_or_else(|| "unknown".to_string()),
                        expires_at,
                        requester_node_id,
                    },
                );
                p2p = pushed.then(|| P2pSourceInfo {
                    device_id: owner_dev.id,
                    iroh_node_id: node_id,
                    iroh_relay_url: owner_dev.iroh_relay_url,
                    direct_addrs: owner_dev.direct_addrs,
                    transfer_token: token,
                });
            }
        }
    }

    let mut cloud = None;
    if item.cloud_ready {
        if let (Some(backend_id), Some(storage_path)) =
            (item.storage_backend_id.as_deref(), item.storage_path.as_deref())
        {
            if let Some(backend) = state
                .db
                .get_storage_backend(backend_id, &auth.user_id)
                .map_err(internal_err)?
            {
                let provider = state.build_storage_provider(&backend).map_err(internal_err)?;
                match provider.resolve_download(storage_path).await {
                    Ok(DownloadResolution::DirectUrl(url)) => {
                        cloud = Some(CloudDownloadInfo {
                            url,
                            is_direct_url: true,
                            backend_name: backend.name,
                        });
                    }
                    Ok(DownloadResolution::Stream { .. }) => {
                        cloud = Some(CloudDownloadInfo {
                            url: format!("/api/drawer/items/{}/download", item.id),
                            is_direct_url: false,
                            backend_name: backend.name,
                        });
                    }
                    Err(err) => {
                        tracing::warn!("cloud download resolution failed for {}: {err}", item.id);
                    }
                }
            }
        }
    }

    Ok(Json(DownloadPlan {
        item_id: item.id,
        p2p,
        cloud,
    }))
}

async fn download_item_content(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Response, (StatusCode, String)> {
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "item not found".to_string()))?;

    let (Some(backend_id), Some(storage_path)) =
        (item.storage_backend_id.as_deref(), item.storage_path.as_deref())
    else {
        return Err((
            StatusCode::BAD_REQUEST,
            "item is not cached on cloud storage".to_string(),
        ));
    };

    let backend = state
        .db
        .get_storage_backend(backend_id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "storage backend not found".to_string()))?;
    let provider = state.build_storage_provider(&backend).map_err(internal_err)?;

    match provider
        .resolve_download(storage_path)
        .await
        .map_err(internal_err)?
    {
        DownloadResolution::DirectUrl(url) => Ok(Redirect::temporary(&url).into_response()),
        DownloadResolution::Stream {
            stream,
            content_length,
            content_type,
        } => {
            let mut builder = Response::builder().status(StatusCode::OK);
            let ct = content_type.unwrap_or_else(|| "application/octet-stream".to_string());
            builder = builder.header(header::CONTENT_TYPE, ct);
            if let Some(len) = content_length {
                builder = builder.header(header::CONTENT_LENGTH, len.to_string());
            }
            let encoded_name = urlencoding::encode(&item.name);
            builder = builder.header(
                header::CONTENT_DISPOSITION,
                format!("attachment; filename*=UTF-8''{encoded_name}"),
            );
            let body = Body::from_stream(stream);
            builder.body(body).map_err(internal_err)
        }
    }
}

// ============================================================================
// Public Share Link Handlers
// ============================================================================

async fn create_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<CreateShareRequest>,
) -> Result<Json<ShareLinkInfo>, (StatusCode, String)> {
    create_share_for_items(
        &state,
        &auth.user_id,
        vec![id],
        None,
        req.passcode,
        req.expires_hours,
        req.max_downloads,
    )
    .map(Json)
}

async fn create_batch_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateBatchShareRequest>,
) -> Result<Json<ShareLinkInfo>, (StatusCode, String)> {
    create_share_for_items(
        &state,
        &auth.user_id,
        req.item_ids,
        req.title,
        req.passcode,
        req.expires_hours,
        req.max_downloads,
    )
    .map(Json)
}

fn format_share_display_name(custom_title: Option<&str>, items: &[DrawerItemRow]) -> String {
    if let Some(t) = custom_title.map(str::trim).filter(|s| !s.is_empty()) {
        return t.to_string();
    }
    if items.len() == 1 {
        return items[0].name.clone();
    }
    format!("{} 等 {} 项", items[0].name, items.len())
}

fn create_share_for_items(
    state: &Arc<AppState>,
    user_id: &str,
    raw_item_ids: Vec<String>,
    title: Option<String>,
    passcode: Option<String>,
    expires_hours: Option<u64>,
    max_downloads: Option<u64>,
) -> Result<ShareLinkInfo, (StatusCode, String)> {
    let mut unique_ids = Vec::new();
    for id in raw_item_ids {
        if !unique_ids.contains(&id) {
            unique_ids.push(id);
        }
    }
    if unique_ids.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "请至少选择一个文件或文本条目".to_string(),
        ));
    }

    let mut items = Vec::with_capacity(unique_ids.len());
    for id in &unique_ids {
        let item = state
            .db
            .get_drawer_item(id, user_id)
            .map_err(internal_err)?
            .ok_or_else(|| (StatusCode::NOT_FOUND, "drawer item not found".to_string()))?;

        if item.kind == DrawerItemKind::File && !item.cloud_ready {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("文件「{}」尚未上传到云盘/服务器，请先转存云端后再创建外链", item.name),
            ));
        }
        items.push(item);
    }

    let code = generate_short_code();
    let passcode_hash = passcode
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(hash_password)
        .transpose()
        .map_err(internal_err)?;

    let clean_title = title
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string);

    let now = Utc::now();
    let expires_at = expires_hours
        .filter(|&h| h > 0)
        .map(|h| now + Duration::hours(h as i64));

    let primary_item_id = items[0].id.clone();
    let display_name = format_share_display_name(clean_title.as_deref(), &items);
    let total_size: u64 = items.iter().map(|it| it.size).sum();
    let item_count = items.len() as u64;
    let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
        DrawerItemKind::File
    } else {
        DrawerItemKind::Text
    };

    let row = crate::db::ShareLinkRow {
        code: code.clone(),
        user_id: user_id.to_string(),
        item_id: primary_item_id.clone(),
        title: clean_title,
        passcode_hash: passcode_hash.clone(),
        max_downloads: max_downloads.filter(|&n| n > 0),
        download_count: 0,
        expires_at,
        created_at: now,
    };
    state
        .db
        .create_share_link(&row, &unique_ids)
        .map_err(internal_err)?;

    Ok(ShareLinkInfo {
        code: code.clone(),
        item_id: primary_item_id,
        item_name: display_name,
        item_kind: primary_kind,
        item_size: total_size,
        item_count,
        has_passcode: passcode_hash.is_some(),
        max_downloads: row.max_downloads,
        download_count: 0,
        expires_at,
        created_at: now,
        share_path: format!("/s/{code}"),
    })
}

async fn list_share_links(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ShareLinkInfo>>, (StatusCode, String)> {
    let rows = state
        .db
        .list_share_links(&auth.user_id)
        .map_err(internal_err)?;
    let mut out = Vec::new();
    for r in rows {
        let items = state
            .db
            .get_share_link_items(&r.code, &r.item_id)
            .map_err(internal_err)?;
        if items.is_empty() {
            continue;
        }
        let display_name = format_share_display_name(r.title.as_deref(), &items);
        let total_size: u64 = items.iter().map(|it| it.size).sum();
        let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
            DrawerItemKind::File
        } else {
            DrawerItemKind::Text
        };
        out.push(ShareLinkInfo {
            share_path: format!("/s/{}", r.code),
            code: r.code,
            item_id: items[0].id.clone(),
            item_name: display_name,
            item_kind: primary_kind,
            item_size: total_size,
            item_count: items.len() as u64,
            has_passcode: r.passcode_hash.is_some(),
            max_downloads: r.max_downloads,
            download_count: r.download_count,
            expires_at: r.expires_at,
            created_at: r.created_at,
        });
    }
    Ok(Json(out))
}

async fn delete_share_link(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let ok = state
        .db
        .delete_share_link(&code, &auth.user_id)
        .map_err(internal_err)?;
    if !ok {
        return Err((StatusCode::NOT_FOUND, "share link not found".to_string()));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
struct PublicShareQuery {
    #[serde(default)]
    passcode: Option<String>,
    #[serde(default)]
    item_id: Option<String>,
}

/// Runs Argon2 verification off the async worker threads.
async fn verify_password_blocking(password: &str, hash: &str) -> bool {
    let (password, hash) = (password.to_string(), hash.to_string());
    tokio::task::spawn_blocking(move || verify_password(&password, &hash))
        .await
        .unwrap_or(false)
}

/// Whether `passcode` unlocks `share`. Failed attempts are rate limited per share code.
async fn share_unlocked(
    state: &AppState,
    share: &crate::db::ShareLinkRow,
    passcode: Option<&str>,
) -> Result<bool, (StatusCode, String)> {
    let Some(ref hash) = share.passcode_hash else {
        return Ok(true);
    };
    let provided = passcode.unwrap_or("").trim();
    if provided.is_empty() {
        return Ok(false);
    }
    if state.failed_passcodes.is_blocked(&share.code) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "提取码尝试次数过多，请稍后再试".to_string(),
        ));
    }
    if verify_password_blocking(provided, hash).await {
        Ok(true)
    } else {
        state.failed_passcodes.record_failure(&share.code);
        Ok(false)
    }
}

async fn validate_share_access(
    state: &AppState,
    share: &crate::db::ShareLinkRow,
    passcode: Option<&str>,
) -> Result<(), (StatusCode, String)> {
    if let Some(exp) = share.expires_at {
        if exp <= Utc::now() {
            return Err((StatusCode::GONE, "该分享链接已过期".to_string()));
        }
    }
    if let Some(max) = share.max_downloads {
        if share.download_count >= max {
            return Err((StatusCode::GONE, "该分享链接已达到下载次数上限".to_string()));
        }
    }
    if !share_unlocked(state, share, passcode).await? {
        return Err((StatusCode::FORBIDDEN, "需要正确的提取码".to_string()));
    }
    Ok(())
}

async fn public_share_meta(
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let share = state
        .db
        .get_share_link(&code)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "分享链接不存在或已被撤销".to_string()))?;

    if let Some(exp) = share.expires_at {
        if exp <= Utc::now() {
            return Err((StatusCode::GONE, "该分享链接已过期".to_string()));
        }
    }
    if let Some(max) = share.max_downloads {
        if share.download_count >= max {
            return Err((StatusCode::GONE, "该分享链接已达到下载次数上限".to_string()));
        }
    }

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, "关联文件已被删除".to_string()));
    }

    let locked = !share_unlocked(&state, &share, query.passcode.as_deref()).await?;

    let display_name = format_share_display_name(share.title.as_deref(), &items);
    let total_size: u64 = items.iter().map(|it| it.size).sum();
    let primary_kind = if items.iter().any(|it| it.kind == DrawerItemKind::File) {
        DrawerItemKind::File
    } else {
        DrawerItemKind::Text
    };
    let single_text = if !locked && items.len() == 1 && items[0].kind == DrawerItemKind::Text {
        items[0].text_content.clone()
    } else {
        None
    };

    let serialized_items: Vec<serde_json::Value> = items
        .iter()
        .map(|it| {
            serde_json::json!({
                "id": it.id,
                "name": it.name,
                "kind": it.kind,
                "size": it.size,
                "text_content": if !locked && it.kind == DrawerItemKind::Text {
                    it.text_content.clone()
                } else {
                    None
                },
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "code": share.code,
        "name": display_name,
        "kind": primary_kind,
        "size": total_size,
        "item_count": items.len(),
        "items": serialized_items,
        "locked": locked,
        "has_passcode": share.passcode_hash.is_some(),
        "download_count": share.download_count,
        "max_downloads": share.max_downloads,
        "expires_at": share.expires_at,
        "text_content": single_text,
    })))
}

async fn public_share_download(
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Response, (StatusCode, String)> {
    let share = state
        .db
        .get_share_link(&code)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "分享链接不存在或已被撤销".to_string()))?;

    validate_share_access(&state, &share, query.passcode.as_deref()).await?;

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, "关联文件已被删除".to_string()));
    }

    let item = if let Some(ref target_id) = query.item_id {
        items
            .into_iter()
            .find(|it| &it.id == target_id)
            .ok_or_else(|| (StatusCode::NOT_FOUND, "所请求的文件不在该分享中".to_string()))?
    } else {
        items.into_iter().next().unwrap()
    };

    if item.kind == DrawerItemKind::Text {
        if !state
            .db
            .increment_share_download(&code)
            .map_err(internal_err)?
        {
            return Err((StatusCode::GONE, "该分享链接已达到下载次数上限".to_string()));
        }
        let text = item.text_content.unwrap_or_default();
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
            .body(Body::from(text))
            .map_err(internal_err);
    }

    let (Some(backend_id), Some(storage_path)) =
        (item.storage_backend_id.as_deref(), item.storage_path.as_deref())
    else {
        return Err((StatusCode::BAD_REQUEST, "文件尚未缓存到云端".to_string()));
    };

    let backend = state
        .db
        .get_storage_backend(backend_id, &item.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, "存储策略不存在".to_string()))?;

    let provider = state.build_storage_provider(&backend).map_err(internal_err)?;
    let incremented = state
        .db
        .increment_share_download(&code)
        .map_err(internal_err)?;
    if !incremented {
        return Err((StatusCode::GONE, "该分享链接已达到下载次数上限".to_string()));
    }

    match provider
        .resolve_download(storage_path)
        .await
        .map_err(internal_err)?
    {
        DownloadResolution::DirectUrl(url) => Ok(Redirect::temporary(&url).into_response()),
        DownloadResolution::Stream {
            stream,
            content_length,
            content_type,
        } => {
            let mut builder = Response::builder().status(StatusCode::OK);
            let ct = content_type.unwrap_or_else(|| "application/octet-stream".to_string());
            builder = builder.header(header::CONTENT_TYPE, ct);
            if let Some(len) = content_length {
                builder = builder.header(header::CONTENT_LENGTH, len.to_string());
            }
            let encoded_name = urlencoding::encode(&item.name);
            builder = builder.header(
                header::CONTENT_DISPOSITION,
                format!("attachment; filename*=UTF-8''{encoded_name}"),
            );
            let body = Body::from_stream(stream);
            builder.body(body).map_err(internal_err)
        }
    }
}

async fn public_share_page(Path(code): Path<String>) -> Html<String> {
    let safe_code = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect::<String>();
    Html(PUBLIC_SHARE_HTML.replace("__SHARE_CODE__", &safe_code))
}

fn generate_short_code() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let bytes = *Uuid::new_v4().as_bytes();
    (0..8)
        .map(|i| ALPHABET[(bytes[i] as usize) % ALPHABET.len()] as char)
        .collect()
}

const PUBLIC_SHARE_HTML: &str = r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>DropDrawer 外链提取</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: radial-gradient(circle at top, #1f2430 0%, #0e1015 70%);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    color: #f5f5f7; padding: 20px;
  }
  .card {
    width: 100%; max-width: 480px; background: rgba(28, 28, 32, 0.88);
    border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 18px;
    padding: 26px 24px; backdrop-filter: blur(24px);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.5);
  }
  .brand { display: flex; align-items: center; gap: 10px; margin-bottom: 18px; }
  .logo {
    width: 30px; height: 30px; border-radius: 8px;
    background: linear-gradient(135deg, #38bdf8, #2563eb);
    display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 14px;
  }
  .brand span { font-size: 14px; font-weight: 600; color: rgba(245,245,247,0.9); }
  .name { font-size: 17px; font-weight: 600; word-break: break-all; margin: 0 0 6px; }
  .meta { font-size: 12.5px; color: rgba(235,235,245,0.55); margin-bottom: 18px; }
  .input-row { display: flex; gap: 8px; margin-bottom: 14px; }
  input {
    flex: 1; background: rgba(0,0,0,0.32); border: 1px solid rgba(255,255,255,0.14);
    border-radius: 10px; padding: 10px 12px; color: #fff; font-size: 14px; outline: none;
  }
  input:focus { border-color: #0a84ff; }
  button, a.btn {
    display: inline-flex; align-items: center; justify-content: center; width: 100%;
    height: 40px; border-radius: 10px; border: none; cursor: pointer;
    font-size: 13.5px; font-weight: 600; text-decoration: none;
    background: #f5f5f7; color: #111113; transition: opacity .15s;
  }
  button.secondary, a.mini-btn {
    background: rgba(255,255,255,0.1); color: #f5f5f7; width: auto; padding: 0 12px;
    height: 30px; font-size: 12px; border-radius: 8px; text-decoration: none;
    display: inline-flex; align-items: center; justify-content: center; border: none; cursor: pointer;
    flex-shrink: 0;
  }
  button:hover, a.btn:hover, a.mini-btn:hover { opacity: 0.88; }
  pre.text-box {
    background: rgba(0,0,0,0.32); border: 1px solid rgba(255,255,255,0.1);
    border-radius: 10px; padding: 12px; white-space: pre-wrap; word-break: break-word;
    max-height: 240px; overflow: auto; font-size: 13px; margin: 0 0 14px;
  }
  .bundle-list {
    display: flex; flex-direction: column; gap: 8px;
    max-height: 320px; overflow-y: auto; margin-bottom: 16px;
  }
  .bundle-row {
    display: flex; align-items: center; gap: 10px; padding: 10px 12px;
    background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08);
    border-radius: 11px;
  }
  .bundle-info { flex: 1; min-width: 0; }
  .bundle-title {
    font-size: 13px; font-weight: 500; white-space: nowrap;
    overflow: hidden; text-overflow: ellipsis;
  }
  .bundle-sub { font-size: 11.5px; color: rgba(235,235,245,0.5); margin-top: 2px; }
  .err { color: #ff453a; font-size: 12.5px; margin-top: 8px; }
</style>
</head>
<body>
<div class="card">
  <div class="brand"><div class="logo">D</div><span>DropDrawer 外链分享</span></div>
  <div id="app">正在加载分享信息...</div>
</div>
<script>
const code = "__SHARE_CODE__";
let currentPasscode = new URLSearchParams(location.search).get("p") || "";

function fmtBytes(b) {
  if (b < 1024) return b + " B";
  if (b < 1048576) return (b / 1024).toFixed(1) + " KB";
  if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB";
  return (b / 1073741824).toFixed(2) + " GB";
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, m => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
}

function buildDlUrl(itemId) {
  const params = new URLSearchParams();
  if (itemId) params.set("item_id", itemId);
  if (currentPasscode) params.set("passcode", currentPasscode);
  const qs = params.toString();
  return "/api/s/" + encodeURIComponent(code) + "/download" + (qs ? ("?" + qs) : "");
}

async function load(errMsg) {
  const q = currentPasscode ? ("?passcode=" + encodeURIComponent(currentPasscode)) : "";
  const resp = await fetch("/api/s/" + encodeURIComponent(code) + "/meta" + q);
  const el = document.getElementById("app");
  if (!resp.ok) {
    const t = await resp.text();
    el.innerHTML = `<p class="name">无法访问该分享</p><p class="err">${esc(t || resp.statusText)}</p>`;
    return;
  }
  const d = await resp.json();
  const items = Array.isArray(d.items) ? d.items : [];
  const countInfo = items.length > 1 ? `共 ${items.length} 项 · ` : "";
  const limitInfo = d.max_downloads ? ` · 已下载 ${d.download_count}/${d.max_downloads} 次` : ` · 已下载 ${d.download_count} 次`;
  const expInfo = d.expires_at ? ` · 有效期至 ${new Date(d.expires_at).toLocaleString()}` : "";

  if (d.locked) {
    el.innerHTML = `
      <p class="name">${esc(d.name)}</p>
      <p class="meta">${countInfo}${fmtBytes(d.size)}${limitInfo}${expInfo}</p>
      <div class="input-row">
        <input id="pw" placeholder="请输入提取码" value="${esc(currentPasscode)}" />
        <button class="secondary" style="height:40px;padding:0 16px;" onclick="unlock()">提取</button>
      </div>
      ${errMsg ? `<div class="err">${esc(errMsg)}</div>` : ""}
    `;
    document.getElementById("pw").addEventListener("keydown", e => { if (e.key === "Enter") unlock(); });
    return;
  }

  if (items.length > 1) {
    window._bundleItems = items;
    const fileItems = items.filter(it => it.kind === "file");
    const rowsHtml = items.map((it, idx) => {
      if (it.kind === "text") {
        return `
          <div class="bundle-row">
            <div class="bundle-info">
              <div class="bundle-title">${esc(it.name)}</div>
              <div class="bundle-sub">文本片段 · ${fmtBytes(it.size)}</div>
            </div>
            <button class="mini-btn" onclick="copyBundleText(${idx}, this)">复制文本</button>
          </div>
        `;
      }
      return `
        <div class="bundle-row">
          <div class="bundle-info">
            <div class="bundle-title">${esc(it.name)}</div>
            <div class="bundle-sub">文件 · ${fmtBytes(it.size)}</div>
          </div>
          <a class="mini-btn" href="${buildDlUrl(it.id)}">下载</a>
        </div>
      `;
    }).join("");

    el.innerHTML = `
      <p class="name">${esc(d.name)}</p>
      <p class="meta">${countInfo}${fmtBytes(d.size)}${limitInfo}${expInfo}</p>
      <div class="bundle-list">${rowsHtml}</div>
      ${fileItems.length > 0 ? `<button onclick="downloadAllFiles(this)">全部下载 (${fileItems.length} 个文件)</button>` : ""}
    `;
    return;
  }

  if (d.kind === "text") {
    el.innerHTML = `
      <p class="name">${esc(d.name)}</p>
      <p class="meta">文本片段 · ${fmtBytes(d.size)}${expInfo}</p>
      <pre class="text-box" id="txt">${esc(d.text_content || "")}</pre>
      <button onclick="copyTxt(this)">复制全部文本</button>
    `;
    window._sharedText = d.text_content || "";
    return;
  }

  el.innerHTML = `
    <p class="name">${esc(d.name)}</p>
    <p class="meta">${fmtBytes(d.size)}${limitInfo}${expInfo}</p>
    <a class="btn" href="${buildDlUrl(null)}">立即下载文件</a>
  `;
}

async function unlock() {
  const typed = document.getElementById("pw").value.trim();
  if (!typed) return;
  const q = "?passcode=" + encodeURIComponent(typed);
  const resp = await fetch("/api/s/" + encodeURIComponent(code) + "/meta" + q);
  // Failed attempts are rate limited, so never resend a rejected passcode.
  if (!resp.ok) {
    currentPasscode = "";
    load((await resp.text()) || resp.statusText);
    return;
  }
  const d = await resp.json();
  if (d.locked) {
    currentPasscode = "";
    load("提取码不正确，请重试");
  } else {
    currentPasscode = typed;
    load();
  }
}

function copyTxt(btn) {
  navigator.clipboard.writeText(window._sharedText || "");
  if (btn) btn.textContent = "已复制到剪贴板";
}

function copyBundleText(idx, btn) {
  const it = (window._bundleItems || [])[idx];
  if (!it) return;
  navigator.clipboard.writeText(it.text_content || it.name || "");
  if (btn) btn.textContent = "已复制";
}

function downloadAllFiles(btn) {
  const files = (window._bundleItems || []).filter(it => it.kind === "file");
  files.forEach((it, i) => {
    setTimeout(() => {
      const a = document.createElement("a");
      a.href = buildDlUrl(it.id);
      a.download = it.name;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    }, i * 380);
  });
  if (btn) btn.textContent = `已触发 ${files.length} 个文件下载`;
}

load();
</script>
</body>
</html>
"#;

// ============================================================================
// WebSocket Handler
// ============================================================================

#[derive(Debug, Deserialize)]
struct WsQuery {
    /// Accepted for older clients; current clients send `Authorization: Bearer`
    /// so the token does not end up in proxy access logs.
    #[serde(default)]
    token: Option<String>,
    device_id: String,
}

async fn ws_upgrade(
    ws: WebSocketUpgrade,
    Query(query): Query<WsQuery>,
    headers: axum::http::HeaderMap,
    State(state): State<Arc<AppState>>,
) -> Result<Response, (StatusCode, String)> {
    let header_token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim);
    let token = header_token
        .or(query.token.as_deref())
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, "missing ws token".to_string()))?;
    let claims = decode_jwt(token, &state.jwt_secret)
        .map_err(|_| (StatusCode::UNAUTHORIZED, "invalid ws token".to_string()))?;

    if state
        .db
        .get_device(&query.device_id, &claims.sub)
        .map_err(internal_err)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, "device not registered".to_string()));
    }

    Ok(ws.on_upgrade(move |socket| handle_ws(socket, state, claims.sub, query.device_id)))
}

async fn handle_ws(socket: WebSocket, state: Arc<AppState>, user_id: String, device_id: String) {
    const PING_INTERVAL: StdDuration = StdDuration::from_secs(20);
    const READ_TIMEOUT: StdDuration = StdDuration::from_secs(60);
    let (mut ws_sink, mut ws_stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<WsEvent>();
    let key = (user_id.clone(), device_id.clone());
    let is_current = || {
        state
            .connections
            .get(&key)
            .is_some_and(|current| current.same_channel(&tx))
    };

    {
        let _presence = state.presence_changes.lock().await;
        state.connections.insert(key.clone(), tx.clone());

        if let (Ok(devices), Ok(items)) = (
            state.list_devices_with_presence(&user_id),
            state.list_hydrated_items(&user_id),
        ) {
            let _ = tx.send(WsEvent::Snapshot { devices, items });
        }

        if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
            dev.online = true;
            state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
        }
    }

    let mut send_task = tokio::spawn(async move {
        let start = tokio::time::Instant::now() + PING_INTERVAL;
        let mut heartbeat = tokio::time::interval_at(start, PING_INTERVAL);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let message = tokio::select! {
                event = rx.recv() => {
                    let Some(event) = event else { break };
                    let Ok(json) = serde_json::to_string(&event) else { continue };
                    Message::Text(json.into())
                }
                _ = heartbeat.tick() => Message::Ping(Default::default()),
            };
            if ws_sink.send(message).await.is_err() {
                break;
            }
        }
    });

    loop {
        let incoming = tokio::select! {
            incoming = tokio::time::timeout(READ_TIMEOUT, ws_stream.next()) => incoming,
            _ = &mut send_task => break,
        };
        let Ok(Some(Ok(message))) = incoming else { break };
        if !is_current() {
            break;
        }
        match message {
            Message::Text(text) => match serde_json::from_str::<WsClientCommand>(&text) {
                Ok(WsClientCommand::Ping) => {
                    let _ = tx.send(WsEvent::Pong);
                }
                Ok(WsClientCommand::UpdateNodeAddr {
                    iroh_node_id,
                    iroh_relay_url,
                    direct_addrs,
                }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    if let Ok(Some(mut dev)) = state.db.update_device_node_addr(
                        &device_id,
                        &user_id,
                        &iroh_node_id,
                        iroh_relay_url.as_deref(),
                        &direct_addrs,
                    ) {
                        dev.online = true;
                        state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
                    }
                }
                Err(_) => {}
            },
            Message::Close(_) => break,
            _ => {}
        }
    }

    send_task.abort();
    let _presence = state.presence_changes.lock().await;
    if state
        .connections
        .remove_if(&key, |_, current| current.same_channel(&tx))
        .is_some()
    {
        if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
            dev.online = false;
            state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
        }
    }
}

fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| match c {
            '/' | '\\' | '\0' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            _ => c,
        })
        .collect();
    if cleaned.is_empty() {
        "file.bin".to_string()
    } else {
        cleaned
    }
}

fn internal_err<E: std::fmt::Display>(err: E) -> (StatusCode, String) {
    tracing::error!("internal error: {err}");
    (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
}
