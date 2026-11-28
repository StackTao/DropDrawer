use std::sync::Arc;

use axum::{
    Json,
    extract::{FromRequestParts, State},
    http::{HeaderMap, Method, StatusCode, header, request::Parts},
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};

use super::{ApiError, ApiResult, ClientIp, internal_err, totp};
use crate::auth::{create_admin_jwt, decode_jwt, verify_password};
use crate::db::{AdminAccount, AdminRole};
use crate::state::AppState;

pub(super) const ADMIN_COOKIE_NAME: &str = "dd_admin_session";
const ADMIN_SESSION_SECS: i64 = 12 * 60 * 60;
const GLOBAL_LIMIT_KEY: &str = "__all__";

/// An authenticated admin request.
pub struct AdminSession {
    pub ip: String,
    pub expires_at: usize,
    /// Name written to the audit log.
    pub actor: String,
    pub role: AdminRole,
    /// Account behind the session.
    pub account_id: String,
}

impl AdminSession {
    pub fn require_super(&self) -> Result<(), ApiError> {
        if self.role == AdminRole::Super {
            Ok(())
        } else {
            Err((
                StatusCode::FORBIDDEN,
                t!("仅超级管理员可执行此操作", "Only super administrators can do this").to_string(),
            ))
        }
    }
}

/// Endpoints a read-only administrator may still call with a non-GET method.
fn viewer_may_write(path: &str) -> bool {
    path == "/api/admin/logout" || path.starts_with("/api/admin/me/")
}

fn unauthorized(msg: &str) -> ApiError {
    (StatusCode::UNAUTHORIZED, msg.to_string())
}

impl FromRequestParts<Arc<AppState>> for AdminSession {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        if !state.admin_enabled {
            return Err((
                StatusCode::NOT_FOUND,
                "admin console is disabled on this server".to_string(),
            ));
        }
        let bearer = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::trim);
        let cookie_tok = parts
            .headers
            .get(header::COOKIE)
            .and_then(|v| v.to_str().ok())
            .and_then(extract_admin_cookie);
        let token = bearer
            .or(cookie_tok)
            .ok_or_else(|| unauthorized("admin authentication required"))?;
        let claims = decode_jwt(token, &state.jwt_secret)
            .map_err(|_| unauthorized("invalid or expired admin session"))?;
        if !claims.is_admin() {
            return Err((
                StatusCode::FORBIDDEN,
                "admin privileges required".to_string(),
            ));
        }
        let id = claims
            .admin_account_id()
            .ok_or_else(|| unauthorized("invalid or expired admin session"))?;
        let account = state
            .db
            .get_admin_account(id)
            .map_err(internal_err)?
            .filter(|a| !a.disabled && a.token_version == claims.ver)
            .ok_or_else(|| unauthorized("admin session has been signed out"))?;
        let (actor, role, account_id) = (account.username, account.role, account.id);
        if role == AdminRole::Viewer
            && parts.method != Method::GET
            && !viewer_may_write(parts.uri.path())
        {
            return Err((StatusCode::FORBIDDEN, t!("只读管理员不能修改数据", "Read-only administrators can't change data").to_string()));
        }
        let ClientIp(ip) = match ClientIp::from_request_parts(parts, state).await {
            Ok(ip) => ip,
            Err(never) => match never {},
        };
        Ok(AdminSession {
            ip,
            expires_at: claims.exp,
            actor,
            role,
            account_id,
        })
    }
}

fn extract_admin_cookie(cookie_header: &str) -> Option<&str> {
    cookie_header.split(';').find_map(|part| {
        part.trim()
            .strip_prefix(ADMIN_COOKIE_NAME)
            .and_then(|rest| rest.strip_prefix('='))
            .map(str::trim)
            .filter(|v| !v.is_empty())
    })
}

#[derive(Deserialize)]
pub(super) struct AdminLoginRequest {
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    totp_code: Option<String>,
    turnstile_token: Option<String>,
}

/// Body returned with 401 when the password was right but a TOTP code is needed.
pub(super) const TOTP_REQUIRED: &str = "TOTP_REQUIRED";

pub(super) fn session_cookie(headers: &HeaderMap, token: &str) -> String {
    let is_https = headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|p| p.eq_ignore_ascii_case("https"));
    let secure_attr = if is_https { "; Secure" } else { "" };
    format!(
        "{ADMIN_COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={ADMIN_SESSION_SECS}{secure_attr}"
    )
}

pub(super) fn session_response(headers: &HeaderMap, token: String) -> Response {
    (
        StatusCode::OK,
        [
            (header::SET_COOKIE, session_cookie(headers, &token)),
            (header::CACHE_CONTROL, "no-store".to_string()),
        ],
        Json(serde_json::json!({ "token": token })),
    )
        .into_response()
}

/// Issue a fresh session token for a named account at its current token version.
pub(super) fn account_token(state: &AppState, account: &AdminAccount) -> ApiResult<String> {
    create_admin_jwt(
        &state.jwt_secret,
        Some((&account.id, &account.username)),
        account.token_version,
    )
    .map_err(internal_err)
}

async fn verify_password_blocking(password: String, hash: String) -> bool {
    tokio::task::spawn_blocking(move || verify_password(&password, &hash))
        .await
        .unwrap_or(false)
}

pub(super) fn check_login_limit(state: &AppState, ip: &str) -> ApiResult<()> {
    // While the server-wide ceiling is hit, addresses that already failed are
    // refused, but an address with a clean record keeps one try. Otherwise a
    // handful of proxies could lock every administrator out indefinitely.
    if state.failed_admin_logins.is_blocked(ip)
        || (state
            .failed_admin_logins_global
            .is_blocked(GLOBAL_LIMIT_KEY)
            && state.failed_admin_logins.has_failures(ip))
    {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("尝试次数过多，请 15 分钟后再试", "Too many attempts. Try again in 15 minutes").to_string(),
        ));
    }
    Ok(())
}

pub(super) fn fail_login(state: &AppState, ip: &str, who: Option<&str>, msg: &str) -> ApiError {
    state.failed_admin_logins.record_failure(ip);
    state
        .failed_admin_logins_global
        .record_failure(GLOBAL_LIMIT_KEY);
    let _ = state.db.record_audit(
        who.unwrap_or("anonymous"),
        "admin.login_failed",
        who,
        None,
        Some(ip),
    );
    unauthorized(msg)
}

pub(super) fn verify_totp(
    state: &AppState,
    account: &AdminAccount,
    ip: &str,
    code: &str,
) -> ApiResult<()> {
    let secret = account.totp_secret.as_deref().unwrap_or_default();
    let fresh = match totp::verify(secret, code, chrono::Utc::now().timestamp()) {
        Some(step) => state
            .db
            .consume_admin_totp_step(&account.id, step)
            .map_err(internal_err)?,
        None => false,
    };
    if !fresh {
        return Err(fail_login(
            state,
            ip,
            Some(&account.username),
            t!("两步验证码错误或已使用", "The two-step verification code is wrong or already used"),
        ));
    }
    Ok(())
}

pub(super) fn complete_login(
    state: &AppState,
    account: &AdminAccount,
    ip: &str,
    method: Option<&str>,
) -> ApiResult<String> {
    let token = account_token(state, account)?;
    state.failed_admin_logins.reset(ip);
    let _ = state.db.touch_admin_login(&account.id);
    let _ = state
        .db
        .record_audit(&account.username, "admin.login", None, method, Some(ip));
    Ok(token)
}

pub(super) async fn login(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    headers: HeaderMap,
    Json(req): Json<AdminLoginRequest>,
) -> ApiResult<Response> {
    if !state.admin_enabled {
        return Err((
            StatusCode::NOT_FOUND,
            "admin console is disabled on this server".to_string(),
        ));
    }
    check_login_limit(&state, &ip)?;
    // Named administrator account.
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();
    if username.trim().is_empty() || password.is_empty() {
        return Err((StatusCode::BAD_REQUEST, t!("请输入用户名和密码", "Enter a username and password").to_string()));
    }
    super::turnstile::verify(&state, &ip, req.turnstile_token.as_deref()).await?;
    let account = state
        .db
        .find_admin_account(&username)
        .map_err(internal_err)?;
    // Verify against a dummy hash when the account is unknown to keep timing uniform.
    let hash = account
        .as_ref()
        .map(|a| a.password_hash.clone())
        .unwrap_or_else(dummy_hash);
    let password_ok = verify_password_blocking(password, hash).await;
    let Some(account) = account.filter(|a| password_ok && !a.disabled) else {
        return Err(fail_login(
            &state,
            &ip,
            Some(username.trim()),
            t!("用户名或密码错误", "Incorrect username or password"),
        ));
    };
    if account.totp_enabled {
        let Some(code) = req.totp_code.filter(|c| !c.trim().is_empty()) else {
            return Err(unauthorized(TOTP_REQUIRED));
        };
        verify_totp(&state, &account, &ip, &code)?;
    }
    let token = complete_login(
        &state,
        &account,
        &ip,
        account.totp_enabled.then_some("totp"),
    )?;
    Ok(session_response(&headers, token))
}

/// Real Argon2 hash verified when the username does not exist, so the response
/// time does not reveal which administrator names are valid.
fn dummy_hash() -> String {
    static DUMMY: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    DUMMY
        .get_or_init(|| crate::auth::hash_password(&totp::generate_secret()).unwrap_or_default())
        .clone()
}

/// Sign out and revoke the account session.
pub(super) async fn logout(
    State(state): State<Arc<AppState>>,
    session: Result<AdminSession, (StatusCode, String)>,
) -> Response {
    if let Ok(session) = session {
        super::audit(&state, &session, "admin.logout", None, None);
        let _ = state.db.bump_admin_token_version(&session.account_id);
    }
    let cookie = format!("{ADMIN_COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
    (
        StatusCode::OK,
        [(header::SET_COOKIE, cookie)],
        Json(serde_json::json!({ "ok": true })),
    )
        .into_response()
}

#[derive(Debug, Serialize)]
pub(super) struct SessionInfo {
    ok: bool,
    expires_at: usize,
    actor: String,
    role: AdminRole,
    totp_enabled: bool,
}

pub(super) async fn session(
    State(state): State<Arc<AppState>>,
    session: AdminSession,
) -> ApiResult<Json<SessionInfo>> {
    let totp_enabled = state
        .db
        .get_admin_account(&session.account_id)
        .map_err(internal_err)?
        .is_some_and(|a| a.totp_enabled);
    Ok(Json(SessionInfo {
        ok: true,
        expires_at: session.expires_at,
        actor: session.actor,
        role: session.role,
        totp_enabled,
    }))
}
