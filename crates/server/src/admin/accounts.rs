//! Named administrator accounts (super administrators only), the signed-in
//! administrator's own password / two-step settings, and database backups.

use std::sync::Arc;

use axum::{
    body::Body,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};

use super::auth::{account_token, session_cookie};
use super::{audit, internal_err, not_found, totp, AdminSession, ApiError, ApiResult};
use crate::auth::{hash_password, verify_password};
use crate::db::{AdminAccount, AdminAccountSummary, AdminRole};
use crate::state::AppState;

const MIN_PASSWORD_LEN: usize = 10;

fn bad_request(msg: impl Into<String>) -> ApiError {
    (StatusCode::BAD_REQUEST, msg.into())
}

fn validate_admin_username(name: &str) -> Result<(), ApiError> {
    let len = name.chars().count();
    if !(2..=32).contains(&len)
        || !name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | '@'))
    {
        return Err(bad_request(
            "管理员用户名需为 2-32 位字母、数字或 _ - . @",
        ));
    }
    Ok(())
}

fn validate_admin_password(password: &str) -> Result<(), ApiError> {
    if password.chars().count() < MIN_PASSWORD_LEN {
        return Err(bad_request(format!(
            "管理员密码至少 {MIN_PASSWORD_LEN} 位"
        )));
    }
    Ok(())
}

async fn hash_blocking(password: String) -> ApiResult<String> {
    tokio::task::spawn_blocking(move || hash_password(&password))
        .await
        .map_err(internal_err)?
        .map_err(internal_err)
}

fn require_account(state: &AppState, id: &str) -> ApiResult<AdminAccount> {
    state
        .db
        .get_admin_account(id)
        .map_err(internal_err)?
        .ok_or_else(|| not_found("admin account"))
}

/// Management endpoints never act on the caller's own account (use `/me` instead),
/// so a super administrator cannot lock themselves out by accident.
fn not_self(session: &AdminSession, id: &str) -> Result<(), ApiError> {
    if session.account_id == id {
        return Err(bad_request("请在「我的账号」中修改自己的账号"));
    }
    Ok(())
}

// ---- Super administrator: account management -----------------------------------

pub(super) async fn list(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Vec<AdminAccountSummary>>> {
    admin.require_super()?;
    let accounts = state.db.list_admin_accounts().map_err(internal_err)?;
    Ok(Json(accounts.iter().map(AdminAccountSummary::from).collect()))
}

#[derive(Debug, Deserialize)]
pub(super) struct CreateAdminRequest {
    username: String,
    password: String,
    role: AdminRole,
}

pub(super) async fn create(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateAdminRequest>,
) -> ApiResult<Json<AdminAccountSummary>> {
    admin.require_super()?;
    let username = req.username.trim();
    validate_admin_username(username)?;
    validate_admin_password(&req.password)?;
    if state
        .db
        .find_admin_account(username)
        .map_err(internal_err)?
        .is_some()
    {
        return Err((StatusCode::CONFLICT, "该管理员用户名已存在".to_string()));
    }
    let id = uuid::Uuid::new_v4().to_string();
    let hash = hash_blocking(req.password).await?;
    state
        .db
        .create_admin_account(&id, username, &hash, req.role)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "admin_account.create",
        Some(username),
        Some(req.role.as_str()),
    );
    let account = require_account(&state, &id)?;
    Ok(Json(AdminAccountSummary::from(&account)))
}

#[derive(Debug, Deserialize)]
pub(super) struct UpdateAdminRequest {
    role: AdminRole,
    disabled: bool,
}

pub(super) async fn update(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateAdminRequest>,
) -> ApiResult<Json<AdminAccountSummary>> {
    admin.require_super()?;
    not_self(&admin, &id)?;
    let account = require_account(&state, &id)?;
    state
        .db
        .update_admin_account(&id, req.role, req.disabled)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "admin_account.update",
        Some(&account.username),
        Some(&format!("role={} disabled={}", req.role.as_str(), req.disabled)),
    );
    Ok(Json(AdminAccountSummary::from(&require_account(&state, &id)?)))
}

#[derive(Debug, Deserialize)]
pub(super) struct PasswordRequest {
    new_password: String,
}

pub(super) async fn reset_password(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<PasswordRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    admin.require_super()?;
    not_self(&admin, &id)?;
    validate_admin_password(&req.new_password)?;
    let account = require_account(&state, &id)?;
    let hash = hash_blocking(req.new_password).await?;
    state.db.set_admin_password(&id, &hash).map_err(internal_err)?;
    audit(&state, &admin, "admin_account.reset_password", Some(&account.username), None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn reset_totp(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    admin.require_super()?;
    not_self(&admin, &id)?;
    let account = require_account(&state, &id)?;
    state
        .db
        .set_admin_totp_enabled(&id, false)
        .map_err(internal_err)?;
    state.db.bump_admin_token_version(&id).map_err(internal_err)?;
    audit(&state, &admin, "admin_account.reset_totp", Some(&account.username), None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn delete(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    admin.require_super()?;
    not_self(&admin, &id)?;
    let account = require_account(&state, &id)?;
    state.db.delete_admin_account(&id).map_err(internal_err)?;
    audit(&state, &admin, "admin_account.delete", Some(&account.username), None);
    Ok(StatusCode::NO_CONTENT)
}

// ---- The signed-in administrator ------------------------------------------------

fn own_account(state: &AppState, session: &AdminSession) -> ApiResult<AdminAccount> {
    require_account(state, &session.account_id)
}

#[derive(Debug, Deserialize)]
pub(super) struct ChangeOwnPasswordRequest {
    current_password: String,
    new_password: String,
}

/// Change the caller's password; other sessions end and this one gets a new cookie.
pub(super) async fn change_own_password(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<ChangeOwnPasswordRequest>,
) -> ApiResult<Response> {
    let account = own_account(&state, &admin)?;
    validate_admin_password(&req.new_password)?;
    let (current, hash) = (req.current_password, account.password_hash.clone());
    let ok = tokio::task::spawn_blocking(move || verify_password(&current, &hash))
        .await
        .unwrap_or(false);
    if !ok {
        return Err(bad_request("当前密码不正确"));
    }
    let new_hash = hash_blocking(req.new_password).await?;
    state
        .db
        .set_admin_password(&account.id, &new_hash)
        .map_err(internal_err)?;
    audit(&state, &admin, "admin.change_password", None, None);
    let refreshed = require_account(&state, &account.id)?;
    let token = account_token(&state, &refreshed)?;
    Ok((
        StatusCode::OK,
        [(header::SET_COOKIE, session_cookie(&headers, &token))],
        Json(serde_json::json!({ "ok": true })),
    )
        .into_response())
}

#[derive(Debug, Serialize)]
pub(super) struct TotpSetup {
    secret: String,
    otpauth_uri: String,
    qr_data_uri: Option<String>,
}

/// Start (or restart) two-step enrollment. Takes effect only after `totp_enable`.
pub(super) async fn totp_setup(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<TotpSetup>> {
    let account = own_account(&state, &admin)?;
    if account.totp_enabled {
        return Err(bad_request("两步验证已启用，如需更换请先关闭"));
    }
    let secret = totp::generate_secret();
    state
        .db
        .set_admin_totp_pending(&account.id, &secret)
        .map_err(internal_err)?;
    let uri = totp::otpauth_uri("DropDrawer Admin", &account.username, &secret);
    Ok(Json(TotpSetup {
        qr_data_uri: totp::qr_svg_data_uri(&uri),
        otpauth_uri: uri,
        secret,
    }))
}

#[derive(Debug, Deserialize)]
pub(super) struct TotpCodeRequest {
    code: String,
}

fn check_code(state: &AppState, account: &AdminAccount, code: &str) -> Result<(), ApiError> {
    let secret = account
        .totp_secret
        .as_deref()
        .ok_or_else(|| bad_request("请先生成两步验证密钥"))?;
    let step = totp::verify(secret, code, chrono::Utc::now().timestamp())
        .ok_or_else(|| bad_request("验证码不正确，请检查手机时间是否准确"))?;
    if !state
        .db
        .consume_admin_totp_step(&account.id, step)
        .map_err(internal_err)?
    {
        return Err(bad_request("该验证码已使用，请等待下一个"));
    }
    Ok(())
}

pub(super) async fn totp_enable(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<TotpCodeRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let account = own_account(&state, &admin)?;
    check_code(&state, &account, &req.code)?;
    state
        .db
        .set_admin_totp_enabled(&account.id, true)
        .map_err(internal_err)?;
    audit(&state, &admin, "admin.totp_enable", None, None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub(super) async fn totp_disable(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<TotpCodeRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let account = own_account(&state, &admin)?;
    if !account.totp_enabled {
        return Err(bad_request("两步验证尚未启用"));
    }
    check_code(&state, &account, &req.code)?;
    state
        .db
        .set_admin_totp_enabled(&account.id, false)
        .map_err(internal_err)?;
    audit(&state, &admin, "admin.totp_disable", None, None);
    Ok(Json(serde_json::json!({ "ok": true })))
}

// ---- Backup ----------------------------------------------------------------------

/// Download a consistent snapshot of the SQLite database (super administrators only).
/// File blobs in local storage are not included.
pub(super) async fn backup(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Response> {
    admin.require_super()?;
    let path = std::env::temp_dir().join(format!(
        "dropdrawer-backup-{}.db",
        uuid::Uuid::new_v4()
    ));
    let db = state.db.clone();
    let target = path.clone();
    let bytes = tokio::task::spawn_blocking(move || -> anyhow::Result<Vec<u8>> {
        db.backup_to(&target)?;
        let bytes = std::fs::read(&target)?;
        Ok(bytes)
    })
    .await
    .map_err(internal_err)?;
    let _ = std::fs::remove_file(&path);
    let bytes = bytes.map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "maintenance.backup",
        None,
        Some(&format!("bytes={}", bytes.len())),
    );
    let filename = format!(
        "dropdrawer-backup-{}.db",
        chrono::Utc::now().format("%Y%m%d-%H%M%S")
    );
    Ok((
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/vnd.sqlite3".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{filename}\""),
            ),
            (header::CACHE_CONTROL, "no-store".to_string()),
        ],
        Body::from(bytes),
    )
        .into_response())
}

/// Manage bootstrap and recovery directly against the server's SQLite database.
pub fn local_account_command(state: &AppState, args: &[String]) -> anyhow::Result<()> {
    match args {
        [command, username] if command == "admin-account" => {
            let username = username.trim();
            validate_admin_username(username).map_err(|(_, message)| anyhow::anyhow!(message))?;
            let mut password = String::new();
            std::io::stdin().read_line(&mut password)?;
            let password = password.trim_end_matches(['\r', '\n']);
            validate_admin_password(password).map_err(|(_, message)| anyhow::anyhow!(message))?;
            let hash = crate::auth::hash_password(password)?;
            if let Some(account) = state.db.find_admin_account(username)? {
                state.db.set_admin_password(&account.id, &hash)?;
            } else {
                state.db.create_admin_account(&uuid::Uuid::new_v4().to_string(), username, &hash, AdminRole::Super)?;
            }
            println!("Administrator password saved");
        }
        [command] if command == "admin-disable-turnstile" => {
            let mut settings = state.runtime_settings();
            settings.admin_turnstile.enabled = false;
            state.apply_and_persist_settings(settings)?;
            println!("Turnstile disabled. Restart the service to load the updated settings.");
        }
        _ => anyhow::bail!("Usage: dropdrawer-server admin-account <username> | admin-disable-turnstile"),
    }
    Ok(())
}
