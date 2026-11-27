use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    Json,
    extract::{Query, State},
    http::StatusCode,
    response::Response,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    policy,
    state::{AppState, PendingGoogleOAuth},
};

#[derive(Debug, Deserialize)]
pub(super) struct GoogleOAuthStartRequest {
    name: String,
    client_id: String,
    client_secret: String,
    #[serde(default)]
    folder_id: String,
    #[serde(default)]
    is_default: bool,
    redirect_uri: String,
}

pub(super) async fn start_google_oauth(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<GoogleOAuthStartRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    policy::ensure_backend_kind_allowed(
        &state.runtime_settings().storage_policy,
        protocol::StorageBackendKind::GoogleDrive,
    )?;
    let nonce = Uuid::new_v4().to_string();
    let folder_id = if req.folder_id.trim().is_empty() {
        "root".to_string()
    } else {
        req.folder_id.trim().to_string()
    };
    state.pending_google_oauth.insert(
        nonce.clone(),
        PendingGoogleOAuth {
            user_id: auth.user_id,
            name: req.name.trim().to_string(),
            client_id: req.client_id.trim().to_string(),
            client_secret: req.client_secret.trim().to_string(),
            folder_id,
            is_default: req.is_default,
            redirect_uri: req.redirect_uri.trim().to_string(),
            expires_at: Instant::now() + Duration::from_secs(10 * 60),
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

#[derive(Deserialize)]
pub(super) struct GoogleOAuthCallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

#[derive(Deserialize)]
struct GoogleTokenResponse {
    refresh_token: Option<String>,
}

pub(super) async fn google_oauth_callback(
    State(state): State<Arc<AppState>>,
    Query(query): Query<GoogleOAuthCallbackQuery>,
) -> Response {
    let pending = query.state.and_then(|nonce| {
        state
            .pending_google_oauth
            .remove(&nonce)
            .map(|(_, pending)| pending)
    });
    if query.error.is_some() {
        return callback_page(StatusCode::BAD_REQUEST, t!("授权已取消或失败", "Authorization was canceled or failed"));
    }
    let Some(code) = query.code else {
        return callback_page(StatusCode::BAD_REQUEST, t!("缺少授权参数", "Missing authorization parameters"));
    };
    let Some(pending) = pending.filter(|pending| pending.expires_at > Instant::now()) else {
        return callback_page(
            StatusCode::BAD_REQUEST,
            t!("授权会话已过期，请回到 DropDrawer 重新发起", "The authorization session has expired. Return to DropDrawer and start again"),
        );
    };

    let response = state
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
    let Ok(response) = response else {
        return callback_page(StatusCode::BAD_GATEWAY, t!("无法连接 Google OAuth 服务器", "Can't reach the Google OAuth server"));
    };
    if !response.status().is_success() {
        return callback_page(StatusCode::BAD_GATEWAY, t!("换取 Google 授权令牌失败", "Couldn't exchange the Google authorization code"));
    }

    let Ok(tokens) = response.json::<GoogleTokenResponse>().await else {
        return callback_page(StatusCode::BAD_GATEWAY, t!("Google 授权响应格式无效", "Invalid Google authorization response"));
    };
    let Some(refresh_token) = tokens.refresh_token.filter(|token| !token.is_empty()) else {
        return callback_page(
            StatusCode::BAD_GATEWAY,
            t!("Google 未返回刷新令牌，请重新授权并确认已同意权限", "Google didn't return a refresh token. Authorize again and make sure you accept the permissions"),
        );
    };
    let config = protocol::StorageBackendConfig::GoogleDrive {
        client_id: pending.client_id,
        client_secret: pending.client_secret,
        refresh_token,
        folder_id: pending.folder_id,
        api_base_url: None,
        token_url: None,
    };
    if state
        .db
        .create_storage_backend(
            &Uuid::new_v4().to_string(),
            &pending.user_id,
            &pending.name,
            &config,
            pending.is_default,
        )
        .is_err()
    {
        tracing::warn!("failed to save Google Drive authorization");
        return callback_page(StatusCode::INTERNAL_SERVER_ERROR, t!("保存存储配置失败", "Couldn't save the storage settings"));
    }

    callback_page(
        StatusCode::OK,
        t!("Google Drive 已成功绑定。可以关闭此页面，回到 DropDrawer 点击刷新。", "Google Drive is connected. You can close this page and click Refresh in DropDrawer."),
    )
}

// All messages are server-authored literals. Callback inputs and token responses
// never become part of the HTML.
fn callback_page(status: StatusCode, message: &'static str) -> Response {
    let ok = status.is_success();
    let title = if ok {
        t!("Google Drive 绑定成功", "Google Drive connected")
    } else {
        t!("Google Drive 绑定未完成", "Google Drive wasn't connected")
    };
    let hint = if ok {
        t!("此标签页可安全关闭，回到 DropDrawer 点击刷新即可使用", "You can close this tab. Click Refresh in DropDrawer to start using it")
    } else {
        t!("你可以关闭此页面，回到 DropDrawer 重新发起授权", "You can close this page and return to DropDrawer to authorize again")
    };
    crate::google_login::render_oauth_result_page(status, ok, title, message, hint)
}
