mod google_drive_oauth;

use self::google_drive_oauth::{google_oauth_callback, start_google_oauth};

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
        .route("/api/s/{code}/meta", get(public_share_meta))
        .route("/api/s/{code}/download", get(public_share_download))
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

// ============================================================================
// Auth Handlers
// ============================================================================

fn hash_email_code(email: &str, purpose: &str, code: &str, secret: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(secret.as_bytes());
    hasher.update(b":");
    hasher.update(purpose.as_bytes());
    hasher.update(b":");
    hasher.update(email.trim().to_ascii_lowercase().as_bytes());
    hasher.update(b":");
    hasher.update(code.trim().as_bytes());
    hex::encode(hasher.finalize())
}

fn generate_six_digit_code() -> String {
    use rand::{RngCore, rngs::OsRng};
    let n = OsRng.next_u32() % 1_000_000;
    format!("{n:06}")
}

async fn auth_public_config(State(state): State<Arc<AppState>>) -> Json<AuthPublicConfig> {
    let settings = state.runtime_settings();
    Json(settings.to_public_auth_config(state.has_custom_email_sender()))
}

async fn send_email_code(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SendEmailCodeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
    }
    let purpose = req.purpose.trim();
    if purpose != "register" && purpose != "reset_password" {
        return Err((StatusCode::BAD_REQUEST, t!("无效的验证码用途", "Invalid code purpose").to_string()));
    }

    let settings = state.runtime_settings();
    let email_ready = settings.smtp.is_usable() || state.has_custom_email_sender();
    if !email_ready {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email is not enabled on this server").to_string(),
        ));
    }

    let rate_key = format!("{purpose}:{email}");
    if state.email_send_limiter.is_blocked(&rate_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("发送验证码过于频繁，请稍后再试", "Too many code requests. Try again later").to_string(),
        ));
    }
    if let Some(last) = state
        .db
        .last_email_verification_at(&email, purpose)
        .map_err(internal_err)?
    {
        let elapsed = (Utc::now() - last).num_seconds();
        if elapsed < 60 {
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                tf!("请等待 {} 秒后再重新发送验证码", "Wait {} seconds before requesting another code", (60 - elapsed).max(1)),
            ));
        }
    }

    if purpose == "register" {
        if settings.registration_mode == RegistrationMode::Closed {
            return Err((
                StatusCode::FORBIDDEN,
                t!("当前服务器已关闭新用户注册", "This server doesn't accept new sign-ups").to_string(),
            ));
        }
        if let Err(msg) = settings.check_email_domain(&email) {
            return Err((StatusCode::FORBIDDEN, msg));
        }
        if state
            .db
            .find_user_by_email(&email)
            .map_err(internal_err)?
            .is_some()
        {
            return Err((StatusCode::CONFLICT, t!("该邮箱已被注册", "This email is already registered").to_string()));
        }
    } else {
        if !settings.features.password_reset_enabled {
            return Err((
                StatusCode::FORBIDDEN,
                t!("管理员已关闭邮箱找回密码", "The administrator has turned off password reset by email").to_string(),
            ));
        }
        // Avoid user-enumeration: if email is unknown or disabled, still return ok without sending.
        let existing = state.db.find_user_by_email(&email).map_err(internal_err)?;
        if existing.is_none_or(|u| !u.email_verified || u.disabled) {
            state.email_send_limiter.record_failure(&rate_key);
            return Ok(Json(serde_json::json!({ "ok": true })));
        }
    }

    state.email_send_limiter.record_failure(&rate_key);
    let code = generate_six_digit_code();
    let code_hash = hash_email_code(&email, purpose, &code, &state.jwt_secret);
    let expires_at = Utc::now() + Duration::minutes(10);
    state
        .db
        .create_email_verification(&email, purpose, &code_hash, expires_at)
        .map_err(internal_err)?;

    let message = build_verification_email(&email, &code, purpose);
    state
        .send_email(&message)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, tf!("邮件发送失败: {e}", "Couldn't send the email: {e}")))?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn reset_password(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Json(req): Json<ResetPasswordRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
    }
    if req.new_password.len() < 6 {
        return Err((StatusCode::BAD_REQUEST, t!("新密码长度至少 6 位", "The new password must be at least 6 characters").to_string()));
    }
    let settings = state.runtime_settings();
    if !settings.features.password_reset_enabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("管理员已关闭邮箱找回密码", "The administrator has turned off password reset by email").to_string(),
        ));
    }
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email is not enabled on this server").to_string(),
        ));
    }

    let code_hash = hash_email_code(&email, "reset_password", &req.code, &state.jwt_secret);
    let valid = state
        .db
        .verify_and_consume_email_code(&email, "reset_password", &code_hash)
        .map_err(internal_err)?;
    if !valid {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("验证码无效或已过期，请重新获取", "The code is invalid or expired. Request a new one").to_string(),
        ));
    }

    let Some(user) = state.db.find_user_by_email(&email).map_err(internal_err)? else {
        return Err((StatusCode::BAD_REQUEST, t!("验证码无效或已过期", "The code is invalid or expired").to_string()));
    };
    if !user.email_verified || user.disabled {
        return Err((StatusCode::FORBIDDEN, t!("该账号当前不可重置密码", "This account's password can't be reset right now").to_string()));
    }

    let hash = hash_password(&req.new_password).map_err(internal_err)?;
    state
        .db
        .update_user_password(&user.id, &hash)
        .map_err(internal_err)?;
    // A reset password must also end sessions that may have been opened with the old one.
    state.revoke_user_sessions(&user.id, None).await.map_err(internal_err)?;
    state.failed_logins.reset(&login_limit_key(&ip, &user.username));
    state.failed_logins.reset(&login_limit_key(&ip, &email));

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let settings = state.runtime_settings();
    match settings.registration_mode {
        RegistrationMode::Closed => {
            return Err((
                StatusCode::FORBIDDEN,
                "registration is disabled on this server".to_string(),
            ));
        }
        RegistrationMode::InviteOnly => {
            let code = req.invite_code.as_deref().map(str::trim).unwrap_or("");
            if code.is_empty() {
                return Err((StatusCode::FORBIDDEN, t!("当前服务器仅支持邀请码注册", "This server only accepts sign-ups with an invitation code").to_string()));
            }
            if !state.db.is_invite_code_valid(code).map_err(internal_err)? {
                return Err((StatusCode::FORBIDDEN, t!("邀请码无效、已用完或已过期", "The invitation code is invalid, used up or expired").to_string()));
            }
        }
        RegistrationMode::Open => {}
    }

    let username = req.username.trim();
    if username.len() < 2 || req.password.len() < 6 {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("用户名至少 2 个字符，密码至少 6 位", "Usernames need at least 2 characters and passwords at least 6").to_string(),
        ));
    }
    policy::validate_username(username)?;

    if state
        .db
        .find_user_by_username(username)
        .map_err(internal_err)?
        .is_some()
    {
        return Err((StatusCode::CONFLICT, t!("该用户名已被注册", "This username is already taken").to_string()));
    }

    let email_ready = settings.smtp.is_usable() || state.has_custom_email_sender();
    let require_email = settings.email_verification_required && email_ready;
    let supplied_email = req
        .email
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase());

    let (verified_email, email_verified) = if require_email || supplied_email.is_some() {
        let Some(email) = supplied_email else {
            return Err((StatusCode::BAD_REQUEST, t!("请填写注册邮箱并完成验证码校验", "Enter your email and verify it with the code").to_string()));
        };
        if !is_valid_email(&email) {
            return Err((StatusCode::BAD_REQUEST, t!("邮箱地址格式无效", "Invalid email address").to_string()));
        }
        if let Err(msg) = settings.check_email_domain(&email) {
            return Err((StatusCode::FORBIDDEN, msg));
        }
        if state
            .db
            .find_user_by_email(&email)
            .map_err(internal_err)?
            .is_some()
        {
            return Err((StatusCode::CONFLICT, t!("该邮箱已被注册", "This email is already registered").to_string()));
        }
        if require_email || req.email_code.as_deref().is_some_and(|c| !c.trim().is_empty()) {
            let code = req.email_code.as_deref().unwrap_or("").trim();
            if code.is_empty() {
                return Err((StatusCode::BAD_REQUEST, t!("请输入邮箱验证码", "Enter the email verification code").to_string()));
            }
            let code_hash = hash_email_code(&email, "register", code, &state.jwt_secret);
            let ok = state
                .db
                .verify_and_consume_email_code(&email, "register", &code_hash)
                .map_err(internal_err)?;
            if !ok {
                return Err((
                    StatusCode::BAD_REQUEST,
                    t!("邮箱验证码无效或已过期，请重新获取", "The email code is invalid or expired. Request a new one").to_string(),
                ));
            }
            (Some(email), true)
        } else {
            (Some(email), false)
        }
    } else {
        (None, false)
    };

    if settings.registration_mode == RegistrationMode::InviteOnly {
        let code = req.invite_code.as_deref().unwrap_or("");
        let consumed = state.db.consume_invite_code(code).map_err(internal_err)?;
        if !consumed {
            return Err((StatusCode::FORBIDDEN, t!("邀请码无效、已用完或已过期", "The invitation code is invalid, used up or expired").to_string()));
        }
    }

    let hash = hash_password(&req.password).map_err(internal_err)?;
    let user_id = Uuid::new_v4().to_string();
    let user = state
        .db
        .create_user_with_email(
            &user_id,
            username,
            &hash,
            verified_email.as_deref(),
            email_verified,
        )
        .map_err(internal_err)?;
    let token = issue_user_token(&state, &user.id, &user.username).map_err(internal_err)?;
    let _ = state.db.touch_last_login(&user.id);

    Ok(Json(AuthResponse { token, user }))
}

fn login_limit_key(ip: &str, username: &str) -> String {
    format!("{ip}|{}", username.trim().to_lowercase())
}

async fn login(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Json(req): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !state.runtime_settings().password_login_enabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("当前服务器已关闭账号密码登录，请使用其他已启用的登录方式", "Password sign-in is turned off on this server. Use another enabled sign-in method").to_string(),
        ));
    }
    let limit_key = login_limit_key(&ip, &req.username);
    if state.failed_logins.is_blocked(&limit_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "too many failed login attempts, try again later".to_string(),
        ));
    }
    let invalid = || {
        state.failed_logins.record_failure(&limit_key);
        (StatusCode::UNAUTHORIZED, t!("用户名或密码错误", "Incorrect username or password").to_string())
    };
    let user_rec = state
        .db
        .find_user_by_identifier(req.username.trim())
        .map_err(internal_err)?
        .ok_or_else(invalid)?;

    if user_rec.disabled {
        return Err((
            StatusCode::FORBIDDEN,
            t!("该账号已被管理员禁用", "This account has been disabled by an administrator").to_string(),
        ));
    }

    if !verify_password_blocking(&req.password, &user_rec.password_hash).await {
        return Err(invalid());
    }
    state.failed_logins.reset(&limit_key);

    let token = create_versioned_jwt(
        &user_rec.id,
        &user_rec.username,
        user_rec.token_version,
        &state.jwt_secret,
    )
    .map_err(internal_err)?;
    let _ = state.db.touch_last_login(&user_rec.id);
    Ok(Json(AuthResponse {
        token,
        user: protocol::UserProfile {
            id: user_rec.id,
            username: user_rec.username,
            email: user_rec.email,
            created_at: user_rec.created_at,
        },
    }))
}

fn build_account_info(state: &AppState, user: &crate::db::UserRecord) -> anyhow::Result<AccountInfo> {
    let settings = state.runtime_settings();
    let google_linked = state.db.user_has_google_link(&user.id)?;
    let email_binding_available = settings.smtp.is_usable() || state.has_custom_email_sender();
    Ok(AccountInfo {
        id: user.id.clone(),
        username: user.username.clone(),
        email: user.email.clone(),
        email_verified: user.email_verified,
        has_password: !user.password_hash.trim().is_empty(),
        google_linked,
        email_binding_available,
        created_at: user.created_at,
    })
}

async fn get_own_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<AccountInfo>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    let info = build_account_info(&state, &user).map_err(internal_err)?;
    Ok(Json(info))
}

async fn change_own_password(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<ChangePasswordRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if req.new_password.len() < 6 {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("新密码长度至少 6 位", "New password must be at least 6 characters").to_string(),
        ));
    }
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;

    // A Google-only account adding its first password must also prove it is the holder.
    confirm_account_holder(&auth, &user, req.current_password.as_deref()).await?;

    let hash = hash_password(&req.new_password).map_err(internal_err)?;
    state
        .db
        .update_user_password(&user.id, &hash)
        .map_err(internal_err)?;
    // The initiating device reconnects with the new token after this response.
    state
        .revoke_user_sessions(&user.id, req.device_id.as_deref())
        .await
        .map_err(internal_err)?;
    state.failed_logins.reset(&user.username.to_lowercase());
    if let Some(ref email) = user.email {
        state.failed_logins.reset(&email.to_lowercase());
    }
    let token = issue_user_token(&state, &user.id, &user.username).map_err(internal_err)?;
    Ok(Json(AuthResponse {
        token,
        user: protocol::UserProfile {
            id: user.id,
            username: user.username,
            email: user.email,
            created_at: user.created_at,
        },
    }))
}

async fn send_bind_email_code(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<BindEmailSendCodeRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    // Passwordless accounts must have signed in recently; password accounts give
    // their password when confirming the code. Checking now saves a wasted email.
    if user.password_hash.trim().is_empty() {
        confirm_account_holder(&auth, &user, None).await?;
    }
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("邮箱地址格式无效", "Invalid email address").to_string(),
        ));
    }
    let settings = state.runtime_settings();
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email service is not enabled on this server").to_string(),
        ));
    }
    if let Err(msg) = settings.check_email_domain(&email) {
        return Err((StatusCode::FORBIDDEN, msg));
    }
    if let Some(owner) = state.db.find_user_by_email(&email).map_err(internal_err)?
        && owner.id != auth.user_id
    {
        return Err((
            StatusCode::CONFLICT,
            t!("该邮箱已被其他账号使用", "That email address is already in use").to_string(),
        ));
    }

    let purpose = "bind_email";
    let rate_key = format!("{purpose}:{email}");
    if state.email_send_limiter.is_blocked(&rate_key) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("发送验证码过于频繁，请稍后再试", "Too many verification codes sent; try again later").to_string(),
        ));
    }
    if let Some(last) = state
        .db
        .last_email_verification_at(&email, purpose)
        .map_err(internal_err)?
    {
        let elapsed = (Utc::now() - last).num_seconds();
        if elapsed < 60 {
            let wait = (60 - elapsed).max(1);
            return Err((
                StatusCode::TOO_MANY_REQUESTS,
                tf!(
                    "请等待 {wait} 秒后再重新发送验证码",
                    "Please wait {wait} seconds before requesting another code"
                ),
            ));
        }
    }

    state.email_send_limiter.record_failure(&rate_key);
    let code = generate_six_digit_code();
    let code_hash = hash_email_code(&email, purpose, &code, &state.jwt_secret);
    let expires_at = Utc::now() + Duration::minutes(10);
    state
        .db
        .create_email_verification(&email, purpose, &code_hash, expires_at)
        .map_err(internal_err)?;

    let message = build_verification_email(&email, &code, purpose);
    state
        .send_email(&message)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, tf!("邮件发送失败: {e}", "Failed to send email: {e}")))?;

    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn confirm_bind_email(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<BindEmailConfirmRequest>,
) -> Result<Json<AccountInfo>, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    // The email is where password resets go, so a session alone must not change it.
    confirm_account_holder(&auth, &user, req.current_password.as_deref()).await?;
    let email = req.email.trim().to_ascii_lowercase();
    if !is_valid_email(&email) {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("邮箱地址格式无效", "Invalid email address").to_string(),
        ));
    }
    let settings = state.runtime_settings();
    if !settings.smtp.is_usable() && !state.has_custom_email_sender() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            t!("当前服务器未启用邮件服务", "Email service is not enabled on this server").to_string(),
        ));
    }
    if let Err(msg) = settings.check_email_domain(&email) {
        return Err((StatusCode::FORBIDDEN, msg));
    }
    if let Some(owner) = state.db.find_user_by_email(&email).map_err(internal_err)?
        && owner.id != auth.user_id
    {
        return Err((
            StatusCode::CONFLICT,
            t!("该邮箱已被其他账号使用", "That email address is already in use").to_string(),
        ));
    }

    let code_hash = hash_email_code(&email, "bind_email", &req.code, &state.jwt_secret);
    let valid = state
        .db
        .verify_and_consume_email_code(&email, "bind_email", &code_hash)
        .map_err(internal_err)?;
    if !valid {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("验证码无效或已过期，请重新获取", "Verification code is invalid or expired").to_string(),
        ));
    }

    state
        .db
        .set_user_verified_email(&auth.user_id, &email)
        .map_err(internal_err)?;
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;
    let info = build_account_info(&state, &user).map_err(internal_err)?;
    Ok(Json(info))
}

async fn delete_own_account(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<DeleteOwnAccountRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("账号不存在", "account not found").to_string()))?;

    let has_password = !user.password_hash.trim().is_empty();
    if !has_password {
        let confirm = req.confirm_username.as_deref().map(str::trim).unwrap_or("");
        if confirm != user.username {
            return Err((
                StatusCode::BAD_REQUEST,
                t!("请输入完整用户名以确认注销账号", "Enter your exact username to confirm account deletion").to_string(),
            ));
        }
    }
    confirm_account_holder(&auth, &user, req.password.as_deref()).await?;

    state.disconnect_user(&user.id);
    let failed = state.delete_all_drawer_items(&user.id).await.map_err(internal_err)?;
    if failed > 0 {
        // Deleting the account would also drop the storage credentials and the
        // records that let cleanup retry, leaving the files in the user's cloud
        // for good. Keep the account so the user can try again.
        let message = if crate::i18n::is_en() {
            let files = if failed == 1 { "1 file" } else { "files" };
            let files = if failed == 1 { files.to_string() } else { format!("{failed} {files}") };
            format!("{files} couldn't be removed from cloud storage, so the account wasn't deleted. Check the storage connection and try again")
        } else {
            format!("有 {failed} 个文件暂时无法从云盘删除，账号尚未注销。请检查云盘连接后重试")
        };
        return Err((StatusCode::BAD_GATEWAY, message));
    }
    state.db.delete_user(&user.id).map_err(internal_err)?;
    Ok(StatusCode::NO_CONTENT)
}

// ============================================================================
// Device Handlers
// ============================================================================

async fn register_device(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterDeviceRequest>,
) -> Result<Json<DeviceInfo>, (StatusCode, String)> {
    policy::ensure_client_version(&state, req.app_version.as_deref())?;
    if state
        .db
        .device_removed_after(
            &auth.user_id,
            req.device_id.as_deref(),
            req.iroh_node_id.as_deref(),
            auth.issued_at,
        )
        .map_err(internal_err)?
    {
        return Err((
            StatusCode::UNAUTHORIZED,
            t!("该设备已被管理员移除，请重新登录", "An administrator removed this device. Sign in again").to_string(),
        ));
    }
    let _presence = state.presence_changes.lock().await;
    policy::ensure_device_slot(
        &state,
        &auth.user_id,
        req.device_id.as_deref(),
        req.platform,
        req.iroh_node_id.as_deref(),
    )?;
    let mut device = state
        .db
        .upsert_device(&auth.user_id, &req)
        .map_err(internal_err)?;
    let _ = state.db.clear_device_removal(
        &auth.user_id,
        req.device_id.as_deref(),
        req.iroh_node_id.as_deref(),
    );
    state.fill_device_presence(&mut device);
    state.broadcast_user(&auth.user_id, WsEvent::DeviceUpdated(device.clone()));
    Ok(Json(device))
}

#[derive(Debug, Deserialize)]
struct ClientConfigQuery {
    #[serde(default)]
    device_id: Option<String>,
}

async fn client_config(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Query(query): Query<ClientConfigQuery>,
) -> Result<Json<protocol::ClientConfig>, (StatusCode, String)> {
    // Clients poll this when their socket drops; tell a device removed by an
    // administrator to sign in again instead of reconnecting forever.
    if state
        .db
        .device_removed_after(&auth.user_id, query.device_id.as_deref(), None, auth.issued_at)
        .map_err(internal_err)?
    {
        return Err((
            StatusCode::UNAUTHORIZED,
            t!("该设备已被管理员移除，请重新登录", "An administrator removed this device. Sign in again").to_string(),
        ));
    }
    policy::client_config(&state, &auth.user_id).map(Json)
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
    let settings = state.runtime_settings();
    policy::ensure_backend_kind_allowed(&settings.storage_policy, config.kind())?;
    policy::ensure_endpoints_allowed(&settings, &config)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e.to_string()))?;
    let rec = state
        .db
        .create_storage_backend(&id, &auth.user_id, &req.name, &config, req.is_default)
        .map_err(internal_err)?;
    Ok(Json(rec.to_summary()))
}

#[derive(serde::Serialize)]
struct StorageEditSettings {
    max_bytes: Option<u64>,
}

async fn storage_edit_settings(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<StorageEditSettings>, (StatusCode, String)> {
    let backend = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(storage_backend_not_found)?;
    let max_bytes = match backend.config {
        StorageBackendConfig::Local { max_bytes, .. } => max_bytes,
        _ => None,
    };
    Ok(Json(StorageEditSettings { max_bytes }))
}

#[derive(Deserialize)]
struct UpdateStorageBackendRequest {
    name: String,
    #[serde(default)]
    config: serde_json::Map<String, serde_json::Value>,
}

async fn update_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateStorageBackendRequest>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    let backend = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(storage_backend_not_found)?;
    let name = req.name.trim();
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, t!("存储名称不能为空", "Storage name can't be empty").to_string()));
    }
    // Stored files refer to this backend ID. Keep the destination and account
    // identifiers fixed while letting users rotate credentials for that target.
    let credential_fields: &[&str] = match &backend.config {
        StorageBackendConfig::GoogleDrive { .. } => &["client_secret", "refresh_token"],
        StorageBackendConfig::Quark { .. } => &["cookie"],
        StorageBackendConfig::BaiduNetdisk { .. } => {
            &["client_secret", "refresh_token", "access_token"]
        }
        StorageBackendConfig::WebDav { .. } => &["password"],
        StorageBackendConfig::S3 { .. } => &["access_key_id", "secret_access_key"],
        StorageBackendConfig::Local { .. } => &[],
    };
    let mut patch = serde_json::Map::new();
    for (key, value) in req.config {
        if key == "max_bytes" && matches!(&backend.config, StorageBackendConfig::Local { .. }) {
            if !value.is_null() && value.as_u64().is_none_or(|bytes| bytes == 0) {
                return Err((StatusCode::BAD_REQUEST, t!("容量上限必须为正整数", "The capacity limit must be a positive whole number").to_string()));
            }
        } else if credential_fields.contains(&key.as_str()) {
            let credential = value
                .as_str()
                .ok_or_else(|| (StatusCode::BAD_REQUEST, t!("凭据必须为字符串", "Credentials must be strings").to_string()))?;
            if credential.trim().is_empty() {
                continue;
            }
        } else {
            return Err((StatusCode::BAD_REQUEST, t!("此存储字段无法编辑", "This storage field can't be edited").to_string()));
        }
        patch.insert(key, value);
    }
    if !state
        .db
        .update_storage_backend(&id, &auth.user_id, name, &patch)
        .map_err(internal_err)?
    {
        return Err(storage_backend_not_found());
    }
    list_storage_backends(auth, State(state)).await
}

fn storage_backend_not_found() -> (StatusCode, String) {
    (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string())
}

async fn set_default_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    if !state
        .db
        .set_default_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
    {
        return Err(storage_backend_not_found());
    }
    list_storage_backends(auth, State(state)).await
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
        return Err(storage_backend_not_found());
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
        .ok_or_else(storage_backend_not_found)?;

    let provider = match state.storage_provider(&rec).await {
        Ok(provider) => provider,
        Err(err) => {
            return Ok(Json(StorageHealthResponse {
                ok: false,
                message: err.to_string(),
            }))
        }
    };
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
    policy::ensure_item_slot(&state, &auth.user_id)?;
    let now = Utc::now();
    let id = Uuid::new_v4().to_string();
    let expires_at = Some(policy::item_expiry(&state, req.ttl_hours, now));

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
        .ok_or_else(|| (StatusCode::INTERNAL_SERVER_ERROR, t!("条目不存在", "Item not found").to_string()))?;

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
        return Err((StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()));
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
    #[serde(default)]
    content_sha256: Option<String>,
    #[serde(default)]
    size: Option<u64>,
}

fn normalize_sha256(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.len() == 64 && trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(trimmed.to_ascii_lowercase())
    } else {
        None
    }
}

async fn request_upload_plan(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UploadPlanRequest>,
) -> Result<Json<UploadPlan>, (StatusCode, String)> {
    let _item_lock = state.lock_drawer_item(&id).await;
    let item = state
        .db
        .get_drawer_item(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;

    let backend_id = req
        .storage_backend_id
        .as_deref()
        .or(item.storage_backend_id.as_deref());
    let backend = state
        .resolve_backend(&auth.user_id, backend_id)
        .map_err(internal_err)?;
    policy::ensure_upload_allowed(&state, &auth.user_id, &backend)?;
    let expected_size = req.size.unwrap_or(item.size);
    if matches!(&backend.config, StorageBackendConfig::Local { .. }) {
        LocalUploadTooLarge::check(state.local_max_file_bytes(), item.size.max(expected_size))
            .map_err(|err| (StatusCode::PAYLOAD_TOO_LARGE, err.to_string()))?;
    }
    let provider = provider_for(&state, &backend).await?;

    // Telegram-style instant deduplication: strictly scoped to the same user
    // and same storage backend, verified against physical storage before reuse.
    if let Some(content_sha256) = normalize_sha256(req.content_sha256.as_deref())
        && let Some(reused_path) = state
            .db
            .find_reusable_cloud_object(
                &auth.user_id,
                &backend.id,
                &content_sha256,
                expected_size,
                &item.id,
            )
            .map_err(internal_err)?
    {
        let _storage_lock = state.lock_storage_object(&backend.id, &reused_path).await;
        let still_referenced = state
            .db
            .count_other_storage_refs(&auth.user_id, &backend.id, &reused_path, &item.id)
            .map_err(internal_err)?
            > 0;
        if still_referenced && provider.object_exists(&reused_path).await.unwrap_or(false) {
            state
                .db
                .mark_item_cloud_ready_with_sha256(
                    &item.id,
                    &auth.user_id,
                    &backend.id,
                    &reused_path,
                    Some(expected_size),
                    None,
                    Some(&content_sha256),
                )
                .map_err(internal_err)?;
            let hydrated = state
                .hydrate_single_item(&auth.user_id, &item.id)
                .map_err(internal_err)?
                .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目已被移出", "The item was removed").to_string()))?;
            state.broadcast_user(&auth.user_id, WsEvent::ItemUpdated(hydrated.clone()));
            return Ok(Json(UploadPlan::AlreadyCached {
                item: Box::new(hydrated),
            }));
        }
    }

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
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;

    let backend = state
        .resolve_backend(
            &auth.user_id,
            query
                .storage_backend_id
                .as_deref()
                .or(item.storage_backend_id.as_deref()),
        )
        .map_err(internal_err)?;
    policy::ensure_upload_allowed(&state, &auth.user_id, &backend)?;
    let provider = provider_for(&state, &backend).await?;

    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
        .or(if item.size > 0 { Some(item.size) } else { None });

    let remote_key = item_storage_key(&auth.user_id, &item.id, &item.name);

    use sha2::{Digest, Sha256};

    let hasher = Arc::new(std::sync::Mutex::new(Sha256::new()));
    let hasher_for_stream = hasher.clone();
    let stream = body
        .into_data_stream()
        .map_err(|e| anyhow::anyhow!("request body stream error: {e}"))
        .map_ok(move |chunk| {
            if let Ok(mut h) = hasher_for_stream.lock() {
                h.update(&chunk);
            }
            chunk
        });

    let put_res = provider
        .put_stream(&remote_key, content_length, Box::pin(stream))
        .await
        .map_err(|err| match err.downcast_ref::<LocalUploadTooLarge>() {
            Some(limit) => (StatusCode::PAYLOAD_TOO_LARGE, limit.to_string()),
            None => internal_err(err),
        })?;

    let computed_sha256 = hasher
        .lock()
        .ok()
        .map(|h| hex::encode(h.clone().finalize()));

    state
        .db
        .mark_item_cloud_ready_with_sha256(
            &item.id,
            &auth.user_id,
            &backend.id,
            &put_res.stored_key,
            Some(put_res.bytes_written),
            None,
            computed_sha256.as_deref(),
        )
        .map_err(internal_err)?;

    let hydrated = state
        .hydrate_single_item(&auth.user_id, &item.id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目已被移出", "The item was removed").to_string()))?;

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
    #[serde(default)]
    content_sha256: Option<String>,
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
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;
    let backend = state
        .db
        .get_storage_backend(&req.storage_backend_id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string()))?;
    policy::ensure_upload_allowed(&state, &auth.user_id, &backend)?;
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
    let normalized_sha256 = normalize_sha256(req.content_sha256.as_deref());
    let ok = state
        .db
        .mark_item_cloud_ready_with_sha256(
            &id,
            &auth.user_id,
            &req.storage_backend_id,
            &req.remote_key,
            req.size,
            req.blake3_hash.as_deref(),
            normalized_sha256.as_deref(),
        )
        .map_err(internal_err)?;
    if !ok {
        return Err((StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()));
    }
    let hydrated = state
        .hydrate_single_item(&auth.user_id, &id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;
    state.broadcast_user(&auth.user_id, WsEvent::ItemUpdated(hydrated.clone()));
    Ok(Json(hydrated))
}

#[derive(Debug, Deserialize)]
struct DownloadPlanQuery {
    #[serde(default)]
    prefer_replica: bool,
    #[serde(default)]
    requester_device_id: Option<String>,
}

// Private addresses can be routed on a wider LAN than /24. Prefer subnet
// matches, and let QUIC authenticate the peer and confirm actual reachability.
fn lan_candidates(requester: &[String], source: &[String]) -> (bool, Vec<String>) {
    use std::net::{IpAddr, SocketAddr};
    let ips: Vec<_> = requester
        .iter()
        .filter_map(|s| s.parse::<SocketAddr>().ok().map(|a| a.ip()))
        .collect();
    let mut same_prefix = false;
    let mut addresses = Vec::new();
    for address in source {
        let Ok(socket) = address.parse::<SocketAddr>() else {
            continue;
        };
        let mut usable = false;
        for ip in &ips {
            match (*ip, socket.ip()) {
                (IpAddr::V4(a), IpAddr::V4(b)) if a != b && a.is_private() && b.is_private() => {
                    usable = true;
                    same_prefix |= a.octets()[..3] == b.octets()[..3];
                }
                (IpAddr::V6(a), IpAddr::V6(b))
                    if a != b
                        && !a.is_unicast_link_local()
                        && !a.is_loopback()
                        && !a.is_unspecified()
                        && a.octets()[..8] == b.octets()[..8] =>
                {
                    usable = true;
                    same_prefix = true;
                }
                _ => {}
            }
        }
        if usable {
            addresses.push(address.clone());
        }
    }
    (same_prefix, addresses)
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
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;

    let mut p2p = None;
    if item.transfer_mode != TransferMode::CloudCached {
        let devices = state
            .list_devices_with_presence(&auth.user_id)
            .map_err(internal_err)?;
        let requester = devices
            .iter()
            .find(|d| Some(&d.id) == query.requester_device_id.as_ref());
        let mut candidates = Vec::new();
        if query.prefer_replica
            && let (Some(rx), Some(hash)) = (
                requester.filter(|d| d.iroh_node_id.is_some()),
                item.blake3_hash.as_deref(),
            )
        {
            for d in devices
                .iter()
                .filter(|d| d.online && d.id != rx.id && d.id != item.owner_device_id)
            {
                let has_replica = state
                    .ready_files
                    .get(&(auth.user_id.clone(), d.id.clone()))
                    .is_some_and(|files| files.get(&id).is_some_and(|h| h == hash));
                if !has_replica {
                    continue;
                }
                let (same_prefix, addresses) = lan_candidates(&rx.direct_addrs, &d.direct_addrs);
                if !addresses.is_empty() {
                    candidates.push((!same_prefix, d, addresses, Some(hash.to_owned())));
                }
            }
        }
        candidates.sort_by_key(|(less_likely, ..)| *less_likely);
        if let Some(owner) = devices
            .iter()
            .find(|d| d.id == item.owner_device_id && d.online)
        {
            candidates.push((false, owner, owner.direct_addrs.clone(), None));
        }
        for (_, source, direct_addrs, replica_hash) in candidates {
            let Some(node_id) = source.iroh_node_id.clone() else {
                continue;
            };
            let token = Uuid::new_v4().to_string();
            if state.send_to_device(
                &auth.user_id,
                &source.id,
                WsEvent::AuthorizeP2pToken {
                    item_id: id.clone(),
                    token: token.clone(),
                    requester_device_id: query
                        .requester_device_id
                        .clone()
                        .unwrap_or_else(|| "unknown".into()),
                    expires_at: Utc::now() + Duration::minutes(10),
                    requester_node_id: requester.and_then(|d| d.iroh_node_id.clone()),
                },
            ) {
                p2p = Some(P2pSourceInfo {
                    device_id: source.id.clone(),
                    iroh_node_id: node_id,
                    iroh_relay_url: source.iroh_relay_url.clone(),
                    direct_addrs,
                    transfer_token: token,
                    replica_hash,
                });
                break;
            }
        }
    }

    let mut cloud = None;
    if item.cloud_ready
        && let (Some(backend_id), Some(storage_path)) = (
            item.storage_backend_id.as_deref(),
            item.storage_path.as_deref(),
        )
    {
        let settings = state.runtime_settings();
        let backend = state
            .db
            .get_storage_backend(backend_id, &auth.user_id)
            .map_err(internal_err)?;
        let backend = match backend {
            Some(b)
                if policy::ensure_endpoints_allowed(&settings, &b.config)
                    .await
                    .is_ok() =>
            {
                Some(b)
            }
            _ => None,
        };
        if let Some(backend) = backend {
            let provider = state
                .build_storage_provider(&backend)
                .map_err(internal_err)?;
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
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("条目不存在或已被移出", "The item doesn't exist or was removed").to_string()))?;

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
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string()))?;
    let provider = provider_for(&state, &backend).await?;

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
    let first = &items[0].name;
    // "A 等 3 项" counts every item; English names the first and counts the rest.
    if crate::i18n::is_en() {
        let more = items.len() - 1;
        format!("{first} and {more} more {}", if more == 1 { "item" } else { "items" })
    } else {
        format!("{first} 等 {} 项", items.len())
    }
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
            t!("请至少选择一个文件或文本条目", "Select at least one file or text item").to_string(),
        ));
    }

    let mut items = Vec::with_capacity(unique_ids.len());
    for id in &unique_ids {
        let item = state
            .db
            .get_drawer_item(id, user_id)
            .map_err(internal_err)?
            .ok_or_else(|| (StatusCode::NOT_FOUND, t!("抽屉条目不存在", "Drawer item not found").to_string()))?;

        if item.kind == DrawerItemKind::File && !item.cloud_ready {
            return Err((
                StatusCode::BAD_REQUEST,
                tf!("文件「{}」尚未上传到云盘/服务器，请先转存云端后再创建外链", "“{}” hasn't been uploaded to the cloud or server yet. Save it to the cloud before creating a link", item.name),
            ));
        }
        items.push(item);
    }

    let terms = policy::share_terms(
        state,
        user_id,
        passcode.as_deref(),
        expires_hours,
        max_downloads,
    )?;
    let (expires_hours, max_downloads) = (terms.expires_hours, terms.max_downloads);

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
        return Err((StatusCode::NOT_FOUND, t!("分享链接不存在", "Share link not found").to_string()));
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

/// How long after signing in a passwordless (Google-only) account may change
/// its security settings. A session alone, however old, is not enough.
const RECENT_SIGN_IN_MINUTES: i64 = 10;

/// Confirms the request comes from the account holder, not just someone holding
/// a session: the current password when the account has one, otherwise a sign-in
/// within the last few minutes (signing in with Google again proves it).
async fn confirm_account_holder(
    auth: &AuthUser,
    user: &crate::db::UserRecord,
    password: Option<&str>,
) -> Result<(), (StatusCode, String)> {
    if !user.password_hash.trim().is_empty() {
        let password = password.unwrap_or("");
        if password.is_empty() || !verify_password_blocking(password, &user.password_hash).await {
            return Err((
                StatusCode::UNAUTHORIZED,
                t!("当前密码不正确", "Current password is incorrect").to_string(),
            ));
        }
        return Ok(());
    }
    if Utc::now() - auth.issued_at <= Duration::minutes(RECENT_SIGN_IN_MINUTES) {
        return Ok(());
    }
    Err((
        StatusCode::FORBIDDEN,
        tf!(
            "为了保护账号安全，请退出后重新用 Google 登录，并在 {RECENT_SIGN_IN_MINUTES} 分钟内完成此操作",
            "For your security, sign out, sign in with Google again, and finish this within {RECENT_SIGN_IN_MINUTES} minutes"
        ),
    ))
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
            t!("提取码尝试次数过多，请稍后再试", "Too many passcode attempts. Try again later").to_string(),
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
    if let Some(exp) = share.expires_at
        && exp <= Utc::now()
    {
        return Err((StatusCode::GONE, t!("该分享链接已过期", "This share link has expired").to_string()));
    }
    if let Some(max) = share.max_downloads
        && share.download_count >= max
    {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
    }
    if !share_unlocked(state, share, passcode).await? {
        return Err((StatusCode::FORBIDDEN, t!("需要正确的提取码", "A correct passcode is required").to_string()));
    }
    Ok(())
}

async fn public_share_meta(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;

    if let Some(exp) = share.expires_at
        && exp <= Utc::now()
    {
        return Err((StatusCode::GONE, t!("该分享链接已过期", "This share link has expired").to_string()));
    }
    if let Some(max) = share.max_downloads
        && share.download_count >= max
    {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
    }

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, t!("关联文件已被删除", "The linked file has been deleted").to_string()));
    }

    let locked = !share_unlocked(&state, &share, query.passcode.as_deref()).await?;

    // Without a title chosen by the sharer, the name comes from the files, which
    // the passcode protects. Before unlocking, show a neutral title instead.
    let has_custom_title = share.title.as_deref().is_some_and(|t| !t.trim().is_empty());
    let display_name = if locked && !has_custom_title {
        t!("此分享需要提取码", "This share needs a passcode").to_string()
    } else {
        format_share_display_name(share.title.as_deref(), &items)
    };
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

    // A passcode protects the file list too: before unlocking, visitors see only
    // the share's title, item count and total size.
    let visible_items: &[DrawerItemRow] = if locked { &[] } else { &items };
    let serialized_items: Vec<serde_json::Value> = visible_items
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
    ClientIp(ip): ClientIp,
    Path(code): Path<String>,
    Query(query): Query<PublicShareQuery>,
) -> Result<Response, (StatusCode, String)> {
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;

    validate_share_access(&state, &share, query.passcode.as_deref()).await?;

    let items = state
        .db
        .get_share_link_items(&share.code, &share.item_id)
        .map_err(internal_err)?;
    if items.is_empty() {
        return Err((StatusCode::NOT_FOUND, t!("关联文件已被删除", "The linked file has been deleted").to_string()));
    }

    let item = if let Some(ref target_id) = query.item_id {
        items
            .into_iter()
            .find(|it| &it.id == target_id)
            .ok_or_else(|| (StatusCode::NOT_FOUND, t!("所请求的文件不在该分享中", "The requested file isn't part of this share").to_string()))?
    } else {
        items.into_iter().next().unwrap()
    };

    if item.kind == DrawerItemKind::Text {
        if !state
            .db
            .increment_share_download(&code)
            .map_err(internal_err)?
        {
            return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
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
        return Err((StatusCode::BAD_REQUEST, t!("文件尚未缓存到云端", "The file isn't cached in the cloud yet").to_string()));
    };

    let backend = state
        .db
        .get_storage_backend(backend_id, &item.user_id)
        .map_err(internal_err)?
        .ok_or_else(|| (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string()))?;

    let provider = provider_for(&state, &backend).await?;
    let incremented = state
        .db
        .increment_share_download(&code)
        .map_err(internal_err)?;
    if !incremented {
        return Err((StatusCode::GONE, t!("该分享链接已达到下载次数上限", "This share link has reached its download limit").to_string()));
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

fn lookup_public_share(
    state: &AppState,
    ip: &str,
    code: &str,
) -> Result<crate::db::ShareLinkRow, (StatusCode, String)> {
    if state.failed_share_lookups.is_blocked(ip) {
        return Err((StatusCode::TOO_MANY_REQUESTS, t!("分享链接查询过多，请稍后重试", "Too many share link lookups. Try again later").to_string()));
    }
    // Both legacy eight-character codes and new twelve-character codes are valid.
    if matches!(code.len(), 8 | 12)
        && code.bytes().all(|byte| byte.is_ascii_alphanumeric())
        && let Some(share) = state.db.get_share_link(code).map_err(internal_err)?
    {
        return Ok(share);
    }
    state.failed_share_lookups.record_failure(ip);
    Err((StatusCode::NOT_FOUND, t!("分享链接不存在或已被撤销", "The share link doesn't exist or has been revoked").to_string()))
}

async fn public_share_page(Path(code): Path<String>) -> impl IntoResponse {
    // The landing page is static. The metadata and download routes look up
    // the code and enforce the shared miss limit.
    let safe_code: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let html = PUBLIC_SHARE_HTML
        .replace("__LANG__", crate::i18n::current().html_tag())
        .replace("__TITLE__", t!("DropDrawer 外链提取", "DropDrawer shared files"))
        .replace("__BRAND__", t!("DropDrawer 外链分享", "DropDrawer share"))
        .replace("__LOADING__", t!("正在加载分享信息...", "Loading the share…"))
        .replace("__SHARE_CODE__", &safe_code);
    ([(header::VARY, "Accept-Language")], Html(html))
}

fn generate_short_code() -> String {
    use rand::{distributions::Alphanumeric, rngs::OsRng, Rng};
    OsRng.sample_iter(Alphanumeric).take(12).map(char::from).collect()
}

const PUBLIC_SHARE_HTML: &str = include_str!("routes/public_share.html");

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

    validate_user_claims(&state, &claims)?;

    if state
        .db
        .get_device(&query.device_id, &claims.sub)
        .map_err(internal_err)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, t!("设备尚未注册，请重新登录", "This device isn't registered. Sign in again").to_string()));
    }

    Ok(ws.on_upgrade(move |socket| handle_ws(socket, state, claims, query.device_id)))
}

async fn handle_ws(socket: WebSocket, state: Arc<AppState>, claims: Claims, device_id: String) {
    const PING_INTERVAL: StdDuration = StdDuration::from_secs(20);
    const READ_TIMEOUT: StdDuration = StdDuration::from_secs(60);
    let (mut ws_sink, mut ws_stream) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<WsEvent>();
    let user_id = claims.sub.clone();
    let key = (user_id.clone(), device_id.clone());
    let is_current = || {
        state
            .connections
            .get(&key)
            .is_some_and(|current| current.same_channel(&tx))
    };

    {
        let _presence = state.presence_changes.lock().await;
        // Credentials can change between the HTTP upgrade and this callback.
        if validate_user_claims(&state, &claims).is_err() {
            return;
        }
        state.ready_files.remove(&key);
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
                Ok(WsClientCommand::UpdateReadyFiles { files }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    let Ok(replicas) = state.db.ready_replicas(&user_id, &device_id, &files) else {
                        continue;
                    };
                    state.ready_files.insert(key.clone(), replicas);
                    if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
                        state.fill_device_presence(&mut dev);
                        state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
                    }
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
                        state.fill_device_presence(&mut dev);
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
        state.ready_files.remove(&key);
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
