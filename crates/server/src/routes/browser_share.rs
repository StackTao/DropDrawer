use std::{
    collections::HashMap,
    net::IpAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use protocol::{DrawerItemKind, WsEvent};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, oneshot};
use uuid::Uuid;

use super::{internal_err, lookup_public_share, validate_share_access};
use crate::{admin::ClientIp, db::DrawerItemRow, policy, state::AppState};

type Error = (StatusCode, String);
const MAX_SDP: usize = 48 * 1024;
const OFFER_TIMEOUT: Duration = Duration::from_secs(8);
const SESSION_TIMEOUT: Duration = Duration::from_secs(30);
const FALLBACK_WINDOW: Duration = Duration::from_secs(30 * 60);
const MAX_PENDING_SESSIONS: usize = 1024;
const MAX_CLAIMED_SESSIONS: usize = 4096;

struct Session {
    source: (String, String),
    /// Address of the visitor that made the offer.
    client: String,
    code: String,
    item_id: String,
    start_token: Option<String>,
    expires: Instant,
    answer: Option<oneshot::Sender<Option<String>>>,
    answered: bool,
    claimed: bool,
}

#[derive(Default)]
pub(crate) struct Sessions(Mutex<HashMap<String, Session>>);

impl Sessions {
    async fn insert(&self, id: String, session: Session) -> bool {
        let mut sessions = self.0.lock().await;
        let now = Instant::now();
        sessions.retain(|_, entry| entry.expires > now);
        // Claimed sessions only wait for a possible HTTP fallback; they get a
        // pool of their own so they can't crowd out new offers.
        let pending = sessions.values().filter(|s| !s.claimed).count();
        if pending >= MAX_PENDING_SESSIONS
            || sessions.len() >= MAX_PENDING_SESSIONS + MAX_CLAIMED_SESSIONS
            || sessions
                .values()
                .filter(|s| !s.claimed && s.source == session.source)
                .count()
                >= 3
            // The page downloads one file at a time, so one visitor never
            // needs more than a couple of a device's three pending slots.
            || sessions
                .values()
                .filter(|s| !s.claimed && s.source == session.source && s.client == session.client)
                .count()
                >= 2
        {
            return false;
        }
        sessions.insert(id, session);
        true
    }

    pub(crate) async fn answer(&self, id: &str, source: &(String, String), sdp: Option<String>) {
        let mut sessions = self.0.lock().await;
        let Some(session) = sessions
            .get_mut(id)
            .filter(|s| &s.source == source && s.expires > Instant::now())
        else {
            return;
        };
        if let Some(mechanism) = session.answer.take() {
            let sdp = sdp.filter(|s| lan_answer(s));
            session.answered = sdp.is_some();
            let _ = mechanism.send(sdp);
        }
    }

    pub(super) async fn can_fallback(&self, id: &str, code: &str, item: &str) -> bool {
        self.0
            .lock()
            .await
            .get(id)
            .is_some_and(|s| fallback_matches(s, code, item))
    }

    pub(super) async fn take_fallback(&self, id: &str, code: &str, item: &str) -> bool {
        let mut sessions = self.0.lock().await;
        if sessions
            .get(id)
            .is_some_and(|s| fallback_matches(s, code, item))
        {
            sessions.remove(id);
            true
        } else {
            false
        }
    }
}

fn fallback_matches(s: &Session, code: &str, item: &str) -> bool {
    s.claimed && s.code == code && s.item_id == item && s.expires > Instant::now()
}

#[derive(Deserialize)]
pub(super) struct Offer {
    item_id: String,
    passcode: Option<String>,
    sdp: String,
}

#[derive(Serialize)]
pub(super) struct Answer {
    session: String,
    sdp: String,
}

fn source_device(state: &AppState, item: &DrawerItemRow) -> Option<String> {
    let owner = (item.user_id.clone(), item.owner_device_id.clone());
    if state.browser_share_devices.contains(&owner) && state.is_device_online(&owner.0, &owner.1) {
        return Some(owner.1);
    }
    let hash = item.blake3_hash.as_ref()?;
    state.ready_files.iter().find_map(|entry| {
        let source = entry.key();
        (source.0 == item.user_id
            && state.browser_share_devices.contains(source)
            && entry.value().get(&item.id) == Some(hash)
            && state.is_device_online(&source.0, &source.1))
        .then(|| source.1.clone())
    })
}

/// The source uses ICE Lite. Discard remote candidates so it only learns
/// the browser's address from authenticated inbound ICE checks.
fn data_offer(sdp: &str) -> Option<String> {
    if sdp.len() > MAX_SDP || sdp.contains('\0') {
        return None;
    }
    let mut media = sdp.lines().filter(|line| line.starts_with("m="));
    if !media.next().is_some_and(|line| {
        let mut fields = line.split_ascii_whitespace();
        fields.next() == Some("m=application")
            && fields.next().is_some()
            && fields.next() == Some("UDP/DTLS/SCTP")
            && fields.next() == Some("webrtc-datachannel")
            && fields.next().is_none()
    }) || media.next().is_some()
    {
        return None;
    }
    let mut offer = String::with_capacity(sdp.len());
    for line in sdp.lines().filter(|line| {
        !line.starts_with("a=candidate:")
            && !line.starts_with("a=remote-candidates:")
            && *line != "a=end-of-candidates"
    }) {
        offer.push_str(line);
        offer.push_str("\r\n");
    }
    Some(offer)
}

fn lan_answer(sdp: &str) -> bool {
    // webrtc-rs 0.14 serializes the flag with a value of the same name.
    if sdp.len() > MAX_SDP
        || !sdp
            .lines()
            .any(|line| matches!(line, "a=ice-lite" | "a=ice-lite:ice-lite"))
    {
        return false;
    }
    let mut candidates = 0;
    for line in sdp.lines().filter(|line| line.starts_with("a=candidate:")) {
        candidates += 1;
        let mut fields = line.split_ascii_whitespace().skip(2);
        let udp = fields.next().is_some_and(|v| v.eq_ignore_ascii_case("udp"));
        let ip = fields.nth(1).and_then(|v| v.parse::<IpAddr>().ok());
        let port = fields.next().and_then(|v| v.parse::<u16>().ok());
        let host = fields.next() == Some("typ") && fields.next() == Some("host");
        let private = match ip {
            Some(IpAddr::V4(ip)) => ip.is_private() || ip.is_link_local(),
            Some(IpAddr::V6(ip)) => ip.is_unique_local() || ip.is_unicast_link_local(),
            None => false,
        };
        if !udp || !host || !private || !port.is_some_and(|v| v != 0) {
            return false;
        }
    }
    candidates > 0
}

fn unavailable() -> Error {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        t!(
            "暂时无法连接发送端，请保持 DropDrawer 在线后重试",
            "The sender is unavailable. Keep DropDrawer online and try again"
        )
        .to_string(),
    )
}

pub(super) async fn offer(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Path(code): Path<String>,
    Json(request): Json<Offer>,
) -> Result<Json<Answer>, Error> {
    // Each source device takes only a few pending offers, so one visitor
    // repeating offers must not keep them all.
    if state.browser_share_offers_by_ip.is_blocked(&ip) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("连接请求过于频繁，请稍后再试", "Too many connection attempts. Try again later").to_owned(),
        ));
    }
    state.browser_share_offers_by_ip.record_failure(&ip);
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;
    validate_share_access(&state, &share, request.passcode.as_deref(), true).await?;
    let item = state
        .db
        .get_share_link_items(&code, &share.item_id)
        .map_err(internal_err)?
        .into_iter()
        .find(|item| item.id == request.item_id && item.kind == DrawerItemKind::File)
        .ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                t!("文件不在此分享中", "The file isn't part of this share").to_owned(),
            )
        })?;
    let sdp = data_offer(&request.sdp).ok_or_else(|| {
        (
            StatusCode::BAD_REQUEST,
            t!("无效的连接请求", "Invalid connection offer").to_owned(),
        )
    })?;
    let device = source_device(&state, &item).ok_or_else(unavailable)?;
    let id = Uuid::new_v4().to_string();
    let start_token = Uuid::new_v4().to_string();
    let (tx, rx) = oneshot::channel();
    let session = Session {
        source: (share.user_id.clone(), device.clone()),
        client: ip.clone(),
        code,
        item_id: item.id.clone(),
        start_token: Some(start_token.clone()),
        expires: Instant::now() + SESSION_TIMEOUT,
        answer: Some(tx),
        answered: false,
        claimed: false,
    };
    if !state.browser_shares.insert(id.clone(), session).await {
        return Err(unavailable());
    }
    let sent = state.send_to_device(
        &share.user_id,
        &device,
        WsEvent::BrowserShareOffer {
            session_id: id.clone(),
            item_id: item.id,
            size: item.size,
            blake3_hash: item.blake3_hash,
            sdp,
            start_token,
        },
    );
    if sent && let Ok(Ok(Some(sdp))) = tokio::time::timeout(OFFER_TIMEOUT, rx).await {
        return Ok(Json(Answer { session: id, sdp }));
    }
    state.browser_shares.0.lock().await.remove(&id);
    Err(unavailable())
}

#[derive(Deserialize)]
pub(super) struct Claim {
    item_id: String,
    passcode: Option<String>,
}

#[derive(Serialize)]
pub(super) struct Grant {
    start_token: String,
}

pub(super) async fn claim(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Path((code, id)): Path<(String, String)>,
    Json(request): Json<Claim>,
) -> Result<Json<Grant>, Error> {
    let share = lookup_public_share(&state, &ip, &code)?;
    policy::ensure_share_access(&state, &share.user_id)?;
    validate_share_access(&state, &share, request.passcode.as_deref(), true).await?;
    if !state
        .db
        .get_share_link_items(&code, &share.item_id)
        .map_err(internal_err)?
        .iter()
        .any(|item| item.id == request.item_id && item.kind == DrawerItemKind::File)
    {
        return Err((
            StatusCode::NOT_FOUND,
            t!("文件不在此分享中", "The file isn't part of this share").to_owned(),
        ));
    }
    let mut sessions = state.browser_shares.0.lock().await;
    let session = sessions
        .get_mut(&id)
        .filter(|s| {
            s.answered
                && !s.claimed
                && s.code == code
                && s.item_id == request.item_id
                && s.expires > Instant::now()
        })
        .ok_or_else(unavailable)?;
    if !state.is_device_online(&session.source.0, &session.source.1) {
        return Err(unavailable());
    }
    // The database treats the download limit atomically across HTTP and live shares.
    if !state
        .db
        .increment_share_download(&code)
        .map_err(internal_err)?
    {
        return Err((
            StatusCode::GONE,
            t!(
                "该分享链接已达到下载次数上限",
                "This share link has reached its download limit"
            )
            .to_owned(),
        ));
    }
    session.claimed = true;
    session.expires = Instant::now() + FALLBACK_WINDOW;
    let start_token = session.start_token.take().ok_or_else(unavailable)?;
    Ok(Json(Grant { start_token }))
}
