use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::{
    body::Body,
    extract::{Path as AxumPath, State},
    http::{header, HeaderMap, Request, StatusCode},
    response::IntoResponse,
    routing::{get, post, put},
    Json, Router,
};
use chrono::{Duration, Utc};
use futures_util::StreamExt;
use dropdrawer_server::{
    db::{Database, DrawerItemRow},
    routes::build_router,
    run_ttl_cleanup_once,
    state::AppState,
};
use protocol::{
    AuthResponse, CreateBatchShareRequest, CreateDrawerItemRequest, CreateShareRequest,
    CreateStorageBackendRequest, DeviceInfo, DevicePlatform, DownloadPlan, DrawerItem,
    DrawerItemKind, LoginRequest, RegisterDeviceRequest, RegisterRequest, ShareLinkInfo,
    StorageBackendConfig, StorageBackendSummary, StorageHealthResponse, TransferMode, UploadPlan,
};
use serde_json::json;
use tempfile::TempDir;
use tower::ServiceExt;

async fn spawn_test_server() -> (Router, Arc<AppState>, TempDir) {
    let tmp = TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("test.db")).unwrap();
    let state = AppState::new(
        db,
        "test-jwt-secret".to_string(),
        tmp.path().join("local_blobs"),
    );
    let app = build_router(state.clone());
    (app, state, tmp)
}

async fn send_json<T: serde::de::DeserializeOwned>(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<serde_json::Value>,
) -> (StatusCode, T) {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(tok) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {tok}"));
    }
    let req = if let Some(b) = body {
        builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(serde_json::to_vec(&b).unwrap()))
            .unwrap()
    } else {
        builder.body(Body::empty()).unwrap()
    };

    let resp = app.clone().oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 10 * 1024 * 1024)
        .await
        .unwrap();
    let parsed: T = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
        panic!(
            "failed decoding response ({status}): {e}, raw={}",
            String::from_utf8_lossy(&bytes)
        )
    });
    (status, parsed)
}

#[tokio::test]
async fn test_device_registration_reuses_persistent_node_and_scopes_ids() {
    let (app, state, _tmp) = spawn_test_server().await;
    let (_, first): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "first", "password": "test-password"})),
    )
    .await;
    let (_, second): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "second", "password": "test-password"})),
    )
    .await;
    let (status, original): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&first.token),
        Some(json!({
            "device_id": "saved-windows",
            "name": "PC",
            "platform": "windows",
            "iroh_node_id": "persistent-node",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, recovered): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&first.token),
        Some(json!({
            "name": "Renamed PC",
            "platform": "windows",
            "iroh_node_id": "persistent-node",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(recovered.id, original.id);
    assert_eq!(recovered.name, "Renamed PC");

    let (_, homonym): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&first.token),
        Some(json!({
            "name": "Renamed PC",
            "platform": "windows",
            "iroh_node_id": "another-node",
        })),
    )
    .await;
    assert_ne!(homonym.id, original.id);
    assert_eq!(state.db.list_devices(&first.user.id).unwrap().len(), 2);

    let (status, other_account): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&second.token),
        Some(json!({
            "device_id": original.id,
            "name": "Renamed PC",
            "platform": "windows",
            "iroh_node_id": "persistent-node",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_ne!(other_account.id, original.id);
    let devices = state.db.list_devices(&second.user.id).unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].id, other_account.id);
}

#[tokio::test]
async fn test_replaced_websocket_cannot_mark_device_offline() {
    use std::time::Duration;
    use tokio::time::timeout;
    use tokio_tungstenite::connect_async;

    let (app, state, _tmp) = spawn_test_server().await;
    let (_, auth): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "reconnect", "password": "test-password"})),
    )
    .await;
    let (_, device): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&auth.token),
        Some(json!({"name": "Phone", "platform": "ios"})),
    )
    .await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let ws_url = format!("ws://{addr}/ws?token={}&device_id={}", auth.token, device.id);
    let connection_timeout = Duration::from_secs(3);

    let invalid_url = format!("ws://{addr}/ws?token={}&device_id=unknown", auth.token);
    assert!(timeout(connection_timeout, connect_async(invalid_url))
        .await
        .unwrap()
        .is_err());

    let (mut previous, _) = timeout(connection_timeout, connect_async(&ws_url))
        .await
        .unwrap()
        .unwrap();
    timeout(connection_timeout, previous.next()).await.unwrap().unwrap().unwrap();

    let (mut current, _) = timeout(connection_timeout, connect_async(&ws_url))
        .await
        .unwrap()
        .unwrap();
    timeout(connection_timeout, current.next()).await.unwrap().unwrap().unwrap();

    previous.close(None).await.unwrap();
    timeout(connection_timeout, async {
        while previous.next().await.is_some() {}
    })
    .await
    .unwrap();
    assert!(state.is_device_online(&auth.user.id, &device.id));

    current.close(None).await.unwrap();
    timeout(connection_timeout, async {
        while current.next().await.is_some() {}
    })
    .await
    .unwrap();
    assert!(!state.is_device_online(&auth.user.id, &device.id));
    server.abort();
}

#[tokio::test]
async fn test_auth_device_local_storage_and_ttl_cleanup() {
    let (app, state, _tmp) = spawn_test_server().await;

    let (st, reg): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(serde_json::to_value(RegisterRequest {
            username: "alice".to_string(),
            password: "password123".to_string(),
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(reg.user.username, "alice");

    let (st, login): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(serde_json::to_value(LoginRequest {
            username: "alice".to_string(),
            password: "password123".to_string(),
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let token = login.token;

    let (st, device): (StatusCode, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&token),
        Some(serde_json::to_value(RegisterDeviceRequest {
            device_id: Some("mac-dev-1".to_string()),
            name: "Alice MacBook".to_string(),
            platform: DevicePlatform::Macos,
            iroh_node_id: Some("fake-node-id-123".to_string()),
            iroh_relay_url: None,
            direct_addrs: vec!["127.0.0.1:4433".to_string()],
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(device.id, "mac-dev-1");

    let (st, item): (StatusCode, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&token),
        Some(serde_json::to_value(CreateDrawerItemRequest {
            device_id: device.id.clone(),
            kind: DrawerItemKind::File,
            name: "hello.txt".to_string(),
            size: 16,
            mime_type: Some("text/plain".to_string()),
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::Hybrid,
            storage_backend_id: None,
            ttl_hours: Some(24),
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert!(!item.cloud_ready);

    let (st, plan): (StatusCode, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item.id),
        Some(&token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let upload_url = match plan {
        UploadPlan::ServerStreamPut { url, .. } => url,
        other => panic!("expected ServerStreamPut, got {other:?}"),
    };

    let payload = b"hello dropdrawer";
    let put_req = Request::builder()
        .method("PUT")
        .uri(&upload_url)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_LENGTH, payload.len())
        .body(Body::from(payload.to_vec()))
        .unwrap();
    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::OK);
    let uploaded: DrawerItem = serde_json::from_slice(
        &axum::body::to_bytes(put_resp.into_body(), 1024 * 1024)
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(uploaded.cloud_ready);
    assert_eq!(uploaded.size, payload.len() as u64);

    let (st, dl_plan): (StatusCode, DownloadPlan) = send_json(
        &app,
        "GET",
        &format!("/api/drawer/items/{}/download-plan", item.id),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let cloud = dl_plan.cloud.expect("expected cloud download info");

    let dl_req = Request::builder()
        .method("GET")
        .uri(&cloud.url)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let dl_resp = app.clone().oneshot(dl_req).await.unwrap();
    assert_eq!(dl_resp.status(), StatusCode::OK);
    let downloaded_bytes = axum::body::to_bytes(dl_resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    assert_eq!(&downloaded_bytes[..], payload);

    state
        .db
        .create_drawer_item(&DrawerItemRow {
            id: "expired-item-1".to_string(),
            user_id: reg.user.id.clone(),
            owner_device_id: device.id.clone(),
            kind: DrawerItemKind::Text,
            name: "old note".to_string(),
            size: 3,
            mime_type: Some("text/plain".to_string()),
            blake3_hash: None,
            text_content: Some("old".to_string()),
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: None,
            storage_path: None,
            cloud_ready: true,
            expires_at: Some(Utc::now() - Duration::minutes(5)),
            created_at: Utc::now() - Duration::hours(2),
        })
        .unwrap();

    let cleaned = run_ttl_cleanup_once(&state).await.unwrap();
    assert_eq!(cleaned, 1);
    assert!(state
        .db
        .get_drawer_item("expired-item-1", &reg.user.id)
        .unwrap()
        .is_none());
}

#[tokio::test]
async fn test_native_google_drive_resumable_upload_download_delete_and_s3() {
    // In-process mock Google OAuth2 + Google Drive API v3 server.
    let files: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mock_addr = listener.local_addr().unwrap();
    let mock_base = format!("http://{mock_addr}");
    let mock_base_for_init = mock_base.clone();

    let mock_app = Router::new()
        .route(
            "/oauth/token",
            post(|| async {
                Json(json!({
                    "access_token": "mock-gdrive-access-token",
                    "expires_in": 3600,
                    "token_type": "Bearer"
                }))
            }),
        )
        .route(
            "/drive/v3/about",
            get(|headers: HeaderMap| async move {
                assert_eq!(
                    headers
                        .get(header::AUTHORIZATION)
                        .and_then(|v| v.to_str().ok()),
                    Some("Bearer mock-gdrive-access-token")
                );
                Json(json!({
                    "user": { "emailAddress": "demo@gmail.com" },
                    "storageQuota": { "limit": "16106127360", "usage": "2147483648" }
                }))
            }),
        )
        .route(
            "/upload/drive/v3/files",
            post(move || {
                let base = mock_base_for_init.clone();
                async move {
                    let mut resp = StatusCode::OK.into_response();
                    resp.headers_mut().insert(
                        header::LOCATION,
                        format!("{base}/upload/session/gdrive-file-99")
                            .parse()
                            .unwrap(),
                    );
                    resp
                }
            }),
        )
        .route(
            "/upload/session/{id}",
            put(
                |State(store): State<Arc<Mutex<HashMap<String, Vec<u8>>>>>,
                 AxumPath(id): AxumPath<String>,
                 body: bytes::Bytes| async move {
                    let len = body.len();
                    store.lock().unwrap().insert(id.clone(), body.to_vec());
                    Json(json!({ "id": id, "size": len.to_string() }))
                },
            ),
        )
        .route(
            "/drive/v3/files/{id}",
            get(
                |State(store): State<Arc<Mutex<HashMap<String, Vec<u8>>>>>,
                 AxumPath(id): AxumPath<String>| async move {
                    store.lock().unwrap().get(&id).cloned().unwrap_or_default()
                },
            )
            .delete(
                |State(store): State<Arc<Mutex<HashMap<String, Vec<u8>>>>>,
                 AxumPath(id): AxumPath<String>| async move {
                    store.lock().unwrap().remove(&id);
                    StatusCode::NO_CONTENT
                },
            ),
        )
        .with_state(files.clone());

    tokio::spawn(async move {
        axum::serve(listener, mock_app).await.unwrap();
    });

    let (app, _state, _tmp) = spawn_test_server().await;
    let (_, auth): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({ "username": "bob", "password": "password123" })),
    )
    .await;
    let token = auth.token;

    // 1. Add Native Google Drive backend
    let (st, backend): (StatusCode, StorageBackendSummary) = send_json(
        &app,
        "POST",
        "/api/storage",
        Some(&token),
        Some(serde_json::to_value(CreateStorageBackendRequest {
            name: "My Google Drive".to_string(),
            config: StorageBackendConfig::GoogleDrive {
                client_id: "cid".to_string(),
                client_secret: "csec".to_string(),
                refresh_token: "rtok".to_string(),
                folder_id: "root".to_string(),
                api_base_url: Some(mock_base.clone()),
                token_url: Some(format!("{mock_base}/oauth/token")),
            },
            is_default: true,
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    // 2. Health check returns Google account + quota
    let (st, health): (StatusCode, StorageHealthResponse) = send_json(
        &app,
        "POST",
        &format!("/api/storage/{}/health", backend.id),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert!(health.ok, "gdrive health failed: {}", health.message);
    assert!(health.message.contains("demo@gmail.com"));

    // 3. Create item & stream upload via Google Drive Resumable Upload
    let (_, item): (StatusCode, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&token),
        Some(serde_json::to_value(CreateDrawerItemRequest {
            device_id: "mac-1".to_string(),
            kind: DrawerItemKind::File,
            name: "report.pdf".to_string(),
            size: 18,
            mime_type: Some("application/pdf".to_string()),
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: Some(backend.id.clone()),
            ttl_hours: Some(12),
        })
        .unwrap()),
    )
    .await;

    let payload = b"google-drive-bytes";
    let put_req = Request::builder()
        .method("PUT")
        .uri(format!(
            "/api/drawer/items/{}/upload?storage_backend_id={}",
            item.id, backend.id
        ))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(payload.to_vec()))
        .unwrap();
    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::OK);
    assert_eq!(
        files.lock().unwrap().get("gdrive-file-99").map(|v| v.as_slice()),
        Some(payload.as_slice())
    );

    // 4. Download back from native Google Drive
    let dl_req = Request::builder()
        .method("GET")
        .uri(format!("/api/drawer/items/{}/download", item.id))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let dl_resp = app.clone().oneshot(dl_req).await.unwrap();
    assert_eq!(dl_resp.status(), StatusCode::OK);
    let dl_bytes = axum::body::to_bytes(dl_resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    assert_eq!(&dl_bytes[..], payload);

    // 5. Delete item also deletes file in Google Drive
    let del_req = Request::builder()
        .method("DELETE")
        .uri(format!("/api/drawer/items/{}", item.id))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let del_resp = app.clone().oneshot(del_req).await.unwrap();
    assert_eq!(del_resp.status(), StatusCode::NO_CONTENT);
    assert!(files.lock().unwrap().get("gdrive-file-99").is_none());

    // 6. S3 Presigned PUT still works
    let (st, s3_backend): (StatusCode, StorageBackendSummary) = send_json(
        &app,
        "POST",
        "/api/storage",
        Some(&token),
        Some(serde_json::to_value(CreateStorageBackendRequest {
            name: "Cloudflare R2".to_string(),
            config: StorageBackendConfig::S3 {
                endpoint: "https://account.r2.cloudflarestorage.com".to_string(),
                region: "auto".to_string(),
                bucket: "dropdrawer".to_string(),
                access_key_id: "AKIAEXAMPLE".to_string(),
                secret_access_key: "SECRETEXAMPLE".to_string(),
                prefix: "cache".to_string(),
                force_path_style: true,
            },
            is_default: false,
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (_, item2): (StatusCode, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&token),
        Some(serde_json::to_value(CreateDrawerItemRequest {
            device_id: "mac-1".to_string(),
            kind: DrawerItemKind::File,
            name: "archive.zip".to_string(),
            size: 100,
            mime_type: None,
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: Some(s3_backend.id.clone()),
            ttl_hours: None,
        })
        .unwrap()),
    )
    .await;

    let (st, s3_plan): (StatusCode, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item2.id),
        Some(&token),
        Some(json!({ "storage_backend_id": s3_backend.id })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    match s3_plan {
        UploadPlan::DirectPresignedPut { url, .. } => {
            assert!(url.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"));
            assert!(url.contains("X-Amz-Signature="));
        }
        other => panic!("expected DirectPresignedPut, got {other:?}"),
    }
}

#[tokio::test]
async fn test_public_share_link_passcode_limit_and_revoke() {
    let (app, _state, _tmp) = spawn_test_server().await;

    let (_, auth): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({ "username": "carol", "password": "password123" })),
    )
    .await;
    let token = auth.token;

    // 1. Create a file item and upload bytes to default local disk storage.
    let (_, item): (StatusCode, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&token),
        Some(serde_json::to_value(CreateDrawerItemRequest {
            device_id: "mac-carol".to_string(),
            kind: DrawerItemKind::File,
            name: "secret-doc.txt".to_string(),
            size: 21,
            mime_type: Some("text/plain".to_string()),
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: None,
            ttl_hours: Some(24),
        })
        .unwrap()),
    )
    .await;

    let (_, plan): (StatusCode, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item.id),
        Some(&token),
        Some(json!({})),
    )
    .await;
    let upload_url = match plan {
        UploadPlan::ServerStreamPut { url, .. } => url,
        other => panic!("expected ServerStreamPut, got {other:?}"),
    };

    let payload = b"burn-after-one-shared";
    let put_req = Request::builder()
        .method("PUT")
        .uri(&upload_url)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(payload.to_vec()))
        .unwrap();
    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::OK);

    // 2. Create share link with passcode & max_downloads = 1 (burn after download).
    let (st, share): (StatusCode, ShareLinkInfo) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", item.id),
        Some(&token),
        Some(serde_json::to_value(CreateShareRequest {
            passcode: Some("8421".to_string()),
            expires_hours: Some(24),
            max_downloads: Some(1),
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert!(share.has_passcode);
    assert_eq!(share.max_downloads, Some(1));
    assert_eq!(share.share_path, format!("/s/{}", share.code));

    // 3. List shares includes the newly created share.
    let (st, shares): (StatusCode, Vec<ShareLinkInfo>) =
        send_json(&app, "GET", "/api/shares", Some(&token), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(shares.len(), 1);
    assert_eq!(shares[0].code, share.code);

    // 4. Public HTML page loads cleanly and embeds the share code.
    let html_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(&share.share_path)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(html_resp.status(), StatusCode::OK);
    let html = String::from_utf8(
        axum::body::to_bytes(html_resp.into_body(), 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(html.contains(&share.code));

    // 5. Meta without passcode is locked; with passcode is unlocked.
    let (st, meta_locked): (StatusCode, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("/api/s/{}/meta", share.code),
        None,
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(meta_locked["locked"], json!(true));

    let (st, meta_open): (StatusCode, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("/api/s/{}/meta?passcode=8421", share.code),
        None,
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(meta_open["locked"], json!(false));

    // 6. Download without passcode returns 403.
    let dl_denied = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/s/{}/download", share.code))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dl_denied.status(), StatusCode::FORBIDDEN);

    // 7. Download with valid passcode succeeds and streams exact payload.
    let dl_ok = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/s/{}/download?passcode=8421", share.code))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dl_ok.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(dl_ok.into_body(), 1024 * 1024)
        .await
        .unwrap();
    assert_eq!(&bytes[..], payload);

    // 8. Second download fails with 410 GONE due to max_downloads = 1.
    let dl_gone = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/s/{}/download?passcode=8421", share.code))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dl_gone.status(), StatusCode::GONE);

    // 9. Revoking share removes it cleanly.
    let del_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/shares/{}", share.code))
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del_resp.status(), StatusCode::NO_CONTENT);

    let after_del = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/s/{}/meta", share.code))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(after_del.status(), StatusCode::NOT_FOUND);

    // 10. Multi-select batch share bundle (file + text) via POST /api/shares.
    let (_, note_item): (StatusCode, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&token),
        Some(serde_json::to_value(CreateDrawerItemRequest {
            device_id: "mac-carol".to_string(),
            kind: DrawerItemKind::Text,
            name: "release-notes".to_string(),
            size: 12,
            mime_type: Some("text/plain".to_string()),
            blake3_hash: None,
            text_content: Some("hello bundle".to_string()),
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: None,
            ttl_hours: None,
        })
        .unwrap()),
    )
    .await;

    let (st, bundle): (StatusCode, ShareLinkInfo) = send_json(
        &app,
        "POST",
        "/api/shares",
        Some(&token),
        Some(serde_json::to_value(CreateBatchShareRequest {
            item_ids: vec![item.id.clone(), note_item.id.clone()],
            title: Some("项目打包合集".to_string()),
            passcode: Some("9999".to_string()),
            expires_hours: Some(24),
            max_downloads: None,
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(bundle.item_count, 2);
    assert_eq!(bundle.item_name, "项目打包合集");

    let (st, bmeta): (StatusCode, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("/api/s/{}/meta?passcode=9999", bundle.code),
        None,
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(bmeta["item_count"], json!(2));
    assert_eq!(bmeta["items"].as_array().unwrap().len(), 2);

    // Download the first item explicitly by item_id from the bundle.
    let b_dl = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!(
                    "/api/s/{}/download?item_id={}&passcode=9999",
                    bundle.code, item.id
                ))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(b_dl.status(), StatusCode::OK);
    let b_bytes = axum::body::to_bytes(b_dl.into_body(), 1024 * 1024)
        .await
        .unwrap();
    assert_eq!(&b_bytes[..], payload);
}
