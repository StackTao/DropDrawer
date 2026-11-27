use std::{net::IpAddr, sync::Arc, time::Duration};

use axum::{
    Json,
    extract::State,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;

use super::ApiResult;
use crate::{settings::AdminTurnstileSettings, state::AppState};

const VERIFY_URL: &str = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const ACTION: &str = "admin_login";

pub(super) fn validate_settings(config: &AdminTurnstileSettings) -> ApiResult<()> {
    if config.enabled
        && (config.site_key.is_empty()
            || config.secret_key.is_empty()
            || config.hostname.is_empty()
            || !config
                .hostname
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')))
    {
        return Err((
            StatusCode::BAD_REQUEST,
            t!("请填写 Turnstile 站点密钥、服务端密钥和主机名", "Enter the Turnstile site key, secret key and host names").to_owned(),
        ));
    }
    Ok(())
}

pub(super) async fn public_config(State(state): State<Arc<AppState>>) -> Response {
    if !state.admin_enabled {
        return StatusCode::NOT_FOUND.into_response();
    }
    let settings = state.runtime_settings();
    let site_key = settings
        .admin_turnstile
        .enabled
        .then_some(settings.admin_turnstile.site_key);
    (
        [(header::CACHE_CONTROL, "no-store")],
        Json(serde_json::json!({
            "google_enabled": settings.google.admin_enabled,
            "turnstile_site_key": site_key,
        })),
    )
        .into_response()
}

#[derive(Deserialize)]
struct Verification {
    success: bool,
    hostname: Option<String>,
    action: Option<String>,
}

impl Verification {
    fn valid_for(&self, hostname: &str) -> bool {
        self.success
            && self
                .hostname
                .as_deref()
                .is_some_and(|host| host.eq_ignore_ascii_case(hostname))
            && self.action.as_deref() == Some(ACTION)
    }
}

pub(super) async fn verify(state: &AppState, ip: &str, token: Option<&str>) -> ApiResult<()> {
    let config = state.runtime_settings().admin_turnstile;
    if !config.enabled {
        return Ok(());
    }
    let rejected = || {
        (
            StatusCode::BAD_REQUEST,
            t!("请完成 Cloudflare 人机验证后重试", "Complete the Cloudflare check and try again").to_owned(),
        )
    };
    let token = token
        .filter(|token| !token.is_empty() && token.len() <= 2048)
        .ok_or_else(rejected)?;
    if state.admin_challenges.is_blocked(ip) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("人机验证请求过多，请稍后再试", "Too many human verification requests. Try again later").to_owned(),
        ));
    }
    state.admin_challenges.record_failure(ip);

    let mut form = vec![("secret", config.secret_key.as_str()), ("response", token)];
    if ip.parse::<IpAddr>().is_ok() {
        form.push(("remoteip", ip));
    }
    let unavailable = |_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            t!("暂时无法验证 Cloudflare 人机验证，请稍后重试", "Cloudflare human verification is unavailable right now. Try again later").to_owned(),
        )
    };
    let result: Verification = state
        .http
        .post(VERIFY_URL)
        .timeout(Duration::from_secs(8))
        .form(&form)
        .send()
        .await
        .map_err(unavailable)?
        .error_for_status()
        .map_err(unavailable)?
        .json()
        .await
        .map_err(unavailable)?;
    if !result.valid_for(&config.hostname) {
        return Err(rejected());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verification_requires_success_and_matching_hostname_and_action() {
        let mut result = Verification {
            success: true,
            hostname: Some("drop.example.test".into()),
            action: Some(ACTION.into()),
        };
        assert!(result.valid_for("drop.example.test"));
        assert!(!result.valid_for("other.example.test"));
        result.action = Some("other".into());
        assert!(!result.valid_for("drop.example.test"));
        result.action = Some(ACTION.into());
        result.success = false;
        assert!(!result.valid_for("drop.example.test"));
    }
}
