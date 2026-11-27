//! Runtime settings and feature switches (hot-applied, persisted in SQLite).

use std::sync::Arc;

use axum::{Json, extract::State, http::StatusCode};
use serde::Deserialize;

use super::{AdminSession, ApiResult, audit, internal_err};
use crate::mailer::build_test_email;
use crate::settings::{
    AdminTurnstileSettings, GoogleProviderSettings, RuntimeSettings, SanitizedRuntimeSettings,
    SmtpSettings, UpdateSettingsRequest, UpdateSmtpInput, is_valid_email, normalize_domain_list,
};
use crate::state::AppState;

pub(super) async fn get_settings(
    _admin: AdminSession,
    State(state): State<Arc<AppState>>,
) -> Json<SanitizedRuntimeSettings> {
    Json(state.runtime_settings().to_sanitized())
}

fn bad_request(msg: impl Into<String>) -> (StatusCode, String) {
    (StatusCode::BAD_REQUEST, msg.into())
}

fn smtp_from_input(input: UpdateSmtpInput, enabled: bool, keep_password: &str) -> SmtpSettings {
    SmtpSettings {
        enabled,
        host: input.host.trim().to_owned(),
        port: input.port,
        security: input.security,
        username: input.username.trim().to_owned(),
        password: input
            .password
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| keep_password.to_owned()),
        from_address: input.from_address.trim().to_owned(),
        from_name: match input.from_name.trim() {
            "" => "DropDrawer".to_string(),
            name => name.to_owned(),
        },
    }
}

/// Apply an update request on top of the current settings. Secrets left blank are kept.
fn merge_settings(
    current: &RuntimeSettings,
    req: UpdateSettingsRequest,
) -> Result<RuntimeSettings, (StatusCode, String)> {
    let mut next = current.clone();
    next.registration_mode = req.registration_mode;
    next.password_login_enabled = req.password_login_enabled;
    next.email_verification_required = req.email_verification_required;
    next.email_allowed_domains = normalize_domain_list(&req.email_allowed_domains);
    next.email_blocked_domains = normalize_domain_list(&req.email_blocked_domains);
    next.local_max_file_bytes = req.local_max_file_bytes;
    next.default_user_local_quota_bytes = req.default_user_local_quota_bytes;

    let google_secret = req
        .google
        .client_secret
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| current.google.client_secret.clone());
    next.google = GoogleProviderSettings {
        enabled: req.google.enabled,
        admin_enabled: req
            .google
            .admin_enabled
            .unwrap_or(current.google.admin_enabled),
        client_id: req.google.client_id.trim().to_owned(),
        client_secret: google_secret,
        redirect_uri: req.google.redirect_uri.trim().to_owned(),
    };
    if let Some(input) = req.admin_turnstile {
        next.admin_turnstile = AdminTurnstileSettings {
            enabled: input.enabled,
            site_key: input.site_key.trim().to_owned(),
            secret_key: input
                .secret_key
                .map(|secret| secret.trim().to_owned())
                .filter(|secret| !secret.is_empty())
                .unwrap_or_else(|| current.admin_turnstile.secret_key.clone()),
            hostname: input.hostname.trim().to_ascii_lowercase(),
        };
    }
    let smtp_enabled = req.smtp.enabled;
    next.smtp = smtp_from_input(req.smtp, smtp_enabled, &current.smtp.password);

    if let Some(features) = req.features {
        next.features = features;
    }
    if let Some(share_policy) = req.share_policy {
        next.share_policy = share_policy;
    }
    if let Some(storage_policy) = req.storage_policy {
        next.storage_policy = storage_policy;
    }
    if let Some(limits) = req.limits {
        next.limits = limits;
    }
    if let Some(client_policy) = req.client_policy {
        next.client_policy = client_policy;
    }
    if let Some(announcement) = req.announcement {
        next.announcement = announcement;
    }
    next.normalize();
    // The server owns the timestamp: it identifies the banner revision for clients.
    next.announcement.updated_at = if next.announcement.same_content(&current.announcement) {
        current.announcement.updated_at
    } else {
        Some(chrono::Utc::now())
    };
    Ok(next)
}

fn validate(state: &AppState, next: &RuntimeSettings) -> Result<(), (StatusCode, String)> {
    if next.google.enabled || next.google.admin_enabled {
        next.google
            .to_google_config()
            .map_err(|e| bad_request(tf!("Google 配置无效: {e}", "Invalid Google settings: {e}")))?;
    }
    super::turnstile::validate_settings(&next.admin_turnstile)?;
    next.smtp
        .validate()
        .map_err(|e| bad_request(e.to_string()))?;
    if next.email_verification_required
        && !next.smtp.is_usable()
        && !state.has_custom_email_sender()
    {
        return Err(bad_request(
            t!("启用「注册必须验证邮箱」前，请先启用并填写完整的 SMTP 发信配置", "Turn on and complete the SMTP settings before requiring email verification for sign-ups"),
        ));
    }
    if !next.password_login_enabled && !next.google.enabled {
        return Err(bad_request(
            t!("至少保留一种登录方式（账号密码登录或 Google 登录）", "Keep at least one sign-in method (password or Google)"),
        ));
    }
    if let Some(min) = next.client_policy.min_version.as_deref()
        && crate::settings::parse_version(min).is_none()
    {
        return Err(bad_request(t!("最低客户端版本格式应为 1.2.3", "The minimum client version must look like 1.2.3")));
    }
    if next.announcement.enabled
        && next.announcement.title.is_empty()
        && next.announcement.message.is_empty()
    {
        return Err(bad_request(t!("启用公告前请填写标题或内容", "Enter a title or message before turning on the announcement")));
    }
    if let (Some(default), Some(max)) = (
        next.limits.default_item_ttl_hours,
        next.limits.max_item_ttl_hours,
    ) && default > max
    {
        return Err(bad_request(t!("条目默认保留时长不能超过最长保留时长", "The default item retention can't exceed the maximum retention")));
    }
    Ok(())
}

/// Top-level setting sections that differ, for the audit log.
fn changed_sections(before: &SanitizedRuntimeSettings, after: &SanitizedRuntimeSettings) -> String {
    let (Ok(serde_json::Value::Object(a)), Ok(serde_json::Value::Object(b))) =
        (serde_json::to_value(before), serde_json::to_value(after))
    else {
        return String::new();
    };
    b.iter()
        .filter(|(k, v)| a.get(*k) != Some(*v))
        .map(|(k, _)| k.as_str())
        .collect::<Vec<_>>()
        .join(",")
}

pub(super) async fn update_settings(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateSettingsRequest>,
) -> ApiResult<Json<SanitizedRuntimeSettings>> {
    let _guard = state.settings_update.lock().await;
    let current = state.runtime_settings();
    let next = merge_settings(&current, req)?;
    validate(&state, &next)?;

    if next.google.admin_enabled != current.google.admin_enabled
        || next.google.client_id != current.google.client_id
        || next.google.client_secret != current.google.client_secret
        || next.google.redirect_uri != current.google.redirect_uri
        || next.admin_turnstile != current.admin_turnstile
    {
        admin.require_super()?;
    }
    let google_secret_changed = next.google.client_secret != current.google.client_secret;
    let smtp_password_changed = next.smtp.password != current.smtp.password;
    state
        .apply_and_persist_settings(next.clone())
        .map_err(internal_err)?;

    let before = current.to_sanitized();
    let after = next.to_sanitized();
    let mut changed = changed_sections(&before, &after);
    for (flag, name) in [
        (google_secret_changed, "google.client_secret"),
        (smtp_password_changed, "smtp.password"),
        (
            next.admin_turnstile.secret_key != current.admin_turnstile.secret_key,
            "admin_turnstile.secret_key",
        ),
    ] {
        if flag {
            if !changed.is_empty() {
                changed.push(',');
            }
            changed.push_str(name);
        }
    }
    if !changed.is_empty() {
        audit(&state, &admin, "settings.update", None, Some(&changed));
        // Let connected clients pick up new switches / announcements right away.
        state.broadcast_all(protocol::WsEvent::ConfigChanged);
    }
    Ok(Json(after))
}

#[derive(Debug, Deserialize)]
pub(super) struct TestSmtpRequest {
    to: String,
    #[serde(default)]
    smtp: Option<UpdateSmtpInput>,
}

pub(super) async fn test_smtp(
    admin: AdminSession,
    State(state): State<Arc<AppState>>,
    Json(req): Json<TestSmtpRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let to = req.to.trim();
    if !is_valid_email(to) {
        return Err(bad_request(t!("收件人邮箱格式无效", "Invalid recipient email address")));
    }
    let current = state.runtime_settings().smtp;
    let smtp = match req.smtp {
        Some(input) => smtp_from_input(input, true, &current.password),
        None => current,
    };
    let email = build_test_email(to);
    state
        .send_email_with_config(&smtp, &email)
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, e.to_string()))?;
    audit(&state, &admin, "smtp.test", Some(to), None);
    Ok(Json(serde_json::json!({ "ok": true, "to": to })))
}
