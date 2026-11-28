//! Device registration, push tokens, client configuration and the device list.

use super::*;

pub(super) async fn register_device(
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

pub(super) async fn register_push_token(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(device_id): Path<String>,
    Json(req): Json<protocol::RegisterPushTokenRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let token = req.token.trim();
    // APNs tokens are 64+ hex characters; FCM tokens are ~160 URL-safe characters.
    let plausible = !token.is_empty()
        && token.len() <= 4096
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b':' | b'.'));
    if !plausible {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("推送令牌格式不正确", "The push token is not valid").to_string(),
        ));
    }
    if !state.push().is_some_and(|push| push.supports(req.provider)) {
        return Err((
            StatusCode::CONFLICT,
            t!("服务器未配置这种推送服务", "This server is not set up for this push service").to_string(),
        ));
    }
    let language = if crate::i18n::is_en() { "en" } else { "zh" };
    let stored = state
        .db
        .upsert_push_token(&device_id, &auth.user_id, req.provider, token, req.sandbox, language)
        .map_err(internal_err)?;
    if !stored {
        return Err((StatusCode::NOT_FOUND, t!("设备不存在", "Device not found").to_string()));
    }
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn delete_push_token(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(device_id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    state
        .db
        .delete_push_token(&device_id, &auth.user_id)
        .map_err(internal_err)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub(super) struct ClientConfigQuery {
    #[serde(default)]
    device_id: Option<String>,
}

pub(super) async fn client_config(
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

pub(super) async fn list_devices(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeviceInfo>>, (StatusCode, String)> {
    let devices = state
        .list_devices_with_presence(&auth.user_id)
        .map_err(internal_err)?;
    Ok(Json(devices))
}
