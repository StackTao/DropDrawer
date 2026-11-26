//! Built-in `/admin` console (Vaultwarden style: one server-side admin token).
//!
//! Layout:
//! - [`auth`]      admin token verification, session cookie, login rate limiting
//! - [`assets`]    the single-page console (`ui/`) with a strict CSP
//! - [`dashboard`] overview statistics, system info, audit log, maintenance
//! - [`settings`]  runtime settings & feature switches, SMTP test
//! - [`users`]     accounts, per-user policy, devices, storage backends, items
//! - [`invites`] / [`shares`] invite codes and public share moderation
//! - [`accounts`]  named administrator accounts, own password / TOTP, backups
//! - [`totp`]      RFC 6238 two-step verification codes
//!
//! The console is disabled (404) unless `DROPDRAWER_ADMIN_TOKEN` is set.

use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::{request::Parts, StatusCode},
    routing::{delete, get, post, put},
    Router,
};

use crate::state::AppState;

mod accounts;
mod assets;
mod auth;
mod dashboard;
mod invites;
mod settings;
mod shares;
pub mod totp;
mod users;

pub use auth::{AdminAuthConfig, AdminSession, AdminTokenVerifier};

pub(crate) type ApiError = (StatusCode, String);
pub(crate) type ApiResult<T> = Result<T, ApiError>;

/// Routes for the admin page and `/api/admin/*`. Merged outside the CORS layer:
/// the console is only ever used same-origin.
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/admin", get(assets::page))
        .route("/admin/assets/{file}", get(assets::asset))
        .route("/api/admin/login", post(auth::login))
        .route("/api/admin/logout", post(auth::logout))
        .route("/api/admin/session", get(auth::session))
        .route("/api/admin/overview", get(dashboard::overview))
        .route("/api/admin/system", get(dashboard::system))
        .route("/api/admin/audit", get(dashboard::audit_log))
        .route("/api/admin/maintenance/cleanup", post(dashboard::cleanup_expired))
        .route("/api/admin/maintenance/backup", get(accounts::backup))
        .route("/api/admin/clients", get(dashboard::client_versions))
        .route("/api/admin/admins", get(accounts::list).post(accounts::create))
        .route(
            "/api/admin/admins/{id}",
            put(accounts::update).delete(accounts::delete),
        )
        .route("/api/admin/admins/{id}/reset-password", post(accounts::reset_password))
        .route("/api/admin/admins/{id}/reset-totp", post(accounts::reset_totp))
        .route("/api/admin/me/password", post(accounts::change_own_password))
        .route("/api/admin/me/totp/setup", post(accounts::totp_setup))
        .route("/api/admin/me/totp/enable", post(accounts::totp_enable))
        .route("/api/admin/me/totp/disable", post(accounts::totp_disable))
        .route(
            "/api/admin/settings",
            get(settings::get_settings).put(settings::update_settings),
        )
        .route("/api/admin/smtp/test", post(settings::test_smtp))
        .route("/api/admin/users", get(users::list))
        .route("/api/admin/users/{id}", get(users::detail).delete(users::delete_user))
        .route("/api/admin/users/{id}/disable", post(users::set_disabled))
        .route("/api/admin/users/{id}/reset-password", post(users::reset_password))
        .route("/api/admin/users/{id}/sign-out", post(users::sign_out))
        .route("/api/admin/users/{id}/policy", put(users::update_policy))
        .route("/api/admin/users/{id}/shares", delete(users::revoke_shares))
        .route(
            "/api/admin/users/{id}/devices/{device_id}",
            delete(users::remove_device),
        )
        .route(
            "/api/admin/users/{id}/backends/{backend_id}",
            delete(users::remove_backend),
        )
        .route(
            "/api/admin/users/{id}/items/{item_id}",
            delete(users::remove_item),
        )
        .route(
            "/api/admin/invites",
            get(invites::list).post(invites::create),
        )
        .route("/api/admin/invites/{code}", delete(invites::delete))
        .route("/api/admin/shares", get(shares::list))
        .route("/api/admin/shares/{code}", delete(shares::delete))
}

pub(crate) fn internal_err(err: impl std::fmt::Display) -> ApiError {
    tracing::error!("admin internal error: {err}");
    (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
}

pub(crate) fn not_found(what: &str) -> ApiError {
    (StatusCode::NOT_FOUND, format!("{what} not found"))
}

/// Best-effort client address for rate limiting and the audit log.
///
/// The socket peer is used directly unless it is a loopback / private address
/// (i.e. a reverse proxy in front of the server), in which case the first
/// `X-Forwarded-For` / `X-Real-IP` entry is trusted instead.
#[derive(Debug, Clone)]
pub struct ClientIp(pub String);

impl<S: Send + Sync> FromRequestParts<S> for ClientIp {
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let forwarded = parts
            .headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(',').next())
            .or_else(|| parts.headers.get("x-real-ip").and_then(|v| v.to_str().ok()))
            .map(str::trim)
            .and_then(|v| v.parse::<IpAddr>().ok());
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|ConnectInfo(addr)| addr.ip());
        let ip = match (peer, forwarded) {
            (Some(peer), Some(fwd)) if crate::policy::is_restricted_ip(peer) => fwd,
            (Some(peer), _) => peer,
            (None, Some(fwd)) => fwd,
            (None, None) => return Ok(Self("unknown".to_string())),
        };
        Ok(Self(ip.to_string()))
    }
}

/// Append an admin action to the audit log; failures are logged, never surfaced.
pub(crate) fn audit(
    state: &AppState,
    session: &AdminSession,
    action: &str,
    target: Option<&str>,
    detail: Option<&str>,
) {
    if let Err(err) = state
        .db
        .record_audit(&session.actor, action, target, detail, Some(&session.ip))
    {
        tracing::warn!("failed to write admin audit entry: {err}");
    }
}
