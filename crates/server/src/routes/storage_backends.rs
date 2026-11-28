//! A user's storage backends: create, edit, set default, delete and health checks.

use super::*;

pub(super) async fn list_storage_backends(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    let mut backends = state
        .db
        .list_storage_backends(&auth.user_id)
        .map_err(internal_err)?;
    if backends.is_empty() {
        let default_rec = state
            .resolve_backend(&auth.user_id, None)
            .map_err(internal_err)?;
        backends.push(default_rec);
    }
    Ok(Json(backends.iter().map(|b| b.to_summary()).collect()))
}

pub(super) async fn create_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateStorageBackendRequest>,
) -> Result<Json<StorageBackendSummary>, (StatusCode, String)> {
    let id = Uuid::new_v4().to_string();
    let config = match req.config {
        // Server-local storage always lives in the caller's own directory under
        // `DROPDRAWER_LOCAL_STORAGE`; a client-chosen path would expose the server's disk.
        StorageBackendConfig::Local { max_bytes, .. } => StorageBackendConfig::Local {
            root_dir: state
                .user_local_storage_dir(&auth.user_id)
                .to_string_lossy()
                .to_string(),
            max_bytes,
        },
        StorageBackendConfig::S3 {
            endpoint,
            region,
            bucket,
            access_key_id,
            secret_access_key,
            prefix,
            force_path_style,
        } => StorageBackendConfig::S3 {
            endpoint,
            region,
            bucket: bucket.trim().to_string(),
            access_key_id,
            secret_access_key,
            prefix,
            force_path_style,
        },
        other => other,
    };
    let settings = state.runtime_settings();
    policy::ensure_backend_kind_allowed(&settings.storage_policy, config.kind())?;
    if let StorageBackendConfig::S3 { bucket, .. } = &config {
        crate::storage::s3::validate_bucket_name(bucket)
            .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
    }
    policy::ensure_endpoints_allowed(&settings, &config)
        .await
        .map_err(|e| (StatusCode::FORBIDDEN, e.to_string()))?;
    let rec = state
        .db
        .create_storage_backend(&id, &auth.user_id, &req.name, &config, req.is_default)
        .map_err(internal_err)?;
    Ok(Json(rec.to_summary()))
}

#[derive(serde::Serialize)]
pub(super) struct StorageEditSettings {
    max_bytes: Option<u64>,
}

pub(super) async fn storage_edit_settings(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<StorageEditSettings>, (StatusCode, String)> {
    let backend = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(storage_backend_not_found)?;
    let max_bytes = match backend.config {
        StorageBackendConfig::Local { max_bytes, .. } => max_bytes,
        _ => None,
    };
    Ok(Json(StorageEditSettings { max_bytes }))
}

#[derive(Deserialize)]
pub(super) struct UpdateStorageBackendRequest {
    name: String,
    #[serde(default)]
    config: serde_json::Map<String, serde_json::Value>,
}

pub(super) async fn update_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateStorageBackendRequest>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    let backend = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(storage_backend_not_found)?;
    let name = req.name.trim();
    if name.is_empty() {
        return Err((StatusCode::BAD_REQUEST, t!("存储名称不能为空", "Storage name can't be empty").to_string()));
    }
    // Stored files refer to this backend ID. Keep the destination and account
    // identifiers fixed while letting users rotate credentials for that target.
    let credential_fields: &[&str] = match &backend.config {
        StorageBackendConfig::GoogleDrive { .. } => &["client_secret", "refresh_token"],
        StorageBackendConfig::Quark { .. } => &["cookie"],
        StorageBackendConfig::BaiduNetdisk { .. } => {
            &["client_secret", "refresh_token", "access_token"]
        }
        StorageBackendConfig::WebDav { .. } => &["password"],
        StorageBackendConfig::S3 { .. } => &["access_key_id", "secret_access_key"],
        StorageBackendConfig::Local { .. } => &[],
    };
    let mut patch = serde_json::Map::new();
    for (key, value) in req.config {
        if key == "max_bytes" && matches!(&backend.config, StorageBackendConfig::Local { .. }) {
            if !value.is_null() && value.as_u64().is_none_or(|bytes| bytes == 0) {
                return Err((StatusCode::BAD_REQUEST, t!("容量上限必须为正整数", "The capacity limit must be a positive whole number").to_string()));
            }
        } else if credential_fields.contains(&key.as_str()) {
            let credential = value
                .as_str()
                .ok_or_else(|| (StatusCode::BAD_REQUEST, t!("凭据必须为字符串", "Credentials must be strings").to_string()))?;
            if credential.trim().is_empty() {
                continue;
            }
        } else {
            return Err((StatusCode::BAD_REQUEST, t!("此存储字段无法编辑", "This storage field can't be edited").to_string()));
        }
        patch.insert(key, value);
    }
    if matches!(&backend.config, StorageBackendConfig::BaiduNetdisk { .. })
        && !patch.is_empty()
    {
        // The expiry belonged to the previously saved token pair.
        patch.insert("access_token_expires_at".into(), serde_json::Value::Null);
    }
    if !state
        .db
        .update_storage_backend(&id, &auth.user_id, name, &patch)
        .map_err(internal_err)?
    {
        return Err(storage_backend_not_found());
    }
    list_storage_backends(auth, State(state)).await
}

pub(super) fn storage_backend_not_found() -> (StatusCode, String) {
    (StatusCode::NOT_FOUND, t!("存储策略不存在", "Storage not found").to_string())
}

pub(super) async fn set_default_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Vec<StorageBackendSummary>>, (StatusCode, String)> {
    if !state
        .db
        .set_default_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
    {
        return Err(storage_backend_not_found());
    }
    list_storage_backends(auth, State(state)).await
}

pub(super) async fn delete_storage_backend(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<StatusCode, (StatusCode, String)> {
    let deleted = state
        .db
        .delete_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?;
    if !deleted {
        return Err(storage_backend_not_found());
    }
    Ok(StatusCode::NO_CONTENT)
}

pub(super) async fn check_storage_health(
    auth: AuthUser,
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<StorageHealthResponse>, (StatusCode, String)> {
    let rec = state
        .db
        .get_storage_backend(&id, &auth.user_id)
        .map_err(internal_err)?
        .ok_or_else(storage_backend_not_found)?;

    let provider = match state.storage_provider(&rec).await {
        Ok(provider) => provider,
        Err(err) => {
            return Ok(Json(StorageHealthResponse {
                ok: false,
                message: err.to_string(),
            }))
        }
    };
    match provider.health_check().await {
        Ok(msg) => Ok(Json(StorageHealthResponse {
            ok: true,
            message: msg,
        })),
        Err(err) => Ok(Json(StorageHealthResponse {
            ok: false,
            message: err.to_string(),
        })),
    }
}
