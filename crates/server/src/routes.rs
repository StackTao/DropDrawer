pub(crate) mod browser_share;
mod account;
mod devices;
mod google_drive_oauth;
mod items;
mod shares;
mod storage_backends;
mod ws;

use self::google_drive_oauth::{google_oauth_callback, start_google_oauth};
// Handlers live in one module per area; the router below refers to them by name.
use self::{account::*, devices::*, items::*, shares::*, storage_backends::*, ws::*};

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
    AccountInfo, AuthPublicConfig, AuthResponse, BindEmailConfirmRequest,
    BindEmailSendCodeRequest, ChangePasswordRequest, CloudDownloadInfo, CreateBatchShareRequest,
    CreateDrawerItemRequest, CreateShareRequest, CreateStorageBackendRequest,
    DeleteOwnAccountRequest, DeviceInfo, DownloadPlan, DrawerItem, DrawerItemKind, LoginRequest,
    P2pSourceInfo, RegisterDeviceRequest, RegisterRequest, ResetPasswordRequest,
    SendEmailCodeRequest, ShareLinkInfo, StorageBackendConfig, StorageBackendSummary,
    StorageHealthResponse, TransferMode, UploadPlan, WsClientCommand, WsEvent,
};
use serde::Deserialize;
use tokio::sync::mpsc;
use tower_http::cors::{AllowOrigin, Any, CorsLayer};
use uuid::Uuid;

use crate::admin::ClientIp;
use crate::auth::{
    create_versioned_jwt, decode_jwt, hash_password, issue_user_token, validate_user_claims,
    verify_password, AuthUser, Claims,
};
use crate::db::DrawerItemRow;
use crate::mailer::build_verification_email;
use crate::policy;
use crate::settings::{RegistrationMode, is_valid_email};
use crate::state::AppState;
use crate::storage::{DownloadResolution, local::LocalUploadTooLarge};

pub fn build_router(state: Arc<AppState>) -> Router {
    build_router_with_cors(state, None)
}

pub fn build_router_with_cors(state: Arc<AppState>, allowed_origins: Option<&[String]>) -> Router {
    let cors = match allowed_origins {
        Some(origins) if !origins.is_empty() && !origins.iter().any(|o| o == "*") => {
            let parsed: Vec<axum::http::HeaderValue> = origins
                .iter()
                .filter_map(|origin| origin.parse().ok())
                .collect();
            if parsed.is_empty() {
                CorsLayer::new()
                    .allow_origin(Any)
                    .allow_methods(Any)
                    .allow_headers(Any)
            } else {
                CorsLayer::new()
                    .allow_origin(AllowOrigin::list(parsed))
                    .allow_methods(Any)
                    .allow_headers(Any)
            }
        }
        _ => CorsLayer::new()
            .allow_origin(Any)
            .allow_methods(Any)
            .allow_headers(Any),
    };

    Router::new()
        .route("/health", get(health))
        .route("/privacy", get(crate::google_login::privacy_notice))
        // Auth
        .route("/api/auth/config", get(auth_public_config))
        .route("/api/auth/register", post(register))
        .route("/api/auth/login", post(login))
        .route("/api/auth/email/send-code", post(send_email_code))
        .route("/api/auth/password/reset", post(reset_password))
        .route("/api/auth/google/start", post(crate::google_login::start))
        .route("/api/auth/google/callback", get(crate::google_login::callback))
        .route("/api/auth/google/poll", post(crate::google_login::poll))
        // Self-service account management (authenticated)
        .route("/api/auth/me", get(get_own_account))
        .route("/api/auth/me/password", post(change_own_password))
        .route("/api/auth/me/email/send-code", post(send_bind_email_code))
        .route("/api/auth/me/email/confirm", post(confirm_bind_email))
        .route("/api/auth/me/delete", post(delete_own_account))
        // Admin Console (Vaultwarden-style, enabled only when DROPDRAWER_ADMIN_TOKEN is set)
        // Devices
        .route("/api/devices", get(list_devices).post(register_device))
        .route(
            "/api/devices/{id}/push-token",
            put(register_push_token).delete(delete_push_token),
        )
        .route("/api/client/config", get(client_config))
        // Storage backends & built-in OAuth helpers
        .route(
            "/api/storage",
            get(list_storage_backends).post(create_storage_backend),
        )
        .route(
            "/api/storage/{id}",
            get(storage_edit_settings)
                .patch(update_storage_backend)
                .delete(delete_storage_backend),
        )
        .route("/api/storage/{id}/default", put(set_default_storage_backend))
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
        .route("/api/share-peer.js", get(|| async {
            ([
                (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
                (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            ], include_str!("routes/public_share_peer.js"))
        }))
        .route("/api/s/{code}/meta", get(public_share_meta))
        .route("/api/s/{code}/download", get(public_share_download))
        .route("/api/s/{code}/peer", post(browser_share::offer))
        .route("/api/s/{code}/peer/{session}/claim", post(browser_share::claim))
        // Real-time WebSocket
        .route("/ws", get(ws_upgrade))
        .layer(cors)
        // The admin console is same-origin only, so it is merged after the CORS layer.
        .merge(crate::admin::router())
        .with_state(state)
        // Outermost, so every handler and error path sees the request language.
        .layer(axum::middleware::from_fn(crate::i18n::scope_language))
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "status": "ok", "service": "dropdrawer-server" }))
}

/// Runs Argon2 verification off the async worker threads.
async fn verify_password_blocking(password: &str, hash: &str) -> bool {
    let (password, hash) = (password.to_string(), hash.to_string());
    tokio::task::spawn_blocking(move || verify_password(&password, &hash))
        .await
        .unwrap_or(false)
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

/// Storage provider for a request: endpoints blocked by the admin storage policy are
/// refused with 403, any other construction failure stays a 500 as before.
async fn provider_for(
    state: &AppState,
    backend: &crate::db::StorageBackendRecord,
) -> Result<Box<dyn crate::storage::StorageProvider>, (StatusCode, String)> {
    policy::ensure_endpoints_allowed(&state.runtime_settings(), &backend.config)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e.to_string()))?;
    state.build_storage_provider(backend).map_err(internal_err)
}

fn internal_err<E: std::fmt::Display>(err: E) -> (StatusCode, String) {
    tracing::error!("internal error: {err}");
    (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
}
