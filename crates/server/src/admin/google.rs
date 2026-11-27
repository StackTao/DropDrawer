use std::{sync::Arc, time::Instant};

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};
use serde::Deserialize;
use uuid::Uuid;

use super::{ApiError, ApiResult, ClientIp, auth, internal_err, turnstile};
use crate::{
    db::AdminAccount,
    google_login::{self, GoogleClaims, GoogleLogin, LIFETIME, MAX_ATTEMPTS, Proof},
    state::AppState,
};

const SECURE_FLOW_COOKIE: &str = "__Host-dd_admin_google_flow";
const LOOPBACK_FLOW_COOKIE: &str = "dd_admin_google_flow";

pub(crate) struct AdminAttempt {
    started: Instant,
    browser_secret: String,
    proof: Option<Proof>,
    account: Option<(String, u64)>,
}

fn disabled() -> ApiError {
    (StatusCode::NOT_FOUND, t!("管理员 Google 登录未启用", "Administrator Google sign-in is not enabled").into())
}

fn expired() -> ApiError {
    (
        StatusCode::BAD_REQUEST,
        t!("Google 登录会话已过期，请重新登录", "The Google sign-in session has expired. Sign in again").into(),
    )
}

fn enabled_provider(state: &AppState) -> ApiResult<Arc<GoogleLogin>> {
    if !state.admin_enabled || !state.runtime_settings().google.admin_enabled {
        return Err(disabled());
    }
    state.google_login().ok_or_else(disabled)
}

fn flow_cookie_name(provider: &GoogleLogin) -> &'static str {
    if provider.config.redirect_uri().starts_with("https:") {
        SECURE_FLOW_COOKIE
    } else {
        LOOPBACK_FLOW_COOKIE
    }
}

fn flow_cookie(value: &str, max_age: u64, provider: &GoogleLogin) -> String {
    let name = flow_cookie_name(provider);
    let secure = if name == SECURE_FLOW_COOKIE {
        "; Secure"
    } else {
        ""
    };
    format!("{name}={value}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{secure}")
}

fn browser_flow<'a>(headers: &'a HeaderMap, provider: &GoogleLogin) -> Option<(Uuid, &'a str)> {
    let name = flow_cookie_name(provider);
    let cookie = headers.get(header::COOKIE)?.to_str().ok()?;
    let value = cookie
        .split(';')
        .find_map(|part| part.trim().strip_prefix(name)?.strip_prefix('='))?;
    let (id, secret) = value.split_once('.')?;
    Some((id.parse().ok()?, secret))
}

#[derive(Deserialize)]
pub(super) struct StartRequest {
    turnstile_token: Option<String>,
}

pub(super) async fn start(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    Json(body): Json<StartRequest>,
) -> ApiResult<Response> {
    let provider = enabled_provider(&state)?;
    auth::check_login_limit(&state, &ip)?;
    if state.admin_google_starts.is_blocked(&ip) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("Google 登录请求过多，请稍后再试", "Too many Google sign-in requests. Try again later").into(),
        ));
    }
    state.admin_google_starts.record_failure(&ip);
    turnstile::verify(&state, &ip, body.turnstile_token.as_deref()).await?;
    let flow_id = Uuid::new_v4();
    let browser_secret = google_login::random_secret();
    let proof = Proof::new();
    let url = proof.authorization_url(&provider.config, flow_id);
    let mut attempts = provider.admin_attempts.lock().await;
    attempts.retain(|_, value| value.started.elapsed() < LIFETIME);
    if attempts.len() >= MAX_ATTEMPTS {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            t!("Google 登录请求过多，请稍后再试", "Too many Google sign-in requests. Try again later").into(),
        ));
    }
    let cookie = flow_cookie(
        &format!("{flow_id}.{browser_secret}"),
        LIFETIME.as_secs(),
        &provider,
    );
    attempts.insert(
        flow_id,
        AdminAttempt {
            started: Instant::now(),
            browser_secret,
            proof: Some(proof),
            account: None,
        },
    );
    Ok((
        [
            (header::SET_COOKIE, cookie),
            (header::CACHE_CONTROL, "no-store".into()),
        ],
        Json(serde_json::json!({"authorization_url": url.as_str()})),
    )
        .into_response())
}

fn redirect(path: &'static str) -> Response {
    (
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::REFERRER_POLICY, "no-referrer"),
        ],
        Redirect::to(path),
    )
        .into_response()
}

fn matching_account(state: &AppState, identity: &GoogleClaims) -> ApiResult<Option<AdminAccount>> {
    // Google is authoritative for Gmail and the Workspace domain in its signed
    // hosted-domain claim. Admin usernames must already be provisioned.
    let Some((_, domain)) = identity.email.rsplit_once('@') else {
        return Ok(None);
    };
    if !domain.eq_ignore_ascii_case("gmail.com")
        && !identity
            .hd
            .as_deref()
            .is_some_and(|host| host.eq_ignore_ascii_case(domain))
    {
        return Ok(None);
    }
    let Some(account) = state
        .db
        .find_admin_account(&identity.email)
        .map_err(internal_err)?
        .filter(|account| !account.disabled)
    else {
        return Ok(None);
    };
    let bound = state
        .db
        .bind_admin_google_identity(&account.id, &identity.sub)
        .map_err(internal_err)?;
    Ok(bound.then_some(account))
}

pub(crate) async fn callback(
    state: &AppState,
    provider: &Arc<GoogleLogin>,
    headers: &HeaderMap,
    ip: &str,
    flow_id: Uuid,
    code: Option<&str>,
) -> Option<Response> {
    let failure = || redirect("/admin?google=failed");
    let proof = {
        let mut attempts = provider.admin_attempts.lock().await;
        let attempt = attempts.get_mut(&flow_id)?;
        if attempt.started.elapsed() >= LIFETIME
            || browser_flow(headers, provider) != Some((flow_id, attempt.browser_secret.as_str()))
        {
            return Some(failure());
        }
        let Some(proof) = attempt.proof.take() else {
            return Some(failure());
        };
        proof
    };
    let Some(code) = code else {
        provider.admin_attempts.lock().await.remove(&flow_id);
        return Some(failure());
    };
    if auth::check_login_limit(state, ip).is_err() {
        return Some(failure());
    }

    let identity =
        google_login::verify_google_identity(&state.http, &provider.config, code, &proof).await;
    let Ok(current_provider) = enabled_provider(state) else {
        return Some(failure());
    };
    if !Arc::ptr_eq(&current_provider, provider) {
        return Some(failure());
    }
    let account = identity
        .ok()
        .and_then(|identity| matching_account(state, &identity).ok().flatten());
    let mut attempts = provider.admin_attempts.lock().await;
    let Some(attempt) = attempts
        .get_mut(&flow_id)
        .filter(|a| a.started.elapsed() < LIFETIME)
    else {
        return Some(failure());
    };
    let Some(account) = account else {
        attempts.remove(&flow_id);
        let _ = auth::fail_login(state, ip, None, t!("Google 登录失败", "Google sign-in failed"));
        return Some(failure());
    };
    if account.totp_enabled {
        attempt.account = Some((account.id, account.token_version));
        return Some(redirect("/admin?google=totp"));
    }
    attempts.remove(&flow_id);
    let Ok(token) = auth::complete_login(state, &account, ip, Some("google")) else {
        return Some(failure());
    };
    let mut response = redirect("/admin");
    // The redirect URI is a validated HTTPS origin (or local loopback for development).
    let cookie = auth::session_cookie(headers, &token);
    if let Ok(cookie) = cookie.parse() {
        response.headers_mut().append(header::SET_COOKIE, cookie);
    }
    if let Ok(cookie) = flow_cookie("", 0, provider).parse() {
        response.headers_mut().append(header::SET_COOKIE, cookie);
    }
    Some(response)
}

#[derive(Deserialize)]
pub(super) struct TotpRequest {
    code: String,
}

pub(super) async fn finish_totp(
    State(state): State<Arc<AppState>>,
    ClientIp(ip): ClientIp,
    headers: HeaderMap,
    Json(body): Json<TotpRequest>,
) -> ApiResult<Response> {
    let provider = enabled_provider(&state)?;
    auth::check_login_limit(&state, &ip)?;
    let (flow_id, secret) = browser_flow(&headers, &provider).ok_or_else(expired)?;
    let mut attempts = provider.admin_attempts.lock().await;
    let (id, version) = attempts
        .get(&flow_id)
        .filter(|a| a.started.elapsed() < LIFETIME && a.browser_secret == secret)
        .and_then(|a| a.account.as_ref())
        .ok_or_else(expired)?;
    let account = state
        .db
        .get_admin_account(id)
        .map_err(internal_err)?
        .filter(|a| !a.disabled && a.totp_enabled && a.token_version == *version)
        .ok_or_else(expired)?;
    auth::verify_totp(&state, &account, &ip, &body.code)?;
    attempts.remove(&flow_id);
    let token = auth::complete_login(&state, &account, &ip, Some("google,totp"))?;
    let mut response = auth::session_response(&headers, token);
    if let Ok(cookie) = flow_cookie("", 0, &provider).parse() {
        response.headers_mut().append(header::SET_COOKIE, cookie);
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        admin::totp,
        db::{AdminRole, Database},
        settings::RuntimeSettings,
    };
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    fn state() -> Arc<AppState> {
        let database = Database::open(":memory:").unwrap();
        database
            .create_admin_account("admin-id", "admin@gmail.com", "unused", AdminRole::Super)
            .unwrap();
        let mut settings = RuntimeSettings::default();
        settings.google.admin_enabled = true;
        settings.google.client_id = "test-id".into();
        settings.google.client_secret = "test-secret".into();
        settings.google.redirect_uri = "https://drop.example.test/api/auth/google/callback".into();
        AppState::with_full_config(
            database,
            "test-jwt-secret".into(),
            std::path::PathBuf::new(),
            settings,
            true,
        )
    }

    fn identity(subject: &str, email: &str, hosted_domain: Option<&str>) -> GoogleClaims {
        serde_json::from_value(serde_json::json!({
            "sub": subject, "email": email, "nonce": "verified",
            "email_verified": true, "hd": hosted_domain,
        }))
        .unwrap()
    }

    #[test]
    fn google_only_links_authoritative_existing_accounts_and_pins_the_subject() {
        let state = state();
        assert!(
            matching_account(&state, &identity("unknown", "other@gmail.com", None))
                .unwrap()
                .is_none()
        );
        let original = identity("real-google-subject", "ADMIN@gmail.com", None);
        assert_eq!(
            matching_account(&state, &original).unwrap().unwrap().role,
            AdminRole::Super
        );
        assert!(matching_account(&state, &original).unwrap().is_some());
        assert!(
            matching_account(&state, &identity("second-subject", "admin@gmail.com", None))
                .unwrap()
                .is_none()
        );
        state
            .db
            .create_admin_account(
                "workspace",
                "admin@example.test",
                "unused",
                AdminRole::Admin,
            )
            .unwrap();
        assert!(
            matching_account(
                &state,
                &identity("workspace-subject", "admin@example.test", None)
            )
            .unwrap()
            .is_none()
        );
        assert!(
            matching_account(
                &state,
                &identity(
                    "workspace-subject",
                    "admin@example.test",
                    Some("example.test")
                )
            )
            .unwrap()
            .is_some()
        );
        state
            .db
            .update_admin_account("admin-id", AdminRole::Super, true)
            .unwrap();
        assert!(matching_account(&state, &original).unwrap().is_none());
    }

    #[tokio::test]
    async fn google_second_factor_is_required_and_consumed_once() {
        let state = state();
        let secret = totp::generate_secret();
        state
            .db
            .set_admin_totp_pending("admin-id", &secret)
            .unwrap();
        state.db.set_admin_totp_enabled("admin-id", true).unwrap();
        let provider = enabled_provider(&state).unwrap();
        let id = Uuid::new_v4();
        provider.admin_attempts.lock().await.insert(
            id,
            AdminAttempt {
                started: Instant::now(),
                browser_secret: "same-browser".into(),
                proof: None,
                account: Some(("admin-id".into(), 0)),
            },
        );
        let app = crate::routes::build_router(state);
        let send_code = |code: &str| {
            Request::post("/api/admin/google/totp")
                .header(
                    header::COOKIE,
                    format!("{SECURE_FLOW_COOKIE}={id}.same-browser"),
                )
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(serde_json::json!({"code": code}).to_string()))
                .unwrap()
        };
        let wrong = app.clone().oneshot(send_code("invalid")).await.unwrap();
        assert_eq!(wrong.status(), StatusCode::UNAUTHORIZED);
        let step = totp::current_step(chrono::Utc::now().timestamp());
        let code = totp::code_at(&secret, step).unwrap();
        let right = app.clone().oneshot(send_code(&code)).await.unwrap();
        assert_eq!(right.status(), StatusCode::OK);
        assert!(
            right
                .headers()
                .get_all(header::SET_COOKIE)
                .iter()
                .any(|value| value.to_str().unwrap().starts_with("dd_admin_session="))
        );
        let replay = app.oneshot(send_code(&code)).await.unwrap();
        assert_eq!(replay.status(), StatusCode::BAD_REQUEST);
    }
}
