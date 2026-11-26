use std::sync::Arc;

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::FromRequestParts,
    http::{header, request::Parts, StatusCode},
};
use chrono::{Duration, Utc};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};

use crate::state::AppState;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub username: String,
    pub exp: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// Session generation; must match `users.token_version`. Absent in tokens issued
    /// before revocation existed, which therefore stay valid until the first revocation.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub ver: u64,
    /// Issue time (Unix seconds). Older tokens lack it; see [`Claims::issued_at`].
    #[serde(default, skip_serializing_if = "is_zero_usize")]
    pub iat: usize,
}

fn is_zero_usize(v: &usize) -> bool {
    *v == 0
}

/// Subject of admin tokens; named accounts use `"{ADMIN_SUBJECT}:{account_id}"`.
pub const ADMIN_SUBJECT: &str = "__dropdrawer_admin__";

/// Lifetime of user session tokens.
const USER_TOKEN_DAYS: i64 = 30;

fn is_zero(v: &u64) -> bool {
    *v == 0
}

impl Claims {
    /// When the token was issued; derived from `exp` for tokens without `iat`.
    pub fn issued_at(&self) -> chrono::DateTime<Utc> {
        let secs = if self.iat > 0 {
            self.iat as i64
        } else {
            self.exp as i64 - Duration::days(USER_TOKEN_DAYS).num_seconds()
        };
        chrono::DateTime::from_timestamp(secs, 0).unwrap_or_else(Utc::now)
    }

    pub fn is_admin(&self) -> bool {
        self.role.as_deref() == Some("admin")
            && (self.sub == ADMIN_SUBJECT || self.admin_account_id().is_some())
    }

    /// Named administrator account behind an admin token (`None` for the owner token).
    pub fn admin_account_id(&self) -> Option<&str> {
        self.sub
            .strip_prefix(ADMIN_SUBJECT)
            .and_then(|rest| rest.strip_prefix(':'))
            .filter(|id| !id.is_empty())
    }
}

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub user_id: String,
    pub username: String,
    pub issued_at: chrono::DateTime<Utc>,
}

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let hash = argon2
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("password hash failed: {e}"))?
        .to_string();
    Ok(hash)
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(hash) else {
        return false;
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok()
}

pub fn create_jwt(user_id: &str, username: &str, secret: &str) -> anyhow::Result<String> {
    create_versioned_jwt(user_id, username, 0, secret)
}

pub fn create_versioned_jwt(
    user_id: &str,
    username: &str,
    token_version: u64,
    secret: &str,
) -> anyhow::Result<String> {
    let now = Utc::now();
    let exp = (now + Duration::days(USER_TOKEN_DAYS)).timestamp() as usize;
    let claims = Claims {
        sub: user_id.to_string(),
        username: username.to_string(),
        exp,
        role: None,
        ver: token_version,
        iat: now.timestamp() as usize,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;
    Ok(token)
}

/// Admin session token. `ver` is the owner session epoch, or the account's token
/// version for a named administrator account.
pub fn create_admin_jwt(
    secret: &str,
    account: Option<(&str, &str)>,
    ver: u64,
) -> anyhow::Result<String> {
    let exp = (Utc::now() + Duration::hours(12)).timestamp() as usize;
    let (sub, username) = match account {
        Some((id, name)) => (format!("{ADMIN_SUBJECT}:{id}"), name.to_string()),
        None => (ADMIN_SUBJECT.to_string(), "owner".to_string()),
    };
    let epoch = ver;
    let claims = Claims {
        sub,
        username,
        exp,
        role: Some("admin".to_string()),
        ver: epoch,
        iat: Utc::now().timestamp() as usize,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;
    Ok(token)
}

pub fn decode_jwt(token: &str, secret: &str) -> anyhow::Result<Claims> {
    let data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::default(),
    )?;
    Ok(data.claims)
}

impl FromRequestParts<Arc<AppState>> for AuthUser {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(
        parts: &mut Parts,
        state: &Arc<AppState>,
    ) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok());

        let token = auth_header
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::trim)
            .ok_or_else(|| (StatusCode::UNAUTHORIZED, "missing bearer token".to_string()))?;

        let claims = decode_jwt(token, &state.jwt_secret)
            .map_err(|_| (StatusCode::UNAUTHORIZED, "invalid or expired token".to_string()))?;

        validate_user_claims(state, &claims)?;

        Ok(AuthUser {
            issued_at: claims.issued_at(),
            user_id: claims.sub,
            username: claims.username,
        })
    }
}

/// Sign a session token for `user_id` at its current revocation generation.
pub fn issue_user_token(state: &AppState, user_id: &str, username: &str) -> anyhow::Result<String> {
    let version = state
        .db
        .user_auth_state(user_id)?
        .map(|s| s.token_version)
        .unwrap_or(0);
    create_versioned_jwt(user_id, username, version, &state.jwt_secret)
}

/// Reject admin tokens, disabled or deleted accounts, and revoked sessions.
pub(crate) fn validate_user_claims(
    state: &AppState,
    claims: &Claims,
) -> Result<(), (StatusCode, String)> {
    if claims.is_admin() {
        return Err((
            StatusCode::UNAUTHORIZED,
            "admin session cannot access user endpoints".to_string(),
        ));
    }
    match state.db.user_auth_state(&claims.sub) {
        Ok(Some(auth)) if auth.disabled => Err((
            StatusCode::UNAUTHORIZED,
            "account is disabled or no longer exists".to_string(),
        )),
        Ok(Some(auth)) if auth.token_version != claims.ver => Err((
            StatusCode::UNAUTHORIZED,
            "session has been signed out, please log in again".to_string(),
        )),
        Ok(Some(_)) => Ok(()),
        _ => Err((
            StatusCode::UNAUTHORIZED,
            "account is disabled or no longer exists".to_string(),
        )),
    }
}
