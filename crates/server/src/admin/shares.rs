//! Moderation of public share links across all users.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use super::{audit, internal_err, not_found, AdminSession, ApiResult};
use crate::db::AdminShareRow;
use crate::state::AppState;

pub(super) async fn list(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> ApiResult<Json<Vec<AdminShareRow>>> {
    Ok(Json(
        state.db.list_all_share_links_admin().map_err(internal_err)?,
    ))
}

pub(super) async fn delete(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Path(code): Path<String>,
) -> ApiResult<StatusCode> {
    if !state.db.delete_share_link_admin(&code).map_err(internal_err)? {
        return Err(not_found("share link"));
    }
    audit(&state, &admin, "share.revoke", Some(&code), None);
    Ok(StatusCode::NO_CONTENT)
}
