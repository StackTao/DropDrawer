//! Invite codes for the "invite only" registration mode.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use chrono::{Duration, Utc};
use rand::{rngs::OsRng, Rng};
use serde::Deserialize;

use super::{audit, internal_err, not_found, AdminSession, ApiResult};
use crate::db::InviteCodeRecord;
use crate::state::AppState;

/// Unambiguous alphabet (no 0/O/1/I); 32 symbols, so sampling has no modulo bias.
const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LEN: usize = 10;

fn generate_code() -> String {
    (0..CODE_LEN)
        .map(|_| ALPHABET[OsRng.gen_range(0..ALPHABET.len())] as char)
        .collect()
}

pub(super) async fn list(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Vec<InviteCodeRecord>>> {
    Ok(Json(state.db.list_invite_codes().map_err(internal_err)?))
}

#[derive(Debug, Deserialize)]
pub(super) struct CreateInviteRequest {
    #[serde(default)]
    note: Option<String>,
    #[serde(default = "default_one")]
    max_uses: u32,
    #[serde(default)]
    expires_hours: Option<u64>,
}

fn default_one() -> u32 {
    1
}

pub(super) async fn create(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateInviteRequest>,
) -> ApiResult<Json<InviteCodeRecord>> {
    let max_uses = req.max_uses.clamp(1, 100_000);
    let expires_at = req
        .expires_hours
        .filter(|&h| h > 0)
        .map(|h| Utc::now() + Duration::hours(h.min(24 * 365 * 10) as i64));
    let note = req
        .note
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(200).collect::<String>());
    let code = generate_code();
    let rec = state
        .db
        .create_invite_code(&code, note.as_deref(), max_uses, expires_at)
        .map_err(internal_err)?;
    audit(
        &state,
        &admin,
        "invite.create",
        Some(&rec.code),
        Some(&format!("max_uses={max_uses}")),
    );
    Ok(Json(rec))
}

pub(super) async fn delete(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
) -> ApiResult<StatusCode> {
    if !state.db.delete_invite_code(&code).map_err(internal_err)? {
        return Err(not_found("invite code"));
    }
    audit(&state, &admin, "invite.delete", Some(&code), None);
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    #[test]
    fn invite_codes_use_the_unambiguous_alphabet() {
        for _ in 0..50 {
            let code = super::generate_code();
            assert_eq!(code.len(), super::CODE_LEN);
            assert!(code.bytes().all(|b| super::ALPHABET.contains(&b)));
        }
    }
}
