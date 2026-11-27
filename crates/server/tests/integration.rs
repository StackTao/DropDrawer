use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::{
    body::Body,
    extract::{ConnectInfo, Path as AxumPath, State},
    http::{header, HeaderMap, Request, StatusCode},
    response::IntoResponse,
    routing::{get, post, put},
    Extension, Json, Router,
};
use chrono::{Duration, Utc};
use futures_util::StreamExt;
use dropdrawer_server::{
    admin::TrustProxy,
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
    test_server_with_local_file_limit(None)
}

fn test_server_with_local_file_limit(
    limit: Option<u64>,
) -> (Router, Arc<AppState>, TempDir) {
    let tmp = TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("test.db")).unwrap();
    let state = AppState::with_google_login(
        db,
        "test-jwt-secret".to_string(),
        tmp.path().join("local_blobs"),
        None,
        limit,
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
            email: None,
            email_code: None,
            invite_code: None,
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
            app_version: None,
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
    type MockDriveFiles = Arc<Mutex<HashMap<String, Vec<u8>>>>;
    let files: MockDriveFiles = Arc::new(Mutex::new(HashMap::new()));
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
                |State(store): State<MockDriveFiles>,
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
                |State(store): State<MockDriveFiles>,
                 AxumPath(id): AxumPath<String>| async move {
                    store.lock().unwrap().get(&id).cloned().unwrap_or_default()
                },
            )
            .delete(
                |State(store): State<MockDriveFiles>,
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

    let (app, state, _tmp) = test_server_with_local_file_limit(Some(10));
    let (_, auth): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({ "username": "bob", "password": "password123" })),
    )
    .await;
    let token = auth.token;

    let (_, initial): (_, Vec<StorageBackendSummary>) =
        send_json(&app, "GET", "/api/storage", Some(&token), None).await;
    let local = &initial[0];
    assert!(local.is_default);

    // Configure Drive and edit its credentials before using it as the default.
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
            is_default: false,
        })
        .unwrap()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let edit_url = format!("/api/storage/{}", backend.id);
    let (status, settings): (_, serde_json::Value) =
        send_json(&app, "GET", &edit_url, Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(settings, json!({"max_bytes": null}));

    let (_, edited): (_, Vec<StorageBackendSummary>) = send_json(
        &app,
        "PATCH",
        &edit_url,
        Some(&token),
        Some(json!({
            "name": "Edited Google Drive",
            "config": { "client_secret": "", "refresh_token": "rotated-token" },
        })),
    )
    .await;
    assert_eq!(edited[0].id, local.id);
    assert!(edited[0].is_default);
    assert_eq!(edited[1].name, "Edited Google Drive");
    let record = state.db.get_storage_backend(&backend.id, &auth.user.id).unwrap().unwrap();
    let StorageBackendConfig::GoogleDrive { client_secret, refresh_token, .. } = record.config else {
        panic!("editing must preserve the provider type");
    };
    assert_eq!(client_secret, "csec");
    assert_eq!(refresh_token, "rotated-token");

    let (_, selected): (_, Vec<StorageBackendSummary>) =
        send_json(&app, "PUT", &format!("{edit_url}/default"), Some(&token), None).await;
    assert_eq!(selected[0].id, backend.id);
    assert!(selected[0].is_default);
    assert!(!selected[1].is_default);

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
            storage_backend_id: None,
            ttl_hours: Some(12),
        })
        .unwrap()),
    )
    .await;

    let payload = b"google-drive-bytes";
    let put_req = Request::builder()
        .method("PUT")
        .uri(format!("/api/drawer/items/{}/upload", item.id))
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::from(payload.to_vec()))
        .unwrap();
    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::OK);
    assert_eq!(
        files.lock().unwrap().get("gdrive-file-99").map(|v| v.as_slice()),
        Some(payload.as_slice())
    );

    let (_, selected): (_, Vec<StorageBackendSummary>) = send_json(
        &app,
        "PUT",
        &format!("/api/storage/{}/default", local.id),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(selected[0].id, local.id);
    assert!(selected[0].is_default);

    // Files already uploaded to Drive are still available after switching back.
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
async fn browser_share_without_upload_and_with_single_use_cloud_fallback() {
    use futures_util::SinkExt;
    use std::time::Duration;
    use tokio_tungstenite::{connect_async, tungstenite::Message};

    let (app, state, _tmp) = spawn_test_server().await;
    let (_, auth): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "browser-share", "password": "test-password"})),
    )
    .await;
    let token = Some(auth.token.as_str());
    let (_, device): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        token,
        Some(json!({"name": "Sender", "platform": "macos", "iroh_node_id": "test-node"})),
    )
    .await;
    let (_, item): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        token,
        Some(
            json!({"device_id": device.id, "kind": "file", "name": "share.bin",
            "size": 4, "transfer_mode": "p2p_only"}),
        ),
    )
    .await;
    let (status, share): (_, ShareLinkInfo) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", item.id),
        token,
        Some(json!({"passcode": "8421", "max_downloads": 1})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let base = format!("/api/s/{}", share.code);
    let (_, meta): (_, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("{base}/meta?passcode=8421"),
        None,
        None,
    )
    .await;
    assert_eq!(meta["items"][0]["cloud_ready"], false);
    let offer_path = format!("{base}/peer");
    let offer = json!({"item_id": item.id, "passcode":"8421",
        "sdp": "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=candidate:test\r\n"});
    let (status, _) = send_raw(&app, "POST", &offer_path, None, Some(offer.clone())).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        state
            .db
            .get_share_link(&share.code)
            .unwrap()
            .unwrap()
            .download_count,
        0
    );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let router = app.clone();
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let (mut sender, _) = connect_async(format!(
        "ws://127.0.0.1:{port}/ws?token={}&device_id={}",
        auth.token, device.id
    ))
    .await
    .unwrap();

    let session = tokio::time::timeout(Duration::from_secs(4), async {
        sender
            .send(Message::text(
                r#"{"type":"browser_share_ready","payload":{}}"#,
            ))
            .await
            .unwrap();
        sender
            .send(Message::text(r#"{"type":"ping"}"#))
            .await
            .unwrap();
        while let Some(Ok(Message::Text(text))) = sender.next().await {
            if serde_json::from_str::<serde_json::Value>(&text).unwrap()["type"] == "pong" {
                break;
            }
        }
        let signal = async {
            while let Some(Ok(Message::Text(text))) = sender.next().await {
                let event: serde_json::Value = serde_json::from_str(&text).unwrap();
                if event["type"] != "browser_share_offer" {
                    continue;
                }
                let session = &event["payload"];
                assert_eq!(session["item_id"], item.id);
                assert!(!session["sdp"].as_str().unwrap().contains("a=candidate:"));
                sender
                    .send(Message::text(
                        json!({"type":"browser_share_answer", "payload":{
                            "session_id":session["session_id"],
                        "sdp":"v=0\r\na=ice-lite:ice-lite\r\na=candidate:1 1 udp 100 192.168.1.3 7777 typ host\r\n",
                        }})
                        .to_string(),
                    ))
                    .await
                    .unwrap();
                return session["start_token"].clone();
            }
            panic!("sender closed before seeing the browser offer")
        };
        let ((status, answer), start_token) = tokio::join!(
            send_json::<serde_json::Value>(&app, "POST", &offer_path, None, Some(offer)),
            signal
        );
        assert_eq!(status, StatusCode::OK);
        (answer["session"].as_str().unwrap().to_owned(), start_token)
    })
    .await
    .unwrap();

    let claim_path = format!("{base}/peer/{}/claim", session.0);
    let claim = |passcode| Some(json!({"item_id":item.id, "passcode":passcode}));
    let (status, _) = send_raw(&app, "POST", &claim_path, None, claim("9999")).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        state
            .db
            .get_share_link(&share.code)
            .unwrap()
            .unwrap()
            .download_count,
        0
    );
    let (status, grant): (_, serde_json::Value) =
        send_json(&app, "POST", &claim_path, None, claim("8421")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(grant["start_token"], session.1);
    let (status, _) = send_raw(&app, "POST", &claim_path, None, claim("8421")).await;
    assert_eq!(status, StatusCode::GONE);

    // If a cloud copy appears, the same download can fall back once.
    let (_, plan): (_, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item.id),
        token,
        Some(json!({})),
    )
    .await;
    let UploadPlan::ServerStreamPut { url, .. } = plan else {
        panic!("expected local disk upload");
    };
    let request = Request::builder()
        .method("PUT")
        .uri(url)
        .header(header::AUTHORIZATION, format!("Bearer {}", auth.token))
        .body(Body::from("test"))
        .unwrap();
    assert_eq!(
        app.clone().oneshot(request).await.unwrap().status(),
        StatusCode::OK
    );
    let fallback_path = format!(
        "{base}/download?item_id={}&passcode=8421&peer_session={}",
        item.id, session.0
    );
    let (status, bytes) = send_raw(&app, "GET", &fallback_path, None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(&bytes[..], b"test");
    let (status, _) = send_raw(&app, "GET", &fallback_path, None, None).await;
    assert_eq!(status, StatusCode::GONE);
    assert_eq!(
        state
            .db
            .get_share_link(&share.code)
            .unwrap()
            .unwrap()
            .download_count,
        1
    );
    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn test_public_share_link_passcode_limit_and_revoke() {
    let (app, state, _tmp) = spawn_test_server().await;

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
    assert_eq!(share.code.len(), 12);
    assert!(share.code.bytes().all(|byte| byte.is_ascii_alphanumeric()));

    // 3. List shares includes the newly created share.
    let (st, shares): (StatusCode, Vec<ShareLinkInfo>) =
        send_json(&app, "GET", "/api/shares", Some(&token), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(shares.len(), 1);
    assert_eq!(shares[0].code, share.code);

    // The eight-character links created by older versions remain usable.
    let mut legacy = state.db.get_share_link(&share.code).unwrap().unwrap();
    legacy.code = "abcdefgh".into();
    state.db.create_share_link(&legacy, std::slice::from_ref(&item.id)).unwrap();
    let (status, _) = send_raw(&app, "GET", "/s/abcdefgh", None, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send_raw(&app, "GET", "/api/s/abcdefgh/meta", None, None).await;
    assert_eq!(status, StatusCode::OK);

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
    // Without a custom title, the file name stays hidden until the passcode.
    assert_eq!(meta_locked["name"], json!("此分享需要提取码"));
    assert_eq!(meta_locked["items"], json!([]));

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

    // Before the passcode, only the title, count and total size are visible.
    let (st, locked_meta): (StatusCode, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("/api/s/{}/meta", bundle.code),
        None,
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(locked_meta["locked"], json!(true));
    assert_eq!(locked_meta["item_count"], json!(2));
    assert_eq!(locked_meta["items"].as_array().unwrap().len(), 0);

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
async fn test_local_file_upload_limit_checks_plans_and_streams() {
    const LIMIT: usize = 10 * 1024 * 1024;
    let (app, state, _tmp) = test_server_with_local_file_limit(Some(LIMIT as u64));
    let (_, owner): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "owner", "password": "password123"})),
    )
    .await;
    let token = Some(owner.token.as_str());

    for size in [LIMIT, LIMIT + 1] {
        let (_, item): (_, DrawerItem) = send_json(
            &app,
            "POST",
            "/api/drawer/items",
            token,
            Some(json!({
                "device_id": "test-device",
                "name": "file.bin",
                "kind": "file",
                "size": size,
                "transfer_mode": "p2p_only",
            })),
        )
        .await;
        let item_url = format!("/api/drawer/items/{}", item.id);
        let (plan_status, _) = send_raw(
            &app,
            "POST",
            &format!("{item_url}/upload-plan"),
            token,
            Some(json!({})),
        )
        .await;
        if size > LIMIT {
            assert_eq!(plan_status, StatusCode::PAYLOAD_TOO_LARGE);
            continue;
        }
        assert_eq!(plan_status, StatusCode::OK);
        let upload = || {
            Request::builder()
                .method("PUT")
                .uri(format!("{item_url}/upload"))
                .header(header::AUTHORIZATION, format!("Bearer {}", owner.token))
        };
        let payload = bytes::Bytes::from(vec![1; LIMIT]);
        let at_limit = upload()
            .header(header::CONTENT_LENGTH, LIMIT)
            .body(Body::from(payload.clone()))
            .unwrap();
        assert_eq!(
            app.clone().oneshot(at_limit).await.unwrap().status(),
            StatusCode::OK
        );
        let over_limit = upload()
            .header(header::CONTENT_LENGTH, LIMIT + 1)
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.clone().oneshot(over_limit).await.unwrap().status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );

        // An upload that omits Content-Length can exceed its declared item size.
        let chunks = futures_util::stream::iter([
            Ok::<_, std::io::Error>(bytes::Bytes::from(vec![2; LIMIT])),
            Ok(bytes::Bytes::from_static(b"x")),
        ]);
        let chunked = upload().body(Body::from_stream(chunks)).unwrap();
        assert_eq!(
            app.clone().oneshot(chunked).await.unwrap().status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );
        let owner_id = &owner.user.id;
        let file_dir = state.user_local_storage_dir(owner_id).join(owner_id);
        assert_eq!(std::fs::read_dir(&file_dir).unwrap().count(), 1);
        let (download_status, old_file) =
            send_raw(&app, "GET", &format!("{item_url}/download"), token, None).await;
        assert_eq!(download_status, StatusCode::OK);
        assert_eq!(old_file.as_slice(), payload.as_ref());
    }
}

#[tokio::test]
async fn test_edit_local_storage_preserves_ownership_and_path() {
    let (app, state, _tmp) = spawn_test_server().await;
    let (_, owner): (_, AuthResponse) = send_json(
        &app, "POST", "/api/auth/register", None,
        Some(json!({"username": "owner", "password": "password123"})),
    ).await;
    let (_, other): (_, AuthResponse) = send_json(
        &app, "POST", "/api/auth/register", None,
        Some(json!({"username": "other", "password": "password123"})),
    ).await;
    let (_, backends): (_, Vec<StorageBackendSummary>) =
        send_json(&app, "GET", "/api/storage", Some(&owner.token), None).await;
    let local = &backends[0];
    let url = format!("/api/storage/{}", local.id);
    let edit = json!({"name": "Local archive", "config": {"max_bytes": 1024}});

    for (method, path, body) in [
        ("GET", url.clone(), None),
        ("PATCH", url.clone(), Some(edit.clone())),
        ("PUT", format!("{url}/default"), None),
    ] {
        let (status, _) = send_raw(&app, method, &path, Some(&other.token), body).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
    for config in [json!({"root_dir": "/"}), json!({"max_bytes": 0})] {
        let (status, _) = send_raw(
            &app, "PATCH", &url, Some(&owner.token),
            Some(json!({"name": "Local archive", "config": config})),
        ).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, edited): (_, Vec<StorageBackendSummary>) =
        send_json(&app, "PATCH", &url, Some(&owner.token), Some(edit)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(edited[0].id, local.id);
    assert_eq!(edited[0].name, "Local archive");
    assert_eq!(edited[0].display_target, local.display_target);
    assert!(edited[0].is_default);
    let (_, settings): (_, serde_json::Value) =
        send_json(&app, "GET", &url, Some(&owner.token), None).await;
    assert_eq!(settings, json!({"max_bytes": 1024}));

    let (status, _): (_, Vec<StorageBackendSummary>) = send_json(
        &app, "PATCH", &url, Some(&owner.token),
        Some(json!({"name": "Local archive", "config": {"max_bytes": null}})),
    ).await;
    assert_eq!(status, StatusCode::OK);
    let record = state.resolve_backend(&owner.user.id, None).unwrap();
    assert!(matches!(record.config, StorageBackendConfig::Local { max_bytes: None, .. }));
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
async fn google_drive_callback_uses_static_html_and_expires_pending_states() {
    use std::time::{Duration, Instant};
    use dropdrawer_server::state::PendingGoogleOAuth;

    let (app, state, _tmp) = spawn_test_server().await;
    let pending = PendingGoogleOAuth {
        user_id: "test-user".into(),
        name: "test-drive".into(),
        client_id: "test-client".into(),
        client_secret: "test-secret".into(),
        folder_id: "root".into(),
        is_default: false,
        redirect_uri: "http://example.test/callback".into(),
        expires_at: Instant::now() + Duration::from_secs(60),
    };
    state.pending_google_oauth.insert("cancelled".into(), pending.clone());
    let uri = "/api/oauth/google/callback?error=%3Cb%3Ecallback-marker%3C%2Fb%3E&state=cancelled";
    let response = app.clone().oneshot(Request::get(uri).body(Body::empty()).unwrap())
        .await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.headers()[header::CONTENT_SECURITY_POLICY]
        .to_str().unwrap().contains("default-src 'none'"));
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    let body = axum::body::to_bytes(response.into_body(), 8192).await.unwrap();
    assert!(!String::from_utf8_lossy(&body).contains("callback-marker"));
    assert!(!state.pending_google_oauth.contains_key("cancelled"));

    let expired = PendingGoogleOAuth {
        expires_at: Instant::now() - Duration::from_secs(1),
        ..pending.clone()
    };
    state.pending_google_oauth.insert("callback-expired".into(), expired.clone());
    let (status, body) = send_raw(
        &app, "GET", "/api/oauth/google/callback?state=callback-expired&code=unused", None, None,
    ).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert!(String::from_utf8_lossy(&body).contains("授权会话已过期"));
    assert!(!state.pending_google_oauth.contains_key("callback-expired"));

    state.pending_google_oauth.insert("cleanup-expired".into(), expired);
    state.pending_google_oauth.insert("still-valid".into(), pending);
    run_ttl_cleanup_once(&state).await.unwrap();
    assert!(!state.pending_google_oauth.contains_key("cleanup-expired"));
    assert!(state.pending_google_oauth.contains_key("still-valid"));
}

#[tokio::test]
async fn public_share_misses_are_limited_across_endpoints() {
    let (app, _state, _tmp) = spawn_test_server().await;
    let peer = "192.168.50.10:12000".parse::<std::net::SocketAddr>().unwrap();
    let app_at_peer = app.clone().layer(Extension(ConnectInfo(peer)));
    for attempt in 0..60 {
        let uri = if attempt % 2 == 0 {
            format!("/api/s/{attempt:012}/meta")
        } else {
            format!("/api/s/{attempt:08}/download")
        };
        let (status, _) = send_raw(&app_at_peer, "GET", &uri, None, None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
    let uri = "/api/s/000000000061/download";
    let (status, _) = send_raw(&app_at_peer, "GET", uri, None, None).await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    let peer = "192.168.50.11:12000".parse::<std::net::SocketAddr>().unwrap();
    let (status, _) = send_raw(&app.layer(Extension(ConnectInfo(peer))), "GET", uri, None, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn forged_forwarded_entries_do_not_reset_the_login_limit() {
    let (app, _state, _tmp) = spawn_test_server().await;
    send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "alice", "password": "password123"})),
    )
    .await;
    // Behind nginx with `$proxy_add_x_forwarded_for`: the client may put anything
    // in front, the proxy appends the address it really saw.
    let proxy = "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap();
    let behind_proxy = app.layer(Extension(ConnectInfo(proxy))).layer(Extension(TrustProxy(true)));
    let login = |forwarded: String, password: &str| {
        Request::post("/api/auth/login")
            .header(header::CONTENT_TYPE, "application/json")
            .header("x-forwarded-for", forwarded)
            .header("x-real-ip", "198.51.100.250")
            .body(Body::from(json!({"username": "alice", "password": password}).to_string()))
            .unwrap()
    };
    for attempt in 0..10 {
        let forged = format!("198.51.100.{attempt}, 203.0.113.20");
        let response = behind_proxy.clone().oneshot(login(forged, "wrong-password")).await.unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }
    let response = behind_proxy
        .clone()
        .oneshot(login("198.51.100.99, 203.0.113.20".into(), "password123"))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    // A different real client behind the same proxy is unaffected.
    let response = behind_proxy.oneshot(login("203.0.113.21".into(), "password123")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
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

    let peer = "192.168.50.10:12000".parse::<std::net::SocketAddr>().unwrap();
    let app_at_peer = app.clone().layer(Extension(ConnectInfo(peer)));
    for _ in 0..10 {
        let (status, _) = send_raw(
            &app_at_peer,
            "POST",
            "/api/auth/login",
            None,
            Some(json!({"username": "alice", "password": "wrong-password"})),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    // Forwarded IPs are ignored on a directly exposed server, including Docker.
    let request = || Request::post("/api/auth/login")
        .header(header::CONTENT_TYPE, "application/json")
        .header("x-forwarded-for", "203.0.113.20")
        .body(Body::from(json!({"username": "alice", "password": "password123"}).to_string()))
        .unwrap();
    let response = app_at_peer.clone().oneshot(request()).await.unwrap();
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);

    let response = app_at_peer.layer(Extension(TrustProxy(true)))
        .oneshot(request()).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let peer = "192.168.50.11:12000".parse::<std::net::SocketAddr>().unwrap();
    let response = app.clone().layer(Extension(ConnectInfo(peer)))
        .oneshot(request()).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

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

#[tokio::test]
async fn test_self_service_account_password_email_bind_and_delete() {
    use dropdrawer_server::mailer::MemoryEmailSender;
    use protocol::AccountInfo;

    let (app, state, _tmp) = spawn_test_server().await;
    let sink = MemoryEmailSender::new();
    state.set_email_sender(Arc::new(sink.clone()));

    let (st, reg): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "self_user", "password": "oldpassword"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    // 1. Inspect account info via GET /api/auth/me.
    let (st, info): (StatusCode, AccountInfo) =
        send_json(&app, "GET", "/api/auth/me", Some(&reg.token), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(info.username, "self_user");
    assert!(info.has_password);
    assert!(!info.email_verified);
    assert!(info.email_binding_available);

    // 2. Bind verified email via code.
    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/auth/me/email/send-code",
        Some(&reg.token),
        Some(json!({"email": "self@example.com"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let emails = sink.take_sent();
    assert_eq!(emails.len(), 1);
    let code = emails[0].subject.rsplit('：').next().unwrap().trim().to_string();

    // A session alone can't change the recovery email: the password is required.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/email/confirm",
        Some(&reg.token),
        Some(json!({"email": "self@example.com", "code": code})),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, bound): (StatusCode, AccountInfo) = send_json(
        &app,
        "POST",
        "/api/auth/me/email/confirm",
        Some(&reg.token),
        Some(json!({"email": "self@example.com", "code": code, "current_password": "oldpassword"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(bound.email.as_deref(), Some("self@example.com"));
    assert!(bound.email_verified);

    // 3. Change password -> old token revoked, new token works.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/password",
        Some(&reg.token),
        Some(json!({"current_password": "wrong", "new_password": "newpassword123"})),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // Two live devices: the one changing the password keeps its connection,
    // the other is disconnected along with its now-revoked token.
    for device in ["this-device", "other-device"] {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        state.connections.insert((reg.user.id.clone(), device.into()), tx);
    }
    let (st, updated): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/me/password",
        Some(&reg.token),
        Some(json!({
            "current_password": "oldpassword",
            "new_password": "newpassword123",
            "device_id": "this-device",
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert!(state.connections.contains_key(&(reg.user.id.clone(), "this-device".into())));
    assert!(!state.connections.contains_key(&(reg.user.id.clone(), "other-device".into())));

    // Old token must be rejected now.
    let (st, _) = send_raw(&app, "GET", "/api/auth/me", Some(&reg.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    // New token works.
    let (st, _): (StatusCode, AccountInfo) =
        send_json(&app, "GET", "/api/auth/me", Some(&updated.token), None).await;
    assert_eq!(st, StatusCode::OK);

    // 4. Delete own account (wrong password fails, right password deletes user & invalidates token).
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/delete",
        Some(&updated.token),
        Some(json!({"password": "wrong"})),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/delete",
        Some(&updated.token),
        Some(json!({"password": "newpassword123"})),
    )
    .await;
    assert_eq!(st, StatusCode::NO_CONTENT);

    let (st, _) = send_raw(&app, "GET", "/api/auth/me", Some(&updated.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn passwordless_accounts_must_sign_in_again_for_security_changes() {
    use dropdrawer_server::auth::Claims;
    use dropdrawer_server::mailer::MemoryEmailSender;
    use jsonwebtoken::{EncodingKey, Header, encode};

    let (app, state, _tmp) = spawn_test_server().await;
    state.set_email_sender(Arc::new(MemoryEmailSender::new()));
    // A Google-only account: no password to ask for.
    let user = state.db.create_user("g-user", "gina", "").unwrap();
    let token_signed_in = |minutes_ago: i64| {
        let now = Utc::now();
        let claims = Claims {
            sub: user.id.clone(),
            username: user.username.clone(),
            exp: (now + Duration::days(1)).timestamp() as usize,
            role: None,
            ver: 0,
            iat: (now - Duration::minutes(minutes_ago)).timestamp() as usize,
        };
        encode(&Header::default(), &claims, &EncodingKey::from_secret(state.jwt_secret.as_bytes())).unwrap()
    };
    let stale = token_signed_in(60);
    let fresh = token_signed_in(1);

    // An old session can't set a password, change the email or delete the account.
    for (path, body) in [
        ("/api/auth/me/password", json!({"new_password": "brand-new-password"})),
        ("/api/auth/me/email/send-code", json!({"email": "gina@example.com"})),
        ("/api/auth/me/email/confirm", json!({"email": "gina@example.com", "code": "123456"})),
        ("/api/auth/me/delete", json!({"confirm_username": "gina"})),
    ] {
        let (st, body) = send_raw(&app, "POST", path, Some(&stale), Some(body)).await;
        assert_eq!(st, StatusCode::FORBIDDEN, "{path}");
        assert!(String::from_utf8_lossy(&body).contains("重新用 Google 登录"), "{path}");
    }
    // After signing in again it works.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/password",
        Some(&fresh),
        Some(json!({"new_password": "brand-new-password"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
}

/// A drawer file whose storage delete fails: a directory sits where the file should be.
fn stuck_cloud_file(state: &AppState, user_id: &str) -> std::path::PathBuf {
    let backend = state.resolve_backend(user_id, None).unwrap();
    let storage_key = format!("{user_id}/stuck.txt");
    let path = state.user_local_storage_dir(user_id).join(&storage_key);
    std::fs::create_dir_all(&path).unwrap();
    std::fs::write(path.join("keep"), b"x").unwrap();
    state
        .db
        .create_drawer_item(&DrawerItemRow {
            id: "stuck".into(),
            user_id: user_id.to_owned(),
            owner_device_id: "device".into(),
            kind: DrawerItemKind::File,
            name: "stuck.txt".into(),
            size: 1,
            mime_type: None,
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: Some(backend.id),
            storage_path: Some(storage_key),
            cloud_ready: true,
            expires_at: None,
            created_at: Utc::now(),
        })
        .unwrap();
    path
}

#[tokio::test]
async fn admin_delete_keeps_users_with_stuck_files_unless_forced() {
    let (app, state, _tmp) = admin_test_server();
    let admin = admin_login(&app).await;
    let user = state.db.create_user("stuck-user", "stuck", "").unwrap();
    stuck_cloud_file(&state, &user.id);
    let uri = format!("/api/admin/users/{}", user.id);

    let (st, _) = send_raw(&app, "DELETE", &uri, Some(&admin), None).await;
    assert_eq!(st, StatusCode::CONFLICT);
    assert!(state.db.find_user_by_id(&user.id).unwrap().is_some());

    let (st, _) = send_raw(&app, "DELETE", &format!("{uri}?force=true"), Some(&admin), None).await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert!(state.db.find_user_by_id(&user.id).unwrap().is_none());
}

#[tokio::test]
async fn account_is_kept_when_its_cloud_files_cannot_be_deleted() {
    let (app, state, _tmp) = spawn_test_server().await;
    let (_, reg): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "leaver", "password": "password123"})),
    )
    .await;
    let user_id = reg.user.id.clone();
    let path = stuck_cloud_file(&state, &user_id);

    let delete = || {
        send_raw(
            &app,
            "POST",
            "/api/auth/me/delete",
            Some(&reg.token),
            Some(json!({"password": "password123"})),
        )
    };
    let (st, _) = delete().await;
    assert_eq!(st, StatusCode::BAD_GATEWAY);
    // The account, its storage settings and the retry record all remain.
    assert!(state.db.find_user_by_id(&user_id).unwrap().is_some());
    assert!(state.db.get_drawer_item("stuck", &user_id).unwrap().is_some());

    // Once the file can be removed, deletion goes through.
    std::fs::remove_dir_all(&path).unwrap();
    std::fs::write(&path, b"x").unwrap();
    let (st, _) = delete().await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    assert!(state.db.find_user_by_id(&user_id).unwrap().is_none());
    assert!(!path.exists());
}

#[tokio::test]
async fn account_deletion_keeps_files_on_a_blocked_storage_endpoint() {
    let (app, state, _tmp) = spawn_test_server().await;
    let (_, reg): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "nas_owner", "password": "password123"})),
    )
    .await;
    let user_id = &reg.user.id;
    let backend = state
        .db
        .create_storage_backend(
            "office-nas",
            user_id,
            "Office NAS",
            &StorageBackendConfig::WebDav {
                base_url: "http://127.0.0.1:9/dav".into(),
                username: "test-user".into(),
                password: "test-password".into(),
            },
            false,
        )
        .unwrap();
    let mut settings = state.runtime_settings();
    settings.storage_policy.block_private_endpoints = true;
    state.apply_and_persist_settings(settings).unwrap();

    state
        .db
        .create_drawer_item(&DrawerItemRow {
            id: "stuck".into(),
            user_id: user_id.clone(),
            owner_device_id: "device".into(),
            kind: DrawerItemKind::File,
            name: "stuck.txt".into(),
            size: 1,
            mime_type: None,
            blake3_hash: None,
            text_content: None,
            thumbnail_base64: None,
            transfer_mode: TransferMode::CloudCached,
            storage_backend_id: Some(backend.id.clone()),
            storage_path: Some("stuck.txt".into()),
            cloud_ready: true,
            expires_at: None,
            created_at: Utc::now(),
        })
        .unwrap();
    let (status, _) = send_raw(
        &app,
        "POST",
        "/api/auth/me/delete",
        Some(&reg.token),
        Some(json!({"password": "password123"})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert!(state.db.find_user_by_id(user_id).unwrap().is_some());
    let item = state.db.get_drawer_item("stuck", user_id).unwrap().unwrap();
    assert_eq!(item.storage_backend_id.as_deref(), Some(backend.id.as_str()));
    assert_eq!(item.storage_path.as_deref(), Some("stuck.txt"));
}

#[tokio::test]
async fn test_cloud_upload_deduplication_and_refcounted_deletion() {
    use sha2::{Digest, Sha256};

    let (app, state, _tmp) = spawn_test_server().await;
    let (_, alice): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "dedup_alice", "password": "password123"})),
    )
    .await;
    let (_, bob): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "dedup_bob", "password": "password123"})),
    )
    .await;

    let (_, alice_dev): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&alice.token),
        Some(json!({"device_id": "a-dev", "name": "Mac", "platform": "macos"})),
    )
    .await;
    let (_, bob_dev): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&bob.token),
        Some(json!({"device_id": "b-dev", "name": "Win", "platform": "windows"})),
    )
    .await;

    let payload = b"telegram-style-dedup-content-payload-0123456789";
    let digest = hex::encode(Sha256::digest(payload));

    // 1. Alice uploads item 1 normally.
    let (_, item1): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&alice.token),
        Some(json!({
            "device_id": alice_dev.id,
            "kind": "file",
            "name": "report-v1.bin",
            "size": payload.len(),
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (status, plan1): (_, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item1.id),
        Some(&alice.token),
        Some(json!({"content_sha256": digest, "size": payload.len()})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let upload_url = match plan1 {
        UploadPlan::ServerStreamPut { url, .. } => url,
        other => panic!("expected ServerStreamPut for first upload, got {other:?}"),
    };
    let put_req = Request::builder()
        .method("PUT")
        .uri(&upload_url)
        .header(header::AUTHORIZATION, format!("Bearer {}", alice.token))
        .body(Body::from(payload.to_vec()))
        .unwrap();
    let put_resp = app.clone().oneshot(put_req).await.unwrap();
    assert_eq!(put_resp.status(), StatusCode::OK);

    let alice_blob_root = state.user_local_storage_dir(&alice.user.id);
    let alice_blob_dir = alice_blob_root.join(&alice.user.id);
    let count_blobs = |dir: &std::path::Path| -> usize {
        std::fs::read_dir(dir)
            .map(|rd| rd.filter_map(|e| e.ok()).filter(|e| e.path().is_file()).count())
            .unwrap_or(0)
    };
    assert_eq!(count_blobs(&alice_blob_dir), 1);

    // 2. Alice uploads item 2 with identical content under a different filename -> instant dedup.
    let (_, item2): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&alice.token),
        Some(json!({
            "device_id": alice_dev.id,
            "kind": "file",
            "name": "report-v2.bin",
            "size": payload.len(),
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (status, plan2): (_, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item2.id),
        Some(&alice.token),
        Some(json!({"content_sha256": digest.to_uppercase(), "size": payload.len()})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    match plan2 {
        UploadPlan::AlreadyCached { item } => {
            assert_eq!(item.id, item2.id);
            assert!(item.cloud_ready);
            assert_eq!(item.name, "report-v2.bin");
        }
        other => panic!("expected AlreadyCached for duplicate upload, got {other:?}"),
    }
    assert_eq!(count_blobs(&alice_blob_dir), 1);

    // 3. Cross-user isolation: Bob uploading the exact same content must NOT dedup against Alice.
    let (_, bob_item): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&bob.token),
        Some(json!({
            "device_id": bob_dev.id,
            "kind": "file",
            "name": "bob-copy.bin",
            "size": payload.len(),
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (status, bob_plan): (_, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", bob_item.id),
        Some(&bob.token),
        Some(json!({"content_sha256": digest, "size": payload.len()})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        matches!(bob_plan, UploadPlan::ServerStreamPut { .. }),
        "cross-user upload must never dedup: {bob_plan:?}"
    );

    // 4. Deleting item 1 must preserve the shared blob so item 2 still downloads intact.
    let (status, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/drawer/items/{}", item1.id),
        Some(&alice.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(count_blobs(&alice_blob_dir), 1);

    let dl_req = Request::builder()
        .method("GET")
        .uri(format!("/api/drawer/items/{}/download", item2.id))
        .header(header::AUTHORIZATION, format!("Bearer {}", alice.token))
        .body(Body::empty())
        .unwrap();
    let dl_resp = app.clone().oneshot(dl_req).await.unwrap();
    assert_eq!(dl_resp.status(), StatusCode::OK);
    let disp = dl_resp
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    assert!(disp.contains("report-v2.bin"), "unexpected Content-Disposition: {disp}");
    let dl_bytes = axum::body::to_bytes(dl_resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    assert_eq!(dl_bytes.as_ref(), payload);

    // 5. Ghost-reuse protection: if the underlying blob is missing on disk,
    //    a new upload falls back to normal upload instead of returning AlreadyCached.
    let row2 = state
        .db
        .get_drawer_item(&item2.id, &alice.user.id)
        .unwrap()
        .unwrap();
    let blob_rel = row2.storage_path.unwrap();
    std::fs::remove_file(alice_blob_root.join(&blob_rel)).unwrap();
    assert_eq!(count_blobs(&alice_blob_dir), 0);

    let (_, item3): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&alice.token),
        Some(json!({
            "device_id": alice_dev.id,
            "kind": "file",
            "name": "report-v3.bin",
            "size": payload.len(),
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (status, plan3): (_, UploadPlan) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", item3.id),
        Some(&alice.token),
        Some(json!({"content_sha256": digest, "size": payload.len()})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        matches!(plan3, UploadPlan::ServerStreamPut { .. }),
        "missing physical blob must fall back to normal upload: {plan3:?}"
    );

    // 6. Re-upload item3 and verify deleting the final reference removes the physical blob.
    let upload_url3 = match plan3 {
        UploadPlan::ServerStreamPut { url, .. } => url,
        _ => unreachable!(),
    };
    let put_resp3 = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&upload_url3)
                .header(header::AUTHORIZATION, format!("Bearer {}", alice.token))
                .body(Body::from(payload.to_vec()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(put_resp3.status(), StatusCode::OK);
    assert_eq!(count_blobs(&alice_blob_dir), 1);

    let (status, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/drawer/items/{}", item3.id),
        Some(&alice.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(count_blobs(&alice_blob_dir), 0);
}

#[tokio::test]
async fn test_admin_console_auth_hot_settings_invites_and_user_governance() {
    use dropdrawer_server::{
        settings::RuntimeSettings,
    };
    use protocol::AuthPublicConfig;

    // 1. The console is disabled by default.
    let (disabled_app, _, _tmp0) = spawn_test_server().await;
    let (st, _) = send_raw(&disabled_app, "GET", "/admin", None, None).await;
    assert_eq!(st, StatusCode::NOT_FOUND);
    let (st, _) = send_raw(
        &disabled_app,
        "POST",
        "/api/admin/login",
        None,
        Some(json!({"token": "anything"})),
    )
    .await;
    assert_eq!(st, StatusCode::NOT_FOUND);

    // 2. The explicitly enabled console accepts a provisioned account.
    let tmp = TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("admin.db")).unwrap();
    create_test_admin(&db);
    let state = AppState::with_full_config(
        db,
        "test-jwt-secret".to_string(),
        tmp.path().join("blobs"),
        RuntimeSettings::default(),
        true,
    );
    let app = build_router(state.clone());

    let (st, page) = send_raw(&app, "GET", "/admin", None, None).await;
    assert_eq!(st, StatusCode::OK);
    assert!(String::from_utf8_lossy(&page).contains("DropDrawer Admin"));

    // Removed key login and old key-based sessions both fail.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(json!({"token": "wrong-token"})),
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST);
    let legacy = dropdrawer_server::auth::create_admin_jwt(&state.jwt_secret, None, 0).unwrap();
    let (st, _) = send_raw(&app, "GET", "/api/admin/session", Some(&legacy), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    let (st, login_json): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(test_admin_credentials()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let admin_jwt = login_json["token"].as_str().unwrap().to_string();

    // Admin JWT cannot access regular user endpoints.
    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&admin_jwt), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // 3. Hot-configure invite_only + Google OAuth via /api/admin/settings.
    let (st, saved): (StatusCode, serde_json::Value) = send_json(
        &app,
        "PUT",
        "/api/admin/settings",
        Some(&admin_jwt),
        Some(json!({
            "registration_mode": "invite_only",
            "password_login_enabled": true,
            "email_verification_required": false,
            "email_allowed_domains": [],
            "email_blocked_domains": [],
            "local_max_file_bytes": 10485760,
            "default_user_local_quota_bytes": 104857600,
            "google": {
                "enabled": true,
                "client_id": "hot-client-id",
                "client_secret": "hot-secret-value",
                "redirect_uri": "https://drop.example.com/api/auth/google/callback"
            },
            "smtp": {
                "enabled": false,
                "host": "",
                "port": 587,
                "security": "start_tls",
                "username": "",
                "password": null,
                "from_address": "",
                "from_name": "DropDrawer"
            }
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(saved["google"]["has_client_secret"], true);
    assert!(saved["google"].get("client_secret").is_none());

    // Public auth config reflects hot changes immediately without restart.
    let (st, pub_cfg): (StatusCode, AuthPublicConfig) =
        send_json(&app, "GET", "/api/auth/config", None, None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(pub_cfg.registration_mode, "invite_only");
    assert!(pub_cfg.providers.iter().any(|p| p.id == "google" && p.enabled));

    // Google /start works live after hot configuration!
    let (st, google_start): (StatusCode, serde_json::Value) =
        send_json(&app, "POST", "/api/auth/google/start", None, None).await;
    assert_eq!(st, StatusCode::OK);
    assert!(
        google_start["authorization_url"]
            .as_str()
            .unwrap()
            .contains("hot-client-id")
    );

    // 4. Invite-only registration enforcement.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "noinvite", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    let (st, invite): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/admin/invites",
        Some(&admin_jwt),
        Some(json!({"note": "vip", "max_uses": 1, "expires_hours": 24})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let invite_code = invite["code"].as_str().unwrap().to_string();

    let (st, alice): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({
            "username": "alice_vip",
            "password": "password123",
            "invite_code": invite_code,
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    // Regular user JWT cannot access /api/admin/*.
    let (st, _) = send_raw(&app, "GET", "/api/admin/overview", Some(&alice.token), None).await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // Reusing single-use invite fails.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({
            "username": "alice_vip_2",
            "password": "password123",
            "invite_code": invite_code,
        })),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // 5. Disable user -> existing JWT immediately rejected & login blocked.
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/admin/users/{}/disable", alice.user.id),
        Some(&admin_jwt),
        Some(json!({"disabled": true})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&alice.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "alice_vip", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // Re-enable, admin reset password, create share, then admin revokes share & deletes user.
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/admin/users/{}/disable", alice.user.id),
        Some(&admin_jwt),
        Some(json!({"disabled": false})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/admin/users/{}/reset-password", alice.user.id),
        Some(&admin_jwt),
        Some(json!({"new_password": "newpassword999"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (st, relogin): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "alice_vip", "password": "newpassword999"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (_, dev): (_, DeviceInfo) = send_json(
        &app,
        "POST",
        "/api/devices",
        Some(&relogin.token),
        Some(json!({"device_id": "d1", "name": "Mac", "platform": "macos"})),
    )
    .await;
    let (_, item): (_, DrawerItem) = send_json(
        &app,
        "POST",
        "/api/drawer/items",
        Some(&relogin.token),
        Some(json!({
            "device_id": dev.id,
            "kind": "text",
            "name": "note",
            "size": 4,
            "text_content": "test",
            "transfer_mode": "cloud_cached",
        })),
    )
    .await;
    let (_, share): (_, ShareLinkInfo) = send_json(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", item.id),
        Some(&relogin.token),
        Some(json!({})),
    )
    .await;

    let (st, shares): (StatusCode, Vec<serde_json::Value>) =
        send_json(&app, "GET", "/api/admin/shares", Some(&admin_jwt), None).await;
    assert_eq!(st, StatusCode::OK);
    assert!(shares.iter().any(|s| s["code"] == share.code));

    let (st, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/admin/shares/{}", share.code),
        Some(&admin_jwt),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::NO_CONTENT);

    let (st, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/admin/users/{}", alice.user.id),
        Some(&admin_jwt),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn test_email_verification_registration_domain_rules_and_password_reset() {
    use dropdrawer_server::{
        mailer::MemoryEmailSender,
        settings::RuntimeSettings,
    };
    use protocol::AuthPublicConfig;

    let tmp = TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("email.db")).unwrap();
    create_test_admin(&db);
    let state = AppState::with_full_config(
        db,
        "test-jwt-secret".to_string(),
        tmp.path().join("blobs"),
        RuntimeSettings::default(),
        true,
    );
    let sink = MemoryEmailSender::new();
    state.set_email_sender(Arc::new(sink.clone()));
    let app = build_router(state.clone());

    let (_, admin_login): (_, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(test_admin_credentials()),
    )
    .await;
    let admin_jwt = admin_login["token"].as_str().unwrap().to_string();

    // Enable SMTP + required email verification + domain whitelist.
    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "PUT",
        "/api/admin/settings",
        Some(&admin_jwt),
        Some(json!({
            "registration_mode": "open",
            "password_login_enabled": true,
            "email_verification_required": true,
            "email_allowed_domains": ["company.com"],
            "email_blocked_domains": [],
            "local_max_file_bytes": null,
            "default_user_local_quota_bytes": null,
            "google": {"enabled": false, "client_id": "", "client_secret": null, "redirect_uri": ""},
            "smtp": {
                "enabled": true,
                "host": "smtp.company.com",
                "port": 587,
                "security": "start_tls",
                "username": "noreply@company.com",
                "password": "app-password",
                "from_address": "noreply@company.com",
                "from_name": "DropDrawer"
            }
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    // Public auth config advertises email verification and password reset.
    let (_, pub_cfg): (_, AuthPublicConfig) =
        send_json(&app, "GET", "/api/auth/config", None, None).await;
    assert!(pub_cfg.email_verification_required);
    assert!(pub_cfg.email_password_reset_enabled);

    // Admin SMTP test button works.
    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/admin/smtp/test",
        Some(&admin_jwt),
        Some(json!({"to": "ops@company.com"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let sent = sink.take_sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].to, "ops@company.com");

    // Non-whitelisted domain blocked.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/email/send-code",
        None,
        Some(json!({"email": "stranger@other.org", "purpose": "register"})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // Send register verification code to whitelisted email.
    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/auth/email/send-code",
        None,
        Some(json!({"email": "bob@company.com", "purpose": "register"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let reg_emails = sink.take_sent();
    assert_eq!(reg_emails.len(), 1);
    let code = reg_emails[0]
        .subject
        .rsplit('：')
        .next()
        .unwrap()
        .trim()
        .to_string();
    assert_eq!(code.len(), 6);

    // Wrong code rejected; valid code registers user with verified email.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({
            "username": "bob",
            "password": "password123",
            "email": "bob@company.com",
            "email_code": "000000"
        })),
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST);

    let (st, reg): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({
            "username": "bob",
            "password": "password123",
            "email": "bob@company.com",
            "email_code": code
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(reg.user.email.as_deref(), Some("bob@company.com"));

    // User can log in with verified email address directly.
    let (st, _): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "BOB@company.com", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    // Self-service password reset via email verification code.
    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/auth/email/send-code",
        None,
        Some(json!({"email": "bob@company.com", "purpose": "reset_password"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let reset_emails = sink.take_sent();
    assert_eq!(reset_emails.len(), 1);
    let reset_code = reset_emails[0]
        .subject
        .rsplit('：')
        .next()
        .unwrap()
        .trim()
        .to_string();

    let (st, _): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/auth/password/reset",
        None,
        Some(json!({
            "email": "bob@company.com",
            "code": reset_code,
            "new_password": "brandnewpassword"
        })),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "bob", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    let (st, _): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "bob", "password": "brandnewpassword"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
}

/// Baseline settings payload (what the admin page sends); tests patch individual fields.
fn admin_settings_payload() -> serde_json::Value {
    json!({
        "registration_mode": "open",
        "password_login_enabled": true,
        "email_verification_required": false,
        "email_allowed_domains": [],
        "email_blocked_domains": [],
        "local_max_file_bytes": null,
        "default_user_local_quota_bytes": null,
        "google": { "enabled": false, "client_id": "", "client_secret": null, "redirect_uri": "" },
        "smtp": {
            "enabled": false, "host": "", "port": 587, "security": "start_tls",
            "username": "", "password": null, "from_address": "", "from_name": "DropDrawer"
        }
    })
}

fn create_test_admin(db: &Database) {
    use dropdrawer_server::{auth::hash_password, db::AdminRole};
    db.create_admin_account(
        "test-super-id",
        "test.super@gmail.com",
        &hash_password("test-super-password").unwrap(),
        AdminRole::Super,
    ).unwrap();
}

fn test_admin_credentials() -> serde_json::Value {
    json!({"username": "test.super@gmail.com", "password": "test-super-password"})
}

fn admin_test_server() -> (Router, Arc<AppState>, TempDir) {
    use dropdrawer_server::settings::RuntimeSettings;
    let tmp = TempDir::new().unwrap();
    let db = Database::open(tmp.path().join("admin-policy.db")).unwrap();
    create_test_admin(&db);
    let state = AppState::with_full_config(
        db,
        "test-jwt-secret".to_string(),
        tmp.path().join("blobs"),
        RuntimeSettings::default(),
        true,
    );
    (build_router(state.clone()), state, tmp)
}

async fn admin_login(app: &Router) -> String {
    let (st, body): (StatusCode, serde_json::Value) = send_json(
        app,
        "POST",
        "/api/admin/login",
        None,
        Some(test_admin_credentials()),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    body["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn admin_google_flow_is_browser_bound_and_separate_from_client_login() {
    let (app, state, _tmp) = admin_test_server();
    let mut config = state.runtime_settings();
    config.google.admin_enabled = true;
    config.google.client_id = "test-client".into();
    config.google.client_secret = "test-secret".into();
    config.google.redirect_uri = "https://drop.example.test/api/auth/google/callback".into();
    state.apply_and_persist_settings(config).unwrap();

    let browser_request = Request::post("/api/admin/google/start")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from("{}")).unwrap();
    let response = app.clone().oneshot(browser_request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let cookie = response.headers()[header::SET_COOKIE].to_str().unwrap();
    assert!(cookie.starts_with("__Host-dd_admin_google_flow=") && cookie.contains("Path=/;"));
    assert!(cookie.contains("SameSite=Lax") && cookie.contains("HttpOnly") && cookie.contains("Secure"));
    let cookie = cookie.split(';').next().unwrap().to_owned();
    let bytes = axum::body::to_bytes(response.into_body(), 8192).await.unwrap();
    let response: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let url = url::Url::parse(response["authorization_url"].as_str().unwrap()).unwrap();
    assert_eq!(url.host_str(), Some("accounts.google.com"));
    let params: HashMap<_, _> = url.query_pairs().collect();
    assert_eq!(params["code_challenge_method"], "S256");
    assert_eq!(params["redirect_uri"], "https://drop.example.test/api/auth/google/callback");
    let flow_id = &params["state"];
    let callback = format!("/api/auth/google/callback?state={flow_id}&error=access_denied");

    let response = app.clone().oneshot(Request::get(&callback).body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(response.headers()[header::LOCATION], "/admin?google=failed");
    assert!(!response.headers().contains_key(header::SET_COOKIE));
    let response = app.clone().oneshot(Request::get(&callback).header(header::COOKIE, cookie)
        .body(Body::empty()).unwrap()).await.unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert!(!response.headers().contains_key(header::SET_COOKIE));

    let (status, _) = send_raw(&app, "POST", "/api/auth/google/start", None, None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    let (status, _) = send_raw(&app, "POST", "/api/admin/login", None, Some(test_admin_credentials())).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn enabled_turnstile_requires_a_challenge_for_both_admin_login_options() {
    let (app, state, _tmp) = admin_test_server();
    let mut config = state.runtime_settings();
    config.google.admin_enabled = true;
    config.google.client_id = "test-client".into();
    config.google.client_secret = "test-secret".into();
    config.google.redirect_uri = "https://drop.example.test/api/auth/google/callback".into();
    config.admin_turnstile = dropdrawer_server::settings::AdminTurnstileSettings {
        enabled: true,
        hostname: "drop.example.test".into(),
        site_key: "public-test-key".into(),
        secret_key: "private-test-key".into(),
    };
    state.apply_and_persist_settings(config).unwrap();

    let (status, config): (_, serde_json::Value) =
        send_json(&app, "GET", "/api/admin/auth/config", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(config, json!({"google_enabled": true, "turnstile_site_key": "public-test-key"}));
    for (uri, payload) in [("/api/admin/login", test_admin_credentials()), ("/api/admin/google/start", json!({}))] {
        let (status, body) = send_raw(&app, "POST", uri, None, Some(payload)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(String::from_utf8_lossy(&body).contains("人机验证"));
    }
    let response = app.oneshot(Request::get("/admin").body(Body::empty()).unwrap()).await.unwrap();
    let csp = response.headers()[header::CONTENT_SECURITY_POLICY].to_str().unwrap();
    assert!(csp.contains("frame-src https://challenges.cloudflare.com"));
    assert!(csp.contains("script-src 'self' https://challenges.cloudflare.com"));
}

async fn put_settings(app: &Router, admin: &str, patch: serde_json::Value) -> StatusCode {
    let mut payload = admin_settings_payload();
    for (k, v) in patch.as_object().unwrap() {
        payload[k] = v.clone();
    }
    send_raw(app, "PUT", "/api/admin/settings", Some(admin), Some(payload))
        .await
        .0
}

async fn register_user(app: &Router, name: &str) -> AuthResponse {
    let (st, auth): (StatusCode, AuthResponse) = send_json(
        app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": name, "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    auth
}

async fn create_text_item(app: &Router, token: &str, device: &str) -> (StatusCode, Vec<u8>) {
    send_raw(
        app,
        "POST",
        "/api/drawer/items",
        Some(token),
        Some(json!({
            "device_id": device, "kind": "text", "name": "note", "size": 5,
            "text_content": "hello", "transfer_mode": "p2p_only"
        })),
    )
    .await
}

#[tokio::test]
async fn test_admin_feature_switches_and_per_user_policies_are_enforced() {
    let (app, _state, _tmp) = admin_test_server();
    let admin = admin_login(&app).await;

    // Usernames containing markup characters are refused.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/auth/register",
        None,
        Some(json!({"username": "x');alert(1)//", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST);

    let alice = register_user(&app, "alice").await;
    let bob = register_user(&app, "bob").await;
    for (tok, dev) in [(&alice.token, "a1"), (&bob.token, "b1")] {
        let (st, _) = send_raw(
            &app,
            "POST",
            "/api/devices",
            Some(tok),
            Some(json!({"device_id": dev, "name": "Mac", "platform": "macos"})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
    }
    let (st, body) = create_text_item(&app, &alice.token, "a1").await;
    assert_eq!(st, StatusCode::OK);
    let alice_item: DrawerItem = serde_json::from_slice(&body).unwrap();
    let (st, body) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", alice_item.id),
        Some(&alice.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let share: ShareLinkInfo = serde_json::from_slice(&body).unwrap();

    // Limits: one device and two items per user; shares capped at 24h.
    assert_eq!(
        put_settings(
            &app,
            &admin,
            json!({
                "limits": {"max_devices_per_user": 1, "max_items_per_user": 2, "max_item_ttl_hours": 48},
                "share_policy": {"require_passcode": false, "max_expires_hours": 24, "max_downloads_cap": null}
            }),
        )
        .await,
        StatusCode::OK
    );
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/devices",
        Some(&alice.token),
        Some(json!({"device_id": "a2", "name": "Phone", "platform": "ios"})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN, "second device exceeds the limit");
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/devices",
        Some(&alice.token),
        Some(json!({"device_id": "a1", "name": "Mac renamed", "platform": "macos"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK, "re-registering an existing device is allowed");

    let (st, body) = create_text_item(&app, &alice.token, "a1").await;
    assert_eq!(st, StatusCode::OK);
    let second: DrawerItem = serde_json::from_slice(&body).unwrap();
    let ttl = second.expires_at.unwrap() - second.created_at;
    assert!(ttl <= Duration::hours(48), "default 7 day TTL is capped by max_item_ttl_hours");
    let (st, _) = create_text_item(&app, &alice.token, "a1").await;
    assert_eq!(st, StatusCode::FORBIDDEN, "third item exceeds the limit");

    let (st, body) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", second.id),
        Some(&alice.token),
        Some(json!({"expires_hours": 1000})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let capped: ShareLinkInfo = serde_json::from_slice(&body).unwrap();
    assert!(capped.expires_at.unwrap() - capped.created_at <= Duration::hours(24));

    // A payload without the new sections (older admin page) keeps them unchanged.
    assert_eq!(put_settings(&app, &admin, json!({})).await, StatusCode::OK);
    let (_, saved): (_, serde_json::Value) =
        send_json(&app, "GET", "/api/admin/settings", Some(&admin), None).await;
    assert_eq!(saved["limits"]["max_items_per_user"], 2);

    // Global switches: sharing and cloud uploads off, public access paused.
    assert_eq!(
        put_settings(
            &app,
            &admin,
            json!({
                "features": {
                    "google_signup_enabled": true, "password_reset_enabled": true,
                    "cloud_upload_enabled": false, "share_create_enabled": false,
                    "share_access_enabled": false
                },
                "limits": {}
            }),
        )
        .await,
        StatusCode::OK
    );
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", alice_item.id),
        Some(&alice.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (st, _) = send_raw(&app, "GET", &format!("/api/s/{}/meta", share.code), None, None).await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (st, body) = create_text_item(&app, &bob.token, "b1").await;
    assert_eq!(st, StatusCode::OK);
    let bob_item: DrawerItem = serde_json::from_slice(&body).unwrap();
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", bob_item.id),
        Some(&bob.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN, "cloud uploads are switched off");

    // Switch everything back on; restrict only alice via her personal policy.
    assert_eq!(put_settings(&app, &admin, json!({"features": {}})).await, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", &format!("/api/s/{}/meta", share.code), None, None).await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(
        &app,
        "PUT",
        &format!("/api/admin/users/{}/policy", alice.user.id),
        Some(&admin),
        Some(json!({"share_blocked": true, "upload_blocked": true, "note": "abuse report"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", alice_item.id),
        Some(&alice.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN, "alice may no longer share");
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/share", bob_item.id),
        Some(&bob.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::OK, "bob is unaffected");
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/drawer/items/{}/upload-plan", alice_item.id),
        Some(&alice.token),
        Some(json!({})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // Storage policy: disabled kinds and private endpoints are refused.
    assert_eq!(
        put_settings(
            &app,
            &admin,
            json!({"storage_policy": {"disabled_backend_kinds": ["web_dav"], "block_private_endpoints": true}}),
        )
        .await,
        StatusCode::OK
    );
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/storage",
        Some(&bob.token),
        Some(json!({"name": "NAS", "config": {"kind": "web_dav", "base_url": "https://dav.example.com", "username": "u", "password": "p"}})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (_, cfg): (_, protocol::ClientConfig) =
        send_json(&app, "GET", "/api/client/config", Some(&bob.token), None).await;
    assert_eq!(
        cfg.features.disabled_storage_kinds,
        vec![protocol::StorageBackendKind::WebDav],
        "clients learn which storage kinds to hide"
    );
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/storage",
        Some(&bob.token),
        Some(json!({"name": "Minio", "config": {
            "kind": "s3", "endpoint": "http://127.0.0.1:9000", "region": "us-east-1",
            "bucket": "b", "access_key_id": "k", "secret_access_key": "s"
        }})),
    )
    .await;
    assert_eq!(st, StatusCode::FORBIDDEN, "loopback endpoint is blocked");

    // The user detail view exposes devices and policy; devices can be removed.
    let (st, detail): (StatusCode, serde_json::Value) = send_json(
        &app,
        "GET",
        &format!("/api/admin/users/{}", alice.user.id),
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(detail["policy"]["share_blocked"], true);
    assert_eq!(detail["devices"].as_array().unwrap().len(), 1);
    assert!(detail["items"][0].get("text_content").is_none(), "content is not exposed");
    let (st, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/admin/users/{}/devices/a1", alice.user.id),
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::NO_CONTENT);

    let (_, audit): (_, Vec<serde_json::Value>) =
        send_json(&app, "GET", "/api/admin/audit", Some(&admin), None).await;
    let actions: Vec<&str> = audit.iter().filter_map(|e| e["action"].as_str()).collect();
    for expected in ["admin.login", "settings.update", "user.policy", "device.remove"] {
        assert!(actions.contains(&expected), "missing audit action {expected}: {actions:?}");
    }
}

#[tokio::test]
async fn test_admin_can_revoke_user_and_admin_sessions() {
    let (app, _state, _tmp) = admin_test_server();
    let admin = admin_login(&app).await;
    let carol = register_user(&app, "carol").await;
    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&carol.token), None).await;
    assert_eq!(st, StatusCode::OK);

    // Forced sign-out revokes every token issued so far.
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/admin/users/{}/sign-out", carol.user.id),
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&carol.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // Logging in again yields a token for the new generation.
    let (st, relogin): (StatusCode, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "carol", "password": "password123"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&relogin.token), None).await;
    assert_eq!(st, StatusCode::OK);

    // An admin password reset also ends existing sessions.
    let (st, _) = send_raw(
        &app,
        "POST",
        &format!("/api/admin/users/{}/reset-password", carol.user.id),
        Some(&admin),
        Some(json!({"new_password": "another-password"})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/devices", Some(&relogin.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // Admin logout invalidates the admin token itself, not just the cookie.
    let (st, _) = send_raw(&app, "GET", "/api/admin/session", Some(&admin), None).await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "POST", "/api/admin/logout", Some(&admin), None).await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/admin/overview", Some(&admin), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // The console page and its assets carry a strict CSP.
    let resp = app
        .clone()
        .oneshot(Request::builder().uri("/admin").body(Body::empty()).unwrap())
        .await
        .unwrap();
    let csp = resp
        .headers()
        .get(header::CONTENT_SECURITY_POLICY)
        .unwrap()
        .to_str()
        .unwrap();
    assert!(csp.contains("script-src 'self'") && !csp.contains("unsafe-inline"));
    let (st, _) = send_raw(&app, "GET", "/admin/assets/admin.js", None, None).await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/admin/assets/../Cargo.toml", None, None).await;
    assert_ne!(st, StatusCode::OK);
}

#[tokio::test]
async fn test_client_config_announcement_min_version_and_device_removal() {
    let (app, _state, _tmp) = admin_test_server();
    let admin = admin_login(&app).await;
    let dana = register_user(&app, "dana").await;

    // Defaults: everything enabled, no announcement, no minimum version.
    let (st, cfg): (StatusCode, protocol::ClientConfig) =
        send_json(&app, "GET", "/api/client/config", Some(&dana.token), None).await;
    assert_eq!(st, StatusCode::OK);
    assert!(cfg.features.share_create_enabled && cfg.features.cloud_upload_enabled);
    assert!(cfg.announcement.is_none() && cfg.min_client_version.is_none());

    assert_eq!(
        put_settings(
            &app,
            &admin,
            json!({
                "announcement": {"enabled": true, "level": "warning", "title": "维护通知", "message": "今晚 23:00 升级"},
                "client_policy": {"min_version": "v0.2.0"},
                "share_policy": {"require_passcode": true, "max_expires_hours": 72, "max_downloads_cap": null}
            }),
        )
        .await,
        StatusCode::OK
    );
    let (_, policy_resp) = send_raw(
        &app,
        "PUT",
        &format!("/api/admin/users/{}/policy", dana.user.id),
        Some(&admin),
        Some(json!({"upload_blocked": true})),
    )
    .await;
    let _ = policy_resp;
    let (_, cfg): (_, protocol::ClientConfig) =
        send_json(&app, "GET", "/api/client/config", Some(&dana.token), None).await;
    let ann = cfg.announcement.expect("announcement is published");
    assert_eq!((ann.level.as_str(), ann.title.as_str()), ("warning", "维护通知"));
    assert_eq!(cfg.min_client_version.as_deref(), Some("0.2.0"));
    assert!(!cfg.features.cloud_upload_enabled, "per-user restriction is reflected");
    assert!(cfg.features.share_create_enabled && cfg.features.share_requires_passcode);
    assert_eq!(cfg.features.max_share_expires_hours, Some(72));
    assert!(cfg.features.disabled_storage_kinds.is_empty());

    // Re-saving identical announcement keeps its id; editing it changes the id.
    assert_eq!(put_settings(&app, &admin, json!({})).await, StatusCode::OK);
    let (_, same): (_, protocol::ClientConfig) =
        send_json(&app, "GET", "/api/client/config", Some(&dana.token), None).await;
    assert_eq!(same.announcement.unwrap().id, ann.id);

    // Minimum version: old and unversioned clients get 426, current ones register.
    let register = |version: Option<&str>| {
        let mut body = json!({"device_id": "dana-mac", "name": "Mac", "platform": "macos", "iroh_node_id": "node-dana"});
        if let Some(v) = version {
            body["app_version"] = json!(v);
        }
        body
    };
    let (st, _) = send_raw(&app, "POST", "/api/devices", Some(&dana.token), Some(register(None))).await;
    assert_eq!(st, StatusCode::UPGRADE_REQUIRED);
    let (st, _) = send_raw(&app, "POST", "/api/devices", Some(&dana.token), Some(register(Some("0.1.9")))).await;
    assert_eq!(st, StatusCode::UPGRADE_REQUIRED);
    let (st, dev): (StatusCode, DeviceInfo) =
        send_json(&app, "POST", "/api/devices", Some(&dana.token), Some(register(Some("0.2.0+7")))).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(dev.app_version.as_deref(), Some("0.2.0+7"));
    let (_, versions): (_, Vec<serde_json::Value>) =
        send_json(&app, "GET", "/api/admin/clients", Some(&admin), None).await;
    assert!(versions.iter().any(|v| v["version"] == "0.2.0+7" && v["platform"] == "macos"));

    // Removing the device bars the old session from re-registering it (by id or node).
    // (Removal times are compared at second precision, so step past the token's second.)
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let (st, _) = send_raw(
        &app,
        "DELETE",
        &format!("/api/admin/users/{}/devices/dana-mac", dana.user.id),
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(st, StatusCode::NO_CONTENT);
    let (st, _) = send_raw(&app, "POST", "/api/devices", Some(&dana.token), Some(register(Some("0.2.0")))).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    // A running client polling its config learns about the removal too.
    let (st, _) = send_raw(&app, "GET", "/api/client/config?device_id=dana-mac", Some(&dana.token), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, _) = send_raw(&app, "GET", "/api/client/config", Some(&dana.token), None).await;
    assert_eq!(st, StatusCode::OK, "other devices of the account are unaffected");
    let mut by_node = register(Some("0.2.0"));
    by_node["device_id"] = json!(null);
    let (st, _) = send_raw(&app, "POST", "/api/devices", Some(&dana.token), Some(by_node)).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED, "same iroh node under a new id is also refused");

    // Signing in again (a session issued after the removal) may register it.
    let (_, relogin): (_, AuthResponse) = send_json(
        &app,
        "POST",
        "/api/auth/login",
        None,
        Some(json!({"username": "dana", "password": "password123"})),
    )
    .await;
    let (st, _) = send_raw(&app, "POST", "/api/devices", Some(&relogin.token), Some(register(Some("0.2.0")))).await;
    assert_eq!(st, StatusCode::OK);
}

#[tokio::test]
async fn test_admin_accounts_roles_totp_and_backup() {
    use dropdrawer_server::admin::totp;

    let (app, state, _tmp) = admin_test_server();
    let owner = admin_login(&app).await;

    // Owner creates a super admin and a read-only admin.
    for (name, role) in [("ops-lead", "super"), ("auditor", "viewer")] {
        let (st, _) = send_raw(
            &app,
            "POST",
            "/api/admin/admins",
            Some(&owner),
            Some(json!({"username": name, "password": "correct horse battery", "role": role})),
        )
        .await;
        assert_eq!(st, StatusCode::OK);
    }
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/admin/admins",
        Some(&owner),
        Some(json!({"username": "weak", "password": "short", "role": "admin"})),
    )
    .await;
    assert_eq!(st, StatusCode::BAD_REQUEST, "admin passwords need 10+ characters");

    let account_login = |name: &str, code: Option<String>| {
        let mut body = json!({"username": name, "password": "correct horse battery"});
        if let Some(c) = code {
            body["totp_code"] = json!(c);
        }
        body
    };
    let (st, body): (StatusCode, serde_json::Value) =
        send_json(&app, "POST", "/api/admin/login", None, Some(account_login("auditor", None))).await;
    assert_eq!(st, StatusCode::OK);
    let auditor = body["token"].as_str().unwrap().to_string();

    // Viewer: can read, cannot write, cannot manage admins.
    let (st, _) = send_raw(&app, "GET", "/api/admin/users", Some(&auditor), None).await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(put_settings(&app, &auditor, json!({})).await, StatusCode::FORBIDDEN);
    let (st, _) = send_raw(&app, "GET", "/api/admin/admins", Some(&auditor), None).await;
    assert_eq!(st, StatusCode::FORBIDDEN);
    let (st, _) = send_raw(&app, "GET", "/api/admin/maintenance/backup", Some(&auditor), None).await;
    assert_eq!(st, StatusCode::FORBIDDEN);

    // Super admin enrolls TOTP; afterwards logins need a fresh code.
    let (_, body): (_, serde_json::Value) =
        send_json(&app, "POST", "/api/admin/login", None, Some(account_login("ops-lead", None))).await;
    let lead = body["token"].as_str().unwrap().to_string();
    let (st, setup): (StatusCode, serde_json::Value) =
        send_json(&app, "POST", "/api/admin/me/totp/setup", Some(&lead), None).await;
    assert_eq!(st, StatusCode::OK);
    let secret = setup["secret"].as_str().unwrap().to_string();
    assert!(setup["qr_data_uri"].as_str().unwrap().starts_with("data:image/svg+xml"));
    let now = Utc::now().timestamp();
    let enroll_code = totp::code_at(&secret, totp::current_step(now) - 1).unwrap();
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/admin/me/totp/enable",
        Some(&lead),
        Some(json!({"code": enroll_code})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);

    let (st, body) =
        send_raw(&app, "POST", "/api/admin/login", None, Some(account_login("ops-lead", None))).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    assert_eq!(String::from_utf8_lossy(&body), "TOTP_REQUIRED");
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(account_login("ops-lead", Some("000000".into()))),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    // A code from a step already consumed cannot be replayed.
    let (st, _) = send_raw(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(account_login("ops-lead", Some(enroll_code.clone()))),
    )
    .await;
    assert_eq!(st, StatusCode::UNAUTHORIZED, "TOTP codes are single use");
    let fresh = totp::code_at(&secret, totp::current_step(now)).unwrap();
    let (st, body): (StatusCode, serde_json::Value) = send_json(
        &app,
        "POST",
        "/api/admin/login",
        None,
        Some(account_login("ops-lead", Some(fresh))),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let lead2 = body["token"].as_str().unwrap().to_string();

    // Super admin can download a backup that is a valid SQLite database.
    let (st, bytes) = send_raw(&app, "GET", "/api/admin/maintenance/backup", Some(&lead2), None).await;
    assert_eq!(st, StatusCode::OK);
    assert!(bytes.starts_with(b"SQLite format 3\0"));

    // Disabling an account ends its sessions immediately.
    let accounts = state.db.list_admin_accounts().unwrap();
    let auditor_id = &accounts.iter().find(|a| a.username == "auditor").unwrap().id;
    let (st, _) = send_raw(
        &app,
        "PUT",
        &format!("/api/admin/admins/{auditor_id}"),
        Some(&lead2),
        Some(json!({"role": "viewer", "disabled": true})),
    )
    .await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/admin/users", Some(&auditor), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);

    // Account logout only ends sessions for that administrator.
    let (st, _) = send_raw(&app, "POST", "/api/admin/logout", Some(&lead2), None).await;
    assert_eq!(st, StatusCode::OK);
    let (st, _) = send_raw(&app, "GET", "/api/admin/session", Some(&lead2), None).await;
    assert_eq!(st, StatusCode::UNAUTHORIZED);
    let (st, _) = send_raw(&app, "GET", "/api/admin/session", Some(&owner), None).await;
    assert_eq!(st, StatusCode::OK);

    let (_, audit): (_, Vec<serde_json::Value>) =
        send_json(&app, "GET", "/api/admin/audit", Some(&owner), None).await;
    assert!(audit.iter().any(|e| e["actor"] == "ops-lead" && e["action"] == "maintenance.backup"));
    assert!(audit.iter().any(|e| e["action"] == "admin.login_failed" && e["target"] == "ops-lead"));
}

#[tokio::test]
async fn error_messages_follow_accept_language() {
    let (app, _state, _tmp) = spawn_test_server().await;
    let login = |lang: Option<&'static str>| {
        let app = app.clone();
        async move {
            let mut builder = Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header(header::CONTENT_TYPE, "application/json");
            if let Some(lang) = lang {
                builder = builder.header(header::ACCEPT_LANGUAGE, lang);
            }
            let body = serde_json::json!({ "username": "nobody", "password": "wrong-password" });
            let resp = app
                .oneshot(builder.body(Body::from(serde_json::to_vec(&body).unwrap())).unwrap())
                .await
                .unwrap();
            let status = resp.status();
            let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20).await.unwrap();
            (status, String::from_utf8(bytes.to_vec()).unwrap())
        }
    };
    // Older clients send no header and keep the Chinese messages they always showed.
    assert_eq!(login(None).await, (StatusCode::UNAUTHORIZED, "用户名或密码错误".to_string()));
    assert_eq!(
        login(Some("en-US,en;q=0.9")).await,
        (StatusCode::UNAUTHORIZED, "Incorrect username or password".to_string())
    );
    assert_eq!(login(Some("zh-CN")).await.1, "用户名或密码错误");
    // Unsupported languages fall back to English.
    assert_eq!(login(Some("fr-FR")).await.1, "Incorrect username or password");

    let page = |lang: &'static str| {
        let app = app.clone();
        async move {
            let req = Request::builder()
                .uri("/api/oauth/google/callback?error=access_denied")
                .header(header::ACCEPT_LANGUAGE, lang)
                .body(Body::empty())
                .unwrap();
            let resp = app.oneshot(req).await.unwrap();
            let bytes = axum::body::to_bytes(resp.into_body(), 1 << 20).await.unwrap();
            String::from_utf8(bytes.to_vec()).unwrap()
        }
    };
    let en = page("en").await;
    assert!(en.contains(r#"<html lang="en">"#) && en.contains("Authorization was canceled or failed"));
    let zh = page("zh-CN").await;
    assert!(zh.contains(r#"<html lang="zh-CN">"#) && zh.contains("授权已取消或失败"));
}
