//! Drawer items: create, delete, cloud upload plans and streaming uploads,
//! download plans (P2P, LAN replicas, cloud) and server-side downloads.

use super::*;

pub(super) async fn list_drawer_items(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DrawerItem>>, (StatusCode, String)> {
    let items = state
        .list_hydrated_items(&auth.user_id)
        .map_err(internal_err)?;
    Ok(Json(items))
}

pub(super) async fn create_drawer_item(
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
    crate::push::notify_item_added(&state, &auth.user_id, &hydrated);
    Ok(Json(hydrated))
}

pub(super) async fn delete_drawer_item(
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
pub(super) struct BatchDeleteRequest {
    #[serde(default)]
    item_ids: Vec<String>,
    #[serde(default)]
    clear_all: bool,
}

pub(super) async fn batch_delete_drawer_items(
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
pub(super) struct UploadPlanRequest {
    #[serde(default)]
    storage_backend_id: Option<String>,
    #[serde(default)]
    content_sha256: Option<String>,
    #[serde(default)]
    size: Option<u64>,
}

pub(super) fn normalize_sha256(raw: Option<&str>) -> Option<String> {
    let trimmed = raw?.trim();
    if trimmed.len() == 64 && trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(trimmed.to_ascii_lowercase())
    } else {
        None
    }
}

pub(super) async fn request_upload_plan(
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
pub(super) struct UploadQuery {
    #[serde(default)]
    storage_backend_id: Option<String>,
}

pub(super) async fn stream_upload_item(
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
pub(super) fn item_storage_key(user_id: &str, item_id: &str, name: &str) -> String {
    format!("{user_id}/{item_id}_{}", sanitize_filename(name))
}

#[derive(Debug, Deserialize)]
pub(super) struct ConfirmUploadRequest {
    storage_backend_id: String,
    remote_key: String,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    blake3_hash: Option<String>,
    #[serde(default)]
    content_sha256: Option<String>,
}

pub(super) async fn confirm_direct_upload(
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
pub(super) struct DownloadPlanQuery {
    #[serde(default)]
    prefer_replica: bool,
    #[serde(default)]
    requester_device_id: Option<String>,
}

// Private addresses can be routed on a wider LAN than /24. Prefer subnet
// matches, and let QUIC authenticate the peer and confirm actual reachability.
pub(super) fn lan_candidates(requester: &[String], source: &[String]) -> (bool, Vec<String>) {
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

pub(super) async fn get_download_plan(
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

pub(super) async fn download_item_content(
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
