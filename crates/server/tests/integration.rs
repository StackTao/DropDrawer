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

    // Current clients authenticate with a header instead of a query token.
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    let bare_url = format!("ws://{addr}/ws?device_id={}", device.id);
    assert!(timeout(connection_timeout, connect_async(&bare_url))
        .await
        .unwrap()
        .is_err());
    let mut request = bare_url.into_client_request().unwrap();
    request.headers_mut().insert(
        header::AUTHORIZATION,
        format!("Bearer {}", auth.token).parse().unwrap(),
    );
    let (mut current, _) = timeout(connection_timeout, connect_async(request))
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
async fn same_account_lan_replica_requires_original_digest_and_a_live_session() {
    use futures_util::SinkExt;
    use tokio_tungstenite::{connect_async, tungstenite::Message};

    let (app, state, _tmp) = spawn_test_server().await;
    let (_, auth): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "replica-test", "password": "test-password"})),
    )
    .await;
    let token = Some(auth.token.as_str());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let router = app.clone();
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let mut peers = Vec::new();
    for (name, ip) in [
        ("source", "10.1.1.1"),
        ("copy", "192.168.1.2"),
        ("phone", "192.168.1.3"),
    ] {
        let (_, device): (_, DeviceInfo) = send_json(
            &app,
            "POST",
            "/api/devices",
            token,
            Some(
                json!({"name":name, "platform":"android", "iroh_node_id":name,
                "direct_addrs":[format!("{ip}:1234")]}),
            ),
        )
        .await;
        let url = format!(
            "ws://127.0.0.1:{port}/ws?token={}&device_id={}",
            auth.token, device.id
        );
        let (ws, _) = connect_async(url).await.unwrap();
        peers.push((device.id, ws));
    }
    let (_, item): (_, DrawerItem) = send_json(&app, "POST", "/api/drawer/items", token,
        Some(json!({"device_id":peers[0].0, "kind":"file", "name":"test", "size":4, "transfer_mode":"p2p_only"}))).await;
    let path = format!(
        "/api/drawer/items/{}/download-plan?requester_device_id={}",
        item.id, peers[2].0
    );
    let get = |prefer| {
        let url = format!("{path}&prefer_replica={prefer}");
        let app = &app;
        async move {
            send_json::<DownloadPlan>(app, "GET", &url, token, None)
                .await
                .1
                .p2p
        }
    };
    let hash = "a".repeat(64);
    let advertise = |hash: &str| {
        Message::text(
            json!({"type":"update_ready_files",
        "payload":{"files":{item.id.clone():hash}}})
            .to_string(),
        )
    };
    peers[1].1.send(advertise(&hash)).await.unwrap();
    // A ping/pong after the report is a barrier on the same WebSocket.
    async fn sync(
        ws: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) {
        ws.send(Message::text(r#"{"type":"ping"}"#)).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            while let Some(Ok(Message::Text(m))) = ws.next().await {
                if serde_json::from_str::<serde_json::Value>(&m).unwrap()["type"] == "pong" {
                    return;
                }
            }
            panic!("session closed");
        })
        .await
        .unwrap()
    }
    sync(&mut peers[1].1).await;
    assert_eq!(get(true).await.unwrap().device_id, peers[0].0); // unconfirmed digest
    peers[0].1.send(advertise(&hash)).await.unwrap();
    sync(&mut peers[0].1).await;
    let replica = get(true).await.unwrap();
    assert_eq!(replica.device_id, peers[1].0);
    assert_eq!(replica.replica_hash.as_ref(), Some(&hash));
    assert_eq!(replica.direct_addrs, ["192.168.1.2:1234"]);
    assert_eq!(get(false).await.unwrap().device_id, peers[0].0);
    peers[1].1.send(advertise(&"b".repeat(64))).await.unwrap();
    sync(&mut peers[1].1).await;
    assert_eq!(get(true).await.unwrap().device_id, peers[0].0);
    peers[1].1.send(advertise(&hash)).await.unwrap();
    sync(&mut peers[1].1).await;
    peers[0].1.close(None).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while state.is_device_online(&auth.user.id, &peers[0].0) {
            tokio::task::yield_now().await;
        }
    }).await.unwrap();
    assert_eq!(get(true).await.unwrap().device_id, peers[1].0);
    assert!(get(false).await.is_none());
    peers[1].1.close(None).await.unwrap();
    peers[2].1.close(None).await.unwrap();
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
async fn test_clear_drawer_removes_owned_files_and_retries_failed_deletions() {
    let (app, state, _tmp) = spawn_test_server().await;
    let owner = state.db.create_user("owner", "owner", "").unwrap();
    let other = state.db.create_user("other", "other", "").unwrap();
    let token =
        dropdrawer_server::auth::create_jwt(&owner.id, &owner.username, &state.jwt_secret).unwrap();

    let create_file = |user_id: &str, id: &str, expired: bool| {
        let backend = state.resolve_backend(user_id, None).unwrap();
        let storage_key = format!("{user_id}/{id}.txt");
        let path = state.user_local_storage_dir(user_id).join(&storage_key);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"uploaded file").unwrap();
        state
            .db
            .create_drawer_item(&DrawerItemRow {
                id: id.to_owned(),
                user_id: user_id.to_owned(),
                owner_device_id: "device".into(),
                kind: DrawerItemKind::File,
                name: format!("{id}.txt"),
                size: 13,
                mime_type: None,
                blake3_hash: None,
                text_content: None,
                thumbnail_base64: None,
                transfer_mode: TransferMode::CloudCached,
                storage_backend_id: Some(backend.id),
                storage_path: Some(storage_key),
                cloud_ready: true,
                expires_at: expired.then(|| Utc::now() - Duration::minutes(1)),
                created_at: Utc::now(),
            })
            .unwrap();
        path
    };

    let clean = create_file(&owner.id, "clean", false);
    let blocked = create_file(&owner.id, "blocked", true);
    let unrelated = create_file(&other.id, "unrelated", false);
    let saved = blocked.with_extension("saved");
    std::fs::rename(&blocked, &saved).unwrap();
    std::fs::create_dir(&blocked).unwrap();

    let clear = || {
        send_json::<serde_json::Value>(
            &app,
            "POST",
            "/api/drawer/items/batch-delete",
            Some(&token),
            Some(json!({"clear_all": true})),
        )
    };
    let (status, first) = clear().await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        first,
        json!({"deleted": 1, "item_ids": ["clean"], "failed_item_ids": ["blocked"]})
    );
    assert!(!clean.exists());
    assert!(
        state
            .db
            .get_drawer_item("clean", &owner.id)
            .unwrap()
            .is_none()
    );
    assert!(
        state
            .db
            .get_drawer_item("blocked", &owner.id)
            .unwrap()
            .is_some()
    );
    assert_eq!(run_ttl_cleanup_once(&state).await.unwrap(), 0);
    assert!(
        state
            .db
            .get_drawer_item("blocked", &owner.id)
            .unwrap()
            .is_some()
    );

    std::fs::remove_dir(&blocked).unwrap();
    std::fs::rename(&saved, &blocked).unwrap();
    let (status, retry) = clear().await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        retry,
        json!({"deleted": 1, "item_ids": ["blocked"], "failed_item_ids": []})
    );
    assert!(!blocked.exists());
    assert!(state.db.list_drawer_items(&owner.id).unwrap().is_empty());
    assert!(
        state
            .db
            .get_drawer_item("unrelated", &other.id)
            .unwrap()
            .is_some()
    );
    assert_eq!(std::fs::read(unrelated).unwrap(), b"uploaded file");

    let (_, empty) = clear().await;
    assert_eq!(
        empty,
        json!({"deleted": 0, "item_ids": [], "failed_item_ids": []})
    );
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

async fn send_raw(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<serde_json::Value>,
) -> (StatusCode, Vec<u8>) {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(tok) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {tok}"));
    }
    let req = match body {
        Some(b) => builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(serde_json::to_vec(&b).unwrap()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    };
    let resp = app.clone().oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), 10 * 1024 * 1024)
        .await
        .unwrap();
    (status, bytes.to_vec())
}

#[tokio::test]
async fn test_local_storage_cannot_escape_server_storage_area() {
    let (app, state, tmp) = spawn_test_server().await;
    let secret = tmp.path().join("server-secret.txt");
    std::fs::write(&secret, b"top secret").unwrap();

    let (_, mallory): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "mallory", "password": "password123"})),
    )
    .await;
    let (_, device): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&mallory.token),
        Some(json!({"device_id": "m1", "name": "M", "platform": "linux"})),
    )
    .await;

    // A client-chosen root directory is replaced with the caller's own storage directory.
    let (status, backend): (_, StorageBackendSummary) = send_json(
        &app,
        "POST",
        "/api/storage",
        Some(&mallory.token),
        Some(json!({
            "name": "root",
            "config": {"kind": "local", "root_dir": "/"},
            "is_default": false,
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let stored = state
        .db
        .get_storage_backend(&backend.id, &mallory.user.id)
        .unwrap()
        .unwrap();
    match stored.config {
        StorageBackendConfig::Local { root_dir, .. } => assert_eq!(
            std::path::PathBuf::from(root_dir),
            tmp.path().join("local_blobs").join(&mallory.user.id)
        ),
        other => panic!("unexpected config {other:?}"),
    }

    let (_, item): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&mallory.token),
        Some(json!({
            "device_id": device.id,
            "kind": "file",
            "name": "x.bin",
            "size": 10,
            "transfer_mode": "p2p_only",
        })),
    )
    .await;

    // The client cannot pick an arbitrary key when confirming a direct upload.
    let forged_key = secret.to_string_lossy().trim_start_matches('/').to_string();
    let (status, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/confirm-upload", item.id),
        Some(&mallory.token),
        Some(json!({"storage_backend_id": backend.id, "remote_key": forged_key})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A pre-existing record pointing outside the storage area is refused when used,
    // and keys outside the owner's namespace are refused even inside it.
    let escaped = state
        .db
        .create_storage_backend(
            "legacy-escape",
            &mallory.user.id,
            "legacy",
            &StorageBackendConfig::Local {
                root_dir: "/".to_string(),
                max_bytes: None,
            },
            false,
        )
        .unwrap();
    assert!(state.build_storage_provider(&escaped).is_err());
    for (backend_id, key) in [("legacy-escape", forged_key.as_str()), (backend.id.as_str(), "other-user/x")] {
        state
            .db
            .mark_item_cloud_ready(&item.id, &mallory.user.id, backend_id, key, None, None)
            .unwrap();
        let (status, body) = send_raw(
            &app,
            "GET",
            &format!("/api/drawer/items/{}/download", item.id),
            Some(&mallory.token),
            None,
        )
        .await;
        assert_ne!(status, StatusCode::OK, "{key}");
        assert!(!body.windows(10).any(|w| w == b"top secret"));
    }
    state
        .db
        .mark_item_cloud_ready(&item.id, &mallory.user.id, "legacy-escape", &forged_key, None, None)
        .unwrap();
    let (status, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/drawer/items/{}", item.id),
        Some(&mallory.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(std::fs::read(&secret).unwrap(), b"top secret");
    assert!(
        state.db.get_drawer_item(&item.id, &mallory.user.id).unwrap().is_some(),
        "retain the drawer record when its storage path is rejected"
    );

    state.set_registration_open(false);
    let (status, _) = send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "eve", "password": "password123"})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn test_login_and_passcode_guessing_is_throttled() {
    let (app, _state, _tmp) = spawn_test_server().await;
    let (_, alice): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "alice", "password": "password123"})),
    )
    .await;

    for _ in 0..10 {
        let (status, _) = send_raw(
            &app,
            "POST",
            "/api/auth/login",
            None,
            Some(json!({"username": "alice", "password": "wrong-password"})),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    // Even the right password is refused while the account is throttled.
    let (status, _) = send_raw(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "Alice", "password": "password123"})),
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);

    let (_, device): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&alice.token),
        Some(json!({"device_id": "d1", "name": "D", "platform": "linux"})),
    )
    .await;
    let (_, item): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&alice.token),
        Some(json!({
            "device_id": device.id,
            "kind": "text",
            "name": "note",
            "size": 5,
            "text_content": "hello",
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (status, share): (_, ShareLinkInfo) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", item.id),
        Some(&alice.token),
        Some(json!({"passcode": "4321", "max_downloads": 1})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Text shares honour the download limit.
    let download = |passcode: &str| {
        format!("/api/s/{}/download?passcode={passcode}", share.code)
    };
    let (status, body) = send_raw(&app, "GET", &download("4321"), None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, b"hello");
    let (status, _) = send_raw(&app, "GET", &download("4321"), None, None).await;
    assert_eq!(status, StatusCode::GONE);

    // A second share to exercise passcode throttling on the meta endpoint.
    let (_, share): (_, ShareLinkInfo) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", item.id),
        Some(&alice.token),
        Some(json!({"passcode": "4321"})),
    )
    .await;
    for guess in 0..10 {
        let (status, meta): (_, serde_json::Value) = send_json(
            &app,
            "GET",
            &format!("/api/s/{}/meta?passcode={guess:04}", share.code),
            None,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(meta["locked"], true);
    }
    let (status, _) = send_raw(
        &app,
        "GET",
        &format!("/api/s/{}/meta?passcode=4321", share.code),
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    // Viewing the locked page without a passcode still works.
    let (status, _) = send_raw(&app, "GET", &format!("/api/s/{}/meta", share.code), None, None).await;
    assert_eq!(status, StatusCode::OK);
}
