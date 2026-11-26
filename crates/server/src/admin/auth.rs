//! Admin authentication: the `DROPDRAWER_ADMIN_TOKEN` owner login, named
//! administrator accounts with roles and optional TOTP, the session cookie and
//! login rate limiting.

use std::sync::Arc;

use axum::{
    extract::{FromRequestParts, State},
    http::{header, request::Parts, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{internal_err, totp, ApiError, ApiResult, ClientIp};
use crate::auth::{create_admin_jwt, decode_jwt, verify_password};
use crate::db::{AdminAccount, AdminRole};
use crate::state::AppState;

pub(super) const ADMIN_COOKIE_NAME: &str = "dd_admin_session";
const ADMIN_SESSION_SECS: i64 = 12 * 60 * 60;
const GLOBAL_LIMIT_KEY: &str = "__all__";

#[derive(Clone)]
pub enum AdminTokenVerifier {
    Argon2Hash(String),
    PlainSha256([u8; 32]),
}

#[derive(Clone)]
pub struct AdminAuthConfig {
    verifier: AdminTokenVerifier,
}

impl AdminAuthConfig {
    pub fn from_token(raw: Option<&str>) -> Option<Self> {
        let trimmed = raw?.trim();
        if trimmed.is_empty() {
            return None;
        }
        let verifier = if trimmed.starts_with("$argon2") {
            AdminTokenVerifier::Argon2Hash(trimmed.to_string())
        } else {
            let digest = Sha256::digest(trimmed.as_bytes());
            let mut buf = [0u8; 32];
            buf.copy_from_slice(&digest);
            AdminTokenVerifier::PlainSha256(buf)
        };
        Some(Self { verifier })
    }

    /// `true` when the token is configured as an Argon2 PHC hash rather than plaintext.
    pub fn is_hashed(&self) -> bool {
        matches!(self.verifier, AdminTokenVerifier::Argon2Hash(_))
    }

    pub fn verify(&self, candidate: &str) -> bool {
        match &self.verifier {
            AdminTokenVerifier::Argon2Hash(hash) => verify_password(candidate, hash),
            AdminTokenVerifier::PlainSha256(expected) => {
                let got = Sha256::digest(candidate.as_bytes());
                let mut diff = 0u8;
                for (a, b) in expected.iter().zip(got.iter()) {
                    diff |= a ^ b;
                }
                diff == 0
            }
        }
    }
}

/// An authenticated admin request.
pub struct AdminSession {
    pub ip: String,
    pub expires_at: usize,
    /// Name written to the audit log (`owner` for the admin-token login).
    pub actor: String,
    pub role: AdminRole,
    /// Named account behind the session; `None` for the owner token.
    pub account_id: Option<String>,
}

impl AdminSession {
    pub fn require_super(&self) -> Result<(), ApiError> {
        if self.role == AdminRole::Super {
            Ok(())
        } else {
            Err((StatusCode::FORBIDDEN, "仅超级管理员可执行此操作".to_string()))
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
        if state.admin_auth.is_none() {
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
        let (actor, role, account_id) = match claims.admin_account_id() {
            None => {
                if claims.ver != state.admin_epoch() {
                    return Err(unauthorized("admin session has been signed out"));
                }
                ("owner".to_string(), AdminRole::Super, None)
            }
            Some(id) => {
                let account = state
                    .db
                    .get_admin_account(id)
                    .map_err(internal_err)?
                    .filter(|a| !a.disabled && a.token_version == claims.ver)
                    .ok_or_else(|| unauthorized("admin session has been signed out"))?;
                (account.username, account.role, Some(account.id))
            }
        };
        if role == AdminRole::Viewer
            && parts.method != Method::GET
            && !viewer_may_write(parts.uri.path())
        {
            return Err((StatusCode::FORBIDDEN, "只读管理员不能修改数据".to_string()));
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

/// Either the owner token, or an account username + password (+ TOTP code).
#[derive(Debug, Deserialize)]
pub(super) struct AdminLoginRequest {
    #[serde(default)]
    token: Option<String>,
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    totp_code: Option<String>,
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

fn session_response(headers: &HeaderMap, token: String) -> Response {
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

pub(super) async fn login(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    headers: HeaderMap,
    Json(req): Json<AdminLoginRequest>,
) -> ApiResult<Response> {
    let Some(admin_auth) = state.admin_auth.clone() else {
        return Err((
            StatusCode::NOT_FOUND,
            "admin console is disabled on this server".to_string(),
        ));
    };
    let ip_key = format!("ip:{ip}");
    if state.failed_admin_logins.is_blocked(&ip_key)
        || state.failed_admin_logins_global.is_blocked(GLOBAL_LIMIT_KEY)
    {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "尝试次数过多，请 15 分钟后再试".to_string(),
        ));
    }
    let fail = |who: Option<&str>, msg: &str| {
        state.failed_admin_logins.record_failure(&ip_key);
        state.failed_admin_logins_global.record_failure(GLOBAL_LIMIT_KEY);
        let _ = state.db.record_audit(
            who.unwrap_or("anonymous"),
            "admin.login_failed",
            who,
            None,
            Some(&ip),
        );
        unauthorized(msg)
    };

    // Owner login with the server's admin token.
    if let Some(candidate) = req.token.filter(|t| !t.is_empty()) {
        let valid = tokio::task::spawn_blocking(move || admin_auth.verify(&candidate))
            .await
            .unwrap_or(false);
        if !valid {
            return Err(fail(None, "管理员密钥错误"));
        }
        state.failed_admin_logins.reset(&ip_key);
        let _ = state
            .db
            .record_audit("owner", "admin.login", None, None, Some(&ip));
        let token = create_admin_jwt(&state.jwt_secret, None, state.admin_epoch())
            .map_err(internal_err)?;
        return Ok(session_response(&headers, token));
    }

    // Named administrator account.
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();
    if username.trim().is_empty() || password.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "请输入用户名和密码，或使用管理员密钥登录".to_string(),
        ));
    }
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
        return Err(fail(Some(username.trim()), "用户名或密码错误"));
    };
    if account.totp_enabled {
        let Some(code) = req.totp_code.filter(|c| !c.trim().is_empty()) else {
            return Err(unauthorized(TOTP_REQUIRED));
        };
        let secret = account.totp_secret.clone().unwrap_or_default();
        let step = totp::verify(&secret, &code, chrono::Utc::now().timestamp());
        let fresh = match step {
            Some(step) => state
                .db
                .consume_admin_totp_step(&account.id, step)
                .map_err(internal_err)?,
            None => false,
        };
        if !fresh {
            return Err(fail(Some(&account.username), "两步验证码错误或已使用"));
        }
    }
    state.failed_admin_logins.reset(&ip_key);
    let _ = state.db.touch_admin_login(&account.id);
    let _ = state.db.record_audit(
        &account.username,
        "admin.login",
        None,
        account.totp_enabled.then_some("totp"),
        Some(&ip),
    );
    let token = account_token(&state, &account)?;
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

/// Sign out. The owner token ends every owner session; an account ends its own sessions.
pub(super) async fn logout(
    State(state): State<Arc<AppState>>,
    session: Result<AdminSession, (StatusCode, String)>,
) -> Response {
    if let Ok(session) = session {
        super::audit(&state, &session, "admin.logout", None, None);
        match &session.account_id {
            Some(id) => {
                let _ = state.db.bump_admin_token_version(id);
            }
            None => state.revoke_admin_sessions(),
        }
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
    is_owner: bool,
    totp_enabled: bool,
}

pub(super) async fn session(
    State(state): State<Arc<AppState>>,
    session: AdminSession,
) -> ApiResult<Json<SessionInfo>> {
    let totp_enabled = match &session.account_id {
        Some(id) => state
            .db
            .get_admin_account(id)
            .map_err(internal_err)?
            .is_some_and(|a| a.totp_enabled),
        None => false,
    };
    Ok(Json(SessionInfo {
        ok: true,
        expires_at: session.expires_at,
        is_owner: session.account_id.is_none(),
        actor: session.actor,
        role: session.role,
        totp_enabled,
    }))
}
