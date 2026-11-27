//! Enforcement of administrator policies (feature switches, quotas, per-user
//! restrictions) on user-facing endpoints. Handlers call these helpers so the
//! rules live in one place instead of being scattered through `routes.rs`.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use axum::http::StatusCode;
use chrono::{DateTime, Duration, Utc};
use protocol::{DevicePlatform, StorageBackendConfig, StorageBackendKind};

use crate::db::StorageBackendRecord;
use crate::settings::{RuntimeSettings, StoragePolicy};
use crate::state::AppState;

pub type PolicyError = (StatusCode, String);

fn forbidden(msg: impl Into<String>) -> PolicyError {
    (StatusCode::FORBIDDEN, msg.into())
}

fn internal(err: impl std::fmt::Display) -> PolicyError {
    tracing::error!("policy lookup failed: {err}");
    (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
}

pub fn backend_kind_label(kind: StorageBackendKind) -> &'static str {
    match kind {
        StorageBackendKind::Local => t!("服务器本地存储", "server local storage"),
        StorageBackendKind::GoogleDrive => "Google Drive",
        StorageBackendKind::Quark => t!("夸克网盘", "Quark Drive"),
        StorageBackendKind::BaiduNetdisk => t!("百度网盘", "Baidu Netdisk"),
        StorageBackendKind::WebDav => "WebDAV",
        StorageBackendKind::S3 => t!("S3 兼容存储", "S3-compatible storage"),
    }
}

// ---- Accounts ----------------------------------------------------------------

/// Usernames are shown in admin tables and share pages; refuse markup-significant
/// and control characters so they can never be mistaken for code.
pub fn validate_username(username: &str) -> Result<(), PolicyError> {
    let len = username.chars().count();
    if len < 2 {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("用户名至少 2 个字符，密码至少 6 位", "Usernames need at least 2 characters and passwords at least 6").to_string(),
        ));
    }
    if len > 64 {
        return Err((StatusCode::BAD_REQUEST, t!("用户名最长 64 个字符", "Usernames can be at most 64 characters").to_string()));
    }
    if username
        .chars()
        .any(|c| c.is_control() || matches!(c, '<' | '>' | '"' | '\'' | '`' | '&' | '\\' | '/'))
    {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("用户名不能包含 < > \" ' ` & \\ / 或控制字符", "Usernames can't contain < > \" ' ` & \\ / or control characters").to_string(),
        ));
    }
    Ok(())
}

// ---- Devices & drawer items --------------------------------------------------

/// Refuse clients older than the administrator's minimum version (426 Upgrade Required).
pub fn ensure_client_version(state: &AppState, app_version: Option<&str>) -> Result<(), PolicyError> {
    let settings = state.runtime_settings();
    let Some(min) = settings.client_policy.min_version.as_deref() else {
        return Ok(());
    };
    if crate::settings::version_below(app_version, min) {
        return Err((
            StatusCode::UPGRADE_REQUIRED,
            tf!("客户端版本过低（当前 {}，服务器要求 {min} 或更新），请更新 DropDrawer 后再登录", "This client version is too old (current {}, the server requires {min} or later). Update DropDrawer and sign in again",
                app_version.unwrap_or(t!("未知", "unknown"))
            ),
        ));
    }
    Ok(())
}

/// Effective switches and announcement for `user_id`'s clients.
pub fn client_config(state: &AppState, user_id: &str) -> Result<protocol::ClientConfig, PolicyError> {
    let settings = state.runtime_settings();
    let user = state.db.user_policy(user_id).map_err(internal)?;
    let f = &settings.features;
    Ok(protocol::ClientConfig {
        server_version: env!("CARGO_PKG_VERSION").to_string(),
        features: protocol::ClientFeatures {
            browser_share_enabled: true,
            share_create_enabled: f.share_create_enabled && !user.share_blocked,
            cloud_upload_enabled: f.cloud_upload_enabled && !user.upload_blocked,
            share_requires_passcode: settings.share_policy.require_passcode,
            max_share_expires_hours: settings.share_policy.max_expires_hours,
            max_share_downloads: settings.share_policy.max_downloads_cap,
            max_item_ttl_hours: settings.limits.max_item_ttl_hours,
            disabled_storage_kinds: settings.storage_policy.disabled_backend_kinds.clone(),
        },
        announcement: settings.client_announcement(),
        min_client_version: settings.client_policy.min_version.clone(),
    })
}

pub fn ensure_device_slot(
    state: &AppState,
    user_id: &str,
    requested_id: Option<&str>,
    platform: DevicePlatform,
    iroh_node_id: Option<&str>,
) -> Result<(), PolicyError> {
    let Some(limit) = state.runtime_settings().limits.max_devices_per_user else {
        return Ok(());
    };
    let is_new = state
        .db
        .device_would_be_new(requested_id, user_id, platform, iroh_node_id)
        .map_err(internal)?;
    if is_new && state.db.count_devices(user_id).map_err(internal)? >= limit {
        return Err(forbidden(tf!("已达到每个账号最多 {limit} 台设备的上限，请先在其他设备上退出或联系管理员移除旧设备", "This account has reached the limit of {limit} devices. Sign out on another device or ask an administrator to remove an old one"
        )));
    }
    Ok(())
}

pub fn ensure_item_slot(state: &AppState, user_id: &str) -> Result<(), PolicyError> {
    let Some(limit) = state.runtime_settings().limits.max_items_per_user else {
        return Ok(());
    };
    if state.db.count_drawer_items(user_id).map_err(internal)? >= limit {
        return Err(forbidden(tf!("抽屉已达到 {limit} 项的上限，请先清理旧条目", "The drawer has reached its limit of {limit} items. Remove some old items first"
        )));
    }
    Ok(())
}

pub fn item_expiry(state: &AppState, requested_hours: Option<u64>, now: DateTime<Utc>) -> DateTime<Utc> {
    let hours = state.runtime_settings().limits.item_ttl_hours(requested_hours);
    now + Duration::hours(hours.min(i64::MAX as u64 / 3600) as i64)
}

// ---- Uploads & storage backends ---------------------------------------------

pub fn ensure_backend_kind_allowed(
    policy: &StoragePolicy,
    kind: StorageBackendKind,
) -> Result<(), PolicyError> {
    if policy.kind_allowed(kind) {
        Ok(())
    } else {
        Err(forbidden(tf!("管理员已停用「{}」类型的存储", "The administrator has disabled “{}” storage",
            backend_kind_label(kind)
        )))
    }
}

/// Cloud/server uploads (not P2P) for `user_id` into `backend`.
pub fn ensure_upload_allowed(
    state: &AppState,
    user_id: &str,
    backend: &StorageBackendRecord,
) -> Result<(), PolicyError> {
    let settings = state.runtime_settings();
    if !settings.features.cloud_upload_enabled {
        return Err(forbidden(
            t!("管理员已关闭云端中转上传，请使用设备间 P2P 直传", "The administrator has turned off cloud relay uploads. Send files device-to-device over P2P"),
        ));
    }
    if state.db.user_policy(user_id).map_err(internal)?.upload_blocked {
        return Err(forbidden(t!("你的账号已被管理员限制上传到云端", "An administrator has blocked cloud uploads for your account")));
    }
    ensure_backend_kind_allowed(&settings.storage_policy, backend.config.kind())
}

/// Server-local quota for `user_id`: the admin ceiling (per-user override, else
/// server default) caps whatever the user configured on the backend itself.
pub fn effective_local_quota(state: &AppState, user_id: &str, backend_max: Option<u64>) -> Option<u64> {
    let admin_cap = state
        .db
        .user_policy(user_id)
        .ok()
        .and_then(|p| p.local_quota_bytes)
        .or_else(|| state.default_user_local_quota_bytes());
    match (backend_max, admin_cap) {
        (Some(own), Some(cap)) => Some(own.min(cap)),
        (own, cap) => own.or(cap),
    }
}

/// Endpoints the server itself will contact for this backend.
fn backend_endpoints(config: &StorageBackendConfig) -> Vec<&str> {
    match config {
        StorageBackendConfig::Local { .. } => Vec::new(),
        StorageBackendConfig::GoogleDrive {
            api_base_url,
            token_url,
            ..
        } => api_base_url
            .iter()
            .chain(token_url.iter())
            .map(String::as_str)
            .collect(),
        StorageBackendConfig::Quark { api_base_url, .. }
        | StorageBackendConfig::BaiduNetdisk { api_base_url, .. } => {
            api_base_url.iter().map(String::as_str).collect()
        }
        StorageBackendConfig::WebDav { base_url, .. } => vec![base_url.as_str()],
        StorageBackendConfig::S3 { endpoint, .. } => vec![endpoint.as_str()],
    }
}

/// With `block_private_endpoints` on, refuse backends whose endpoints resolve to
/// loopback / private / link-local addresses (SSRF into the server's network).
pub async fn ensure_endpoints_allowed(
    settings: &RuntimeSettings,
    config: &StorageBackendConfig,
) -> anyhow::Result<()> {
    if !settings.storage_policy.block_private_endpoints {
        return Ok(());
    }
    for raw in backend_endpoints(config) {
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        let url = url::Url::parse(raw).map_err(|_| anyhow::anyhow!("{}", tf!("存储地址无效：{raw}", "Invalid storage URL: {raw}")))?;
        let host = url
            .host()
            .ok_or_else(|| anyhow::anyhow!("{}", tf!("存储地址缺少主机名：{raw}", "The storage URL has no host name: {raw}")))?;
        let port = url.port_or_known_default().unwrap_or(443);
        let addrs: Vec<IpAddr> = match host {
            url::Host::Ipv4(ip) => vec![IpAddr::V4(ip)],
            url::Host::Ipv6(ip) => vec![IpAddr::V6(ip)],
            url::Host::Domain(name) => {
                if name.eq_ignore_ascii_case("localhost") || name.ends_with(".localhost") {
                    vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]
                } else {
                    tokio::net::lookup_host((name, port))
                        .await
                        .map(|it| it.map(|sa| sa.ip()).collect())
                        .unwrap_or_default()
                }
            }
        };
        if let Some(ip) = addrs.into_iter().find(|ip| is_restricted_ip(*ip)) {
            anyhow::bail!(
                "{}", tf!("存储地址 {} 指向内网或本机地址（{ip}），已被管理员的安全策略禁止", "The storage URL {} points to a private or local address ({ip}), which the administrator's security policy blocks",
                url.host_str().unwrap_or(raw)
            ));
        }
    }
    Ok(())
}

fn is_restricted_v4(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_unspecified()
        || ip.is_broadcast()
        || a == 0
        || (a == 100 && (64..128).contains(&b)) // carrier-grade NAT
}

fn is_restricted_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_restricted_v4(v4);
    }
    let first = ip.segments()[0];
    ip.is_loopback()
        || ip.is_unspecified()
        || (first & 0xfe00) == 0xfc00 // unique local
        || (first & 0xffc0) == 0xfe80 // link local
}

pub fn is_restricted_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_restricted_v4(v4),
        IpAddr::V6(v6) => is_restricted_v6(v6),
    }
}

// ---- Public share links ------------------------------------------------------

pub struct ShareTerms {
    pub expires_hours: Option<u64>,
    pub max_downloads: Option<u64>,
}

/// Validate a new share request and clamp its lifetime / download count to the admin caps.
pub fn share_terms(
    state: &AppState,
    user_id: &str,
    passcode: Option<&str>,
    expires_hours: Option<u64>,
    max_downloads: Option<u64>,
) -> Result<ShareTerms, PolicyError> {
    let settings = state.runtime_settings();
    if !settings.features.share_create_enabled {
        return Err(forbidden(t!("管理员已关闭公网外链分享", "The administrator has turned off public share links")));
    }
    if state.db.user_policy(user_id).map_err(internal)?.share_blocked {
        return Err(forbidden(t!("你的账号已被管理员限制创建外链", "An administrator has blocked share links for your account")));
    }
    let policy = &settings.share_policy;
    if policy.require_passcode && passcode.map(str::trim).is_none_or(str::is_empty) {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("服务器要求外链必须设置提取码", "This server requires a passcode for share links").to_string(),
        ));
    }
    let clamp = |requested: Option<u64>, cap: Option<u64>| match (requested.filter(|&v| v > 0), cap) {
        (Some(v), Some(cap)) => Some(v.min(cap)),
        (None, Some(cap)) => Some(cap),
        (v, None) => v,
    };
    Ok(ShareTerms {
        expires_hours: clamp(expires_hours, policy.max_expires_hours),
        max_downloads: clamp(max_downloads, policy.max_downloads_cap),
    })
}

/// Public access to a share owned by `owner_id`.
pub fn ensure_share_access(state: &AppState, owner_id: &str) -> Result<(), PolicyError> {
    if !state.runtime_settings().features.share_access_enabled {
        return Err(forbidden(t!("该服务器已暂停公网外链访问", "Public share links are paused on this server")));
    }
    match state.db.user_auth_state(owner_id).map_err(internal)? {
        Some(owner) if !owner.disabled => Ok(()),
        _ => Err(forbidden(t!("分享者的账号已停用，外链不可用", "The owner's account is disabled, so this link is unavailable"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usernames_reject_markup_characters() {
        assert!(validate_username("alice_vip").is_ok());
        assert!(validate_username("someone@example.com (abc)").is_ok());
        assert!(validate_username("张三").is_ok());
        assert!(validate_username("x").is_err());
        assert!(validate_username("x');alert(1);//").is_err());
        assert!(validate_username("<img>").is_err());
        assert!(validate_username("tab\there").is_err());
    }

    #[test]
    fn restricted_ips_cover_internal_ranges() {
        for ip in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "::1",
            "fd00::1",
            "fe80::1",
            "::ffff:127.0.0.1",
        ] {
            assert!(is_restricted_ip(ip.parse().unwrap()), "{ip} should be restricted");
        }
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700::1111"] {
            assert!(!is_restricted_ip(ip.parse().unwrap()), "{ip} should be allowed");
        }
    }

    #[tokio::test]
    async fn endpoint_check_only_applies_when_enabled() {
        let webdav = StorageBackendConfig::WebDav {
            base_url: "http://127.0.0.1:8080/dav".into(),
            username: String::new(),
            password: String::new(),
        };
        let mut settings = RuntimeSettings::default();
        assert!(ensure_endpoints_allowed(&settings, &webdav).await.is_ok());
        settings.storage_policy.block_private_endpoints = true;
        assert!(ensure_endpoints_allowed(&settings, &webdav).await.is_err());
        let public = StorageBackendConfig::WebDav {
            base_url: "https://1.1.1.1/dav".into(),
            username: String::new(),
            password: String::new(),
        };
        assert!(ensure_endpoints_allowed(&settings, &public).await.is_ok());
    }
}
