//! The per-device WebSocket: authentication, presence and drawer events.

use super::*;

#[derive(Debug, Deserialize)]
pub(super) struct WsQuery {
    /// Accepted for older clients; current clients send `Authorization: Bearer`
    /// so the token does not end up in proxy access logs.
    #[serde(default)]
    token: Option<String>,
    device_id: String,
}

const WS_MAX_MESSAGE: usize = 4 * 1024 * 1024;

pub(super) async fn ws_upgrade(
    ws: WebSocketUpgrade,
    Query(query): Query<WsQuery>,
    headers: axum::http::HeaderMap,
    State(state): State<Arc<AppState>>,
) -> Result<Response, (StatusCode, String)> {
    let header_token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim);
    let token = header_token
        .or(query.token.as_deref())
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, "missing ws token".to_string()))?;
    let claims = decode_jwt(token, &state.jwt_secret)
        .map_err(|_| (StatusCode::UNAUTHORIZED, "invalid ws token".to_string()))?;

    validate_user_claims(&state, &claims)?;

    if state
        .db
        .get_device(&query.device_id, &claims.sub)
        .map_err(internal_err)?
        .is_none()
    {
        return Err((StatusCode::NOT_FOUND, t!("设备尚未注册，请重新登录", "This device isn't registered. Sign in again").to_string()));
    }

    // Client commands are small JSON (the largest is the ready-file list); the
    // 64 MiB default would let one connection make the server buffer a lot.
    Ok(ws
        .max_message_size(WS_MAX_MESSAGE)
        .max_frame_size(WS_MAX_MESSAGE)
        .on_upgrade(move |socket| handle_ws(socket, state, claims, query.device_id)))
}

pub(super) async fn handle_ws(socket: WebSocket, state: Arc<AppState>, claims: Claims, device_id: String) {
    const PING_INTERVAL: StdDuration = StdDuration::from_secs(20);
    const READ_TIMEOUT: StdDuration = StdDuration::from_secs(60);
    let (mut ws_sink, mut ws_stream) = socket.split();
    let (tx, mut rx) = mpsc::channel::<WsEvent>(crate::state::WS_QUEUE_CAPACITY);
    // Keep only a weak handle in `handle_ws`: `state.connections` holds the sole
    // strong `Sender`, so a removed connection's `rx` closes once its queue is
    // drained. `closed` ends this handler right away when the connection is
    // replaced, signed out or dropped for being stuck (queue full).
    let tx_weak = tx.downgrade();
    let connection = crate::state::WsConnection::new(tx);
    let closed = connection.closed_signal();
    let user_id = claims.sub.clone();
    let key = (user_id.clone(), device_id.clone());
    let is_current = || {
        tx_weak.upgrade().is_some_and(|tx| {
            state
                .connections
                .get(&key)
                .is_some_and(|current| current.same_channel(&tx))
        })
    };

    {
        let _presence = state.presence_changes.lock().await;
        // Credentials can change between the HTTP upgrade and this callback.
        if validate_user_claims(&state, &claims).is_err() {
            return;
        }
        state.ready_files.remove(&key);
        state.browser_share_devices.remove(&key);
        state.background_push_devices.remove(&key);
        if let Some(previous) = state.connections.insert(key.clone(), connection) {
            previous.close();
        }

        if let (Ok(devices), Ok(items)) = (
            state.list_devices_with_presence(&user_id),
            state.list_hydrated_items(&user_id),
        ) && let Some(tx) = tx_weak.upgrade()
        {
            let _ = tx.try_send(WsEvent::Snapshot { devices, items });
        }

        if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
            dev.online = true;
            state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
        }
    }

    let mut send_task = tokio::spawn(async move {
        let start = tokio::time::Instant::now() + PING_INTERVAL;
        let mut heartbeat = tokio::time::interval_at(start, PING_INTERVAL);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            let message = tokio::select! {
                event = rx.recv() => {
                    let Some(event) = event else { break };
                    let Ok(json) = serde_json::to_string(&event) else { continue };
                    Message::Text(json.into())
                }
                _ = heartbeat.tick() => Message::Ping(Default::default()),
            };
            if ws_sink.send(message).await.is_err() {
                break;
            }
        }
    });

    loop {
        let incoming = tokio::select! {
            incoming = tokio::time::timeout(READ_TIMEOUT, ws_stream.next()) => incoming,
            _ = &mut send_task => break,
            _ = state.ws_shutdown.cancelled() => break,
            _ = closed.cancelled() => break,
        };
        let Ok(Some(Ok(message))) = incoming else { break };
        if !is_current() {
            break;
        }
        match message {
            Message::Text(text) => match serde_json::from_str::<WsClientCommand>(&text) {
                Ok(WsClientCommand::Ping) => {
                    if let Some(tx) = tx_weak.upgrade() {
                        let _ = tx.try_send(WsEvent::Pong);
                    }
                }
                Ok(WsClientCommand::PushVisibility { foreground }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    if foreground {
                        state.background_push_devices.remove(&key);
                    } else {
                        state.background_push_devices.insert(key.clone());
                    }
                }
                Ok(WsClientCommand::BrowserShareReady {}) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    state.browser_share_devices.insert(key.clone());
                }
                Ok(WsClientCommand::BrowserShareAnswer { session_id, sdp }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    state.browser_shares.answer(&session_id, &key, sdp).await;
                }
                Ok(WsClientCommand::UpdateReadyFiles { files }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    let Ok(replicas) = state.db.ready_replicas(&user_id, &device_id, &files) else {
                        continue;
                    };
                    state.ready_files.insert(key.clone(), replicas);
                    if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
                        state.fill_device_presence(&mut dev);
                        state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
                    }
                }
                Ok(WsClientCommand::UpdateNodeAddr {
                    iroh_node_id,
                    iroh_relay_url,
                    direct_addrs,
                }) => {
                    let _presence = state.presence_changes.lock().await;
                    if !is_current() {
                        break;
                    }
                    if let Ok(Some(mut dev)) = state.db.update_device_node_addr(
                        &device_id,
                        &user_id,
                        &iroh_node_id,
                        iroh_relay_url.as_deref(),
                        &direct_addrs,
                    ) {
                        state.fill_device_presence(&mut dev);
                        state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
                    }
                }
                Err(_) => {}
            },
            Message::Close(_) => break,
            _ => {}
        }
    }

    send_task.abort();
    let _presence = state.presence_changes.lock().await;
    let removed_self = tx_weak.upgrade().is_some_and(|tx| {
        state
            .connections
            .remove_if(&key, |_, current| current.same_channel(&tx))
            .is_some()
    });
    if removed_self || !state.connections.contains_key(&key) {
        state.ready_files.remove(&key);
        state.browser_share_devices.remove(&key);
        state.background_push_devices.remove(&key);
        if let Ok(Some(mut dev)) = state.db.get_device(&device_id, &user_id) {
            dev.online = false;
            state.broadcast_user(&user_id, WsEvent::DeviceUpdated(dev));
        }
    }
}
