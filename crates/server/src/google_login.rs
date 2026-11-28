use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    Json,
    extract::{Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header, jwk::JwkSet};
use protocol::AuthResponse;
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

use crate::{auth::issue_user_token, state::AppState};

const CALLBACK_PATH: &str = "/api/auth/google/callback";
pub(crate) const LIFETIME: Duration = Duration::from_secs(300);
pub(crate) const MAX_ATTEMPTS: usize = 1024;
/// A sign-in failure. The message is a stable English key; [`IntoResponse`]
/// and the browser page translate it for the request language.
#[derive(Debug, Clone, Copy)]
pub(crate) struct LoginError(StatusCode, &'static str);

impl IntoResponse for LoginError {
    fn into_response(self) -> Response {
        (self.0, localized_message(self.1)).into_response()
    }
}
const UNAVAILABLE: LoginError = LoginError(
    StatusCode::SERVICE_UNAVAILABLE,
    "Google sign-in is disabled on this server",
);
const EXPIRED: LoginError = LoginError(
    StatusCode::NOT_FOUND,
    "Google sign-in session is invalid or expired",
);
const FAILED: LoginError = LoginError(
    StatusCode::BAD_GATEWAY,
    "Google authorization could not be verified. Try signing in again.",
);
const DENIED: LoginError = LoginError(
    StatusCode::BAD_REQUEST,
    "Google authorization was cancelled or denied",
);
const REGISTRATION_CLOSED: LoginError = LoginError(
    StatusCode::FORBIDDEN,
    "New account registration is disabled on this server",
);
const INVITE_REQUIRED: LoginError = LoginError(
    StatusCode::FORBIDDEN,
    "An invitation code is required to sign up",
);
const INVITE_INVALID: LoginError = LoginError(
    StatusCode::FORBIDDEN,
    "The invitation code is invalid, used up or expired",
);
const GOOGLE_SIGNUP_DISABLED: LoginError = LoginError(
    StatusCode::FORBIDDEN,
    "New Google sign-ups are disabled on this server",
);
const EMAIL_DOMAIN_REJECTED: LoginError = LoginError(
    StatusCode::FORBIDDEN,
    "This Google email domain is not allowed to sign up",
);
const INTERNAL: LoginError = LoginError(
    StatusCode::INTERNAL_SERVER_ERROR,
    "Could not create a DropDrawer session",
);

pub struct GoogleLoginConfig {
    client_id: String,
    client_secret: String,
    redirect_uri: Url,
}

impl GoogleLoginConfig {
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub fn client_secret(&self) -> &str {
        &self.client_secret
    }

    pub fn redirect_uri(&self) -> &str {
        self.redirect_uri.as_str()
    }

    pub fn from_parts(
        client_id: &str,
        client_secret: &str,
        redirect: &str,
    ) -> anyhow::Result<Self> {
        let client_id = client_id.trim().to_owned();
        let client_secret = client_secret.trim().to_owned();
        let redirect = redirect.trim();
        anyhow::ensure!(
            !client_id.is_empty() && !client_secret.is_empty() && !redirect.is_empty(),
            "Google sign-in requires client_id, client_secret and redirect_uri"
        );
        let redirect_uri = Url::parse(redirect)
            .map_err(|_| anyhow::anyhow!("Invalid Google sign-in redirect URI"))?;
        let loopback = matches!(
            redirect_uri.host_str(),
            Some("localhost" | "127.0.0.1" | "[::1]")
        );
        anyhow::ensure!(
            (redirect_uri.scheme() == "https" || (redirect_uri.scheme() == "http" && loopback))
                && redirect_uri.host_str().is_some()
                && redirect_uri.path() == CALLBACK_PATH
                && redirect_uri.username().is_empty()
                && redirect_uri.password().is_none()
                && redirect_uri.query().is_none()
                && redirect_uri.fragment().is_none(),
            "Google sign-in redirect URI must be an HTTPS URL ending in {CALLBACK_PATH} (HTTP is allowed for loopback)"
        );
        Ok(Self {
            client_id,
            client_secret,
            redirect_uri,
        })
    }

    pub fn from_settings(get: impl Fn(&str) -> Option<String>) -> anyhow::Result<Option<Self>> {
        let read = |key| get(key).unwrap_or_default().trim().to_owned();
        let client_id = read("DROPDRAWER_GOOGLE_CLIENT_ID");
        let client_secret = read("DROPDRAWER_GOOGLE_CLIENT_SECRET");
        let redirect = read("DROPDRAWER_GOOGLE_REDIRECT_URI");
        if client_id.is_empty() && client_secret.is_empty() && redirect.is_empty() {
            return Ok(None);
        }
        Self::from_parts(&client_id, &client_secret, &redirect).map(Some)
    }
}

pub(crate) struct GoogleLogin {
    pub(crate) config: GoogleLoginConfig,
    pub(crate) admin_attempts: Mutex<HashMap<Uuid, crate::admin::google::AdminAttempt>>,
    attempts: Mutex<HashMap<Uuid, Attempt>>,
}

struct Attempt {
    poll_key: String,
    started: Instant,
    proof: Option<Proof>,
    invite_code: Option<String>,
    result: Option<Result<AuthResponse, LoginError>>,
}

pub(crate) struct Proof {
    verifier: String,
    nonce: String,
}

impl Proof {
    pub(crate) fn new() -> Self {
        Self { verifier: random_secret(), nonce: random_secret() }
    }

    pub(crate) fn authorization_url(&self, config: &GoogleLoginConfig, flow_id: Uuid) -> Url {
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(self.verifier.as_bytes()));
        let mut url = Url::parse("https://accounts.google.com/o/oauth2/v2/auth")
            .expect("Google authorization URL");
        url.query_pairs_mut().extend_pairs([
            ("client_id", config.client_id.as_str()),
            ("redirect_uri", config.redirect_uri.as_str()),
            ("response_type", "code"),
            ("scope", "openid email"),
            ("state", &flow_id.to_string()),
            ("nonce", &self.nonce),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("prompt", "select_account"),
        ]);
        url
    }
}

impl GoogleLogin {
    pub(crate) fn new(config: GoogleLoginConfig) -> Self {
        Self {
            config,
            admin_attempts: Mutex::new(HashMap::new()),
            attempts: Mutex::new(HashMap::new()),
        }
    }
}

#[derive(Serialize)]
pub(crate) struct StartResponse {
    authorization_url: String,
    state: Uuid,
    poll_key: String,
    expires_in: u64,
}

#[derive(Deserialize)]
pub(crate) struct PollRequest {
    state: Uuid,
    poll_key: String,
}

#[derive(Deserialize)]
pub(crate) struct CallbackQuery {
    state: Option<Uuid>,
    code: Option<String>,
    error: Option<String>,
}

/// Public privacy notice (the URL given to Google's OAuth consent screen). Both
/// languages stay on one page so the URL works for every reviewer; the
/// visitor's language comes first.
pub(crate) async fn privacy_notice() -> impl axum::response::IntoResponse {
    let en = crate::i18n::is_en();
    let html = include_str!("google_privacy.html")
        .replace("__LANG__", crate::i18n::current().html_tag())
        .replace("__TITLE__", if en { "Privacy Notice · DropDrawer" } else { "隐私说明 · DropDrawer" })
        .replace("__ORDER__", if en { "en-first" } else { "zh-first" });
    (
        [(axum::http::header::VARY, "Accept-Language")],
        axum::response::Html(html),
    )
}

#[derive(Deserialize, Default)]
pub(crate) struct StartRequest {
    #[serde(default)]
    invite_code: Option<String>,
}

pub(crate) async fn start(
    State(state): State<Arc<AppState>>,
    crate::admin::ClientIp(ip): crate::admin::ClientIp,
    body: axum::body::Bytes,
) -> Result<Response, LoginError> {
    if !state.runtime_settings().google.enabled {
        return Err(UNAVAILABLE);
    }
    // Per-IP budget, so one client can't fill the shared pool of pending flows.
    if state.google_starts_by_ip.is_blocked(&ip) {
        return Err(LoginError(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many Google sign-in attempts. Try again shortly.",
        ));
    }
    state.google_starts_by_ip.record_failure(&ip);
    let req = if body.is_empty() {
        StartRequest::default()
    } else {
        serde_json::from_slice::<StartRequest>(&body).unwrap_or_default()
    };
    let invite_code = req
        .invite_code
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned);

    let google = state.google_login().ok_or(UNAVAILABLE)?;
    let proof = Proof::new();
    let flow_id = Uuid::new_v4();
    let poll_key = random_secret();
    let authorization_url = proof.authorization_url(&google.config, flow_id);
    let mut attempts = google.attempts.lock().await;
    attempts.retain(|_, attempt| attempt.started.elapsed() < LIFETIME);
    if attempts.len() >= MAX_ATTEMPTS {
        return Err(LoginError(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many Google sign-in attempts. Try again shortly.",
        ));
    }
    attempts.insert(
        flow_id,
        Attempt {
            poll_key: poll_key.clone(),
            started: Instant::now(),
            proof: Some(proof),
            invite_code,
            result: None,
        },
    );
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(StartResponse {
            authorization_url: authorization_url.into(),
            state: flow_id,
            poll_key,
            expires_in: LIFETIME.as_secs(),
        }),
    )
        .into_response())
}

pub(crate) async fn poll(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PollRequest>,
) -> Result<Response, LoginError> {
    if !state.runtime_settings().google.enabled {
        return Err(UNAVAILABLE);
    }
    let google = state.google_login().ok_or(UNAVAILABLE)?;
    let mut attempts = google.attempts.lock().await;
    let attempt = attempts
        .get(&req.state)
        .filter(|attempt| attempt.started.elapsed() < LIFETIME && attempt.poll_key == req.poll_key)
        .ok_or(EXPIRED)?;
    let response = if attempt.result.is_some() {
        let result = attempts
            .remove(&req.state)
            .and_then(|attempt| attempt.result)
            .ok_or(EXPIRED)?;
        Some(result?)
    } else {
        None
    };
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(response)).into_response())
}

pub(crate) async fn callback(
    State(state): State<Arc<AppState>>,
    Query(query): Query<CallbackQuery>,
    headers: HeaderMap,
    crate::admin::ClientIp(ip): crate::admin::ClientIp,
) -> Response {
    let Some(google) = state.google_login() else {
        return browser_page(Err(UNAVAILABLE));
    };
    let Some(flow_id) = query.state else {
        return browser_page(Err(EXPIRED));
    };
    let code = query.code.as_deref().filter(|_| query.error.is_none());
    if let Some(response) = crate::admin::google::callback(&state, &google, &headers, &ip, flow_id, code).await {
        return response;
    }
    if !state.runtime_settings().google.enabled {
        return browser_page(Err(UNAVAILABLE));
    }
    let taken = google
        .attempts
        .lock()
        .await
        .get_mut(&flow_id)
        .filter(|attempt| attempt.started.elapsed() < LIFETIME)
        .and_then(|attempt| {
            let proof = attempt.proof.take()?;
            Some((proof, attempt.invite_code.clone()))
        });
    let Some((proof, invite_code)) = taken else {
        return browser_page(Err(EXPIRED));
    };
    let result = match query.code.as_deref() {
        Some(code) if query.error.is_none() => {
            complete(&state, &google.config, code, &proof, invite_code.as_deref()).await
        }
        _ => Err(DENIED),
    };
    let mut attempts = google.attempts.lock().await;
    let Some(attempt) = attempts
        .get_mut(&flow_id)
        .filter(|attempt| attempt.started.elapsed() < LIFETIME)
    else {
        return browser_page(Err(EXPIRED));
    };
    let browser_result = result.as_ref().map(|_| ()).map_err(|&error| error);
    attempt.result = Some(result);
    browser_page(browser_result)
}

#[derive(Deserialize)]
struct GoogleToken {
    id_token: String,
}

#[derive(Deserialize)]
pub(crate) struct GoogleClaims {
    pub(crate) sub: String,
    nonce: String,
    pub(crate) email: String,
    pub(crate) hd: Option<String>,
    email_verified: bool,
    azp: Option<String>,
}

async fn complete(
    state: &AppState,
    config: &GoogleLoginConfig,
    code: &str,
    proof: &Proof,
    invite_code: Option<&str>,
) -> Result<AuthResponse, LoginError> {
    use crate::db::{GoogleResolveError, GoogleSignupPolicy};
    use crate::settings::RegistrationMode;

    let identity = verify_google_identity(&state.http, config, code, proof)
        .await
        .map_err(|_| FAILED)?;
    let settings = state.runtime_settings();
    let signup_policy = if !settings.features.google_signup_enabled
        || settings.check_email_domain(&identity.email).is_err()
    {
        GoogleSignupPolicy::Closed
    } else {
        match settings.registration_mode {
            RegistrationMode::Open => GoogleSignupPolicy::Open,
            RegistrationMode::InviteOnly => GoogleSignupPolicy::InviteOnly(invite_code),
            RegistrationMode::Closed => GoogleSignupPolicy::Closed,
        }
    };
    let user = match state
        .db
        .resolve_google_user_with_policy(&identity.sub, &identity.email, signup_policy)
        .map_err(|_| INTERNAL)?
    {
        Ok(user) => user,
        Err(GoogleResolveError::InviteRequired) => return Err(INVITE_REQUIRED),
        Err(GoogleResolveError::InviteInvalid) => return Err(INVITE_INVALID),
        Err(GoogleResolveError::RegistrationClosed) => {
            if settings.registration_mode == RegistrationMode::Closed {
                return Err(REGISTRATION_CLOSED);
            } else if !settings.features.google_signup_enabled {
                return Err(GOOGLE_SIGNUP_DISABLED);
            } else {
                return Err(EMAIL_DOMAIN_REJECTED);
            }
        }
    };
    if state
        .db
        .is_user_disabled_or_missing(&user.id)
        .unwrap_or(true)
    {
        return Err(LoginError(
            StatusCode::FORBIDDEN,
            "Your DropDrawer account has been disabled by an administrator",
        ));
    }
    let token = issue_user_token(state, &user.id, &user.username).map_err(|_| INTERNAL)?;
    let _ = state.db.touch_last_login(&user.id);
    Ok(AuthResponse { token, user })
}

pub(crate) async fn verify_google_identity(
    http: &reqwest::Client,
    config: &GoogleLoginConfig,
    code: &str,
    proof: &Proof,
) -> anyhow::Result<GoogleClaims> {
    let token: GoogleToken = http
        .post("https://oauth2.googleapis.com/token")
        .timeout(Duration::from_secs(10))
        .form(&[
            ("code", code),
            ("client_id", config.client_id.as_str()),
            ("client_secret", config.client_secret.as_str()),
            ("redirect_uri", config.redirect_uri.as_str()),
            ("grant_type", "authorization_code"),
            ("code_verifier", proof.verifier.as_str()),
        ])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let token_header = decode_header(&token.id_token)?;
    let keys: JwkSet = http
        .get("https://www.googleapis.com/oauth2/v3/certs")
        .timeout(Duration::from_secs(10))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let key = token_header
        .kid
        .as_deref()
        .and_then(|kid| keys.find(kid))
        .ok_or_else(|| anyhow::anyhow!("Unknown Google signing key"))?;
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&[&config.client_id]);
    validation.set_issuer(&["https://accounts.google.com", "accounts.google.com"]);
    validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
    let claims =
        decode::<GoogleClaims>(&token.id_token, &DecodingKey::from_jwk(key)?, &validation)?.claims;
    anyhow::ensure!(
        claims.nonce == proof.nonce
            && claims.email_verified
            && !claims.email.is_empty()
            && !claims.sub.is_empty()
            && claims
                .azp
                .as_ref()
                .is_none_or(|azp| azp == &config.client_id),
        "Invalid Google identity claims"
    );
    Ok(claims)
}

pub(crate) fn random_secret() -> String {
    let mut bytes = [0; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The text for a [`LoginError`] key in the request language.
fn localized_message(message: &'static str) -> &'static str {
    match message {
        "Google sign-in is disabled on this server" => t!("当前服务器尚未启用 Google 登录。", "Google sign-in isn't enabled on this server."),
        "Google sign-in session is invalid or expired" => t!("登录会话无效或已过期，请返回 DropDrawer 重新发起登录。", "The sign-in session is invalid or expired. Return to DropDrawer and sign in again."),
        "Google authorization could not be verified. Try signing in again." => t!("无法验证 Google 授权信息，请返回 DropDrawer 重试。", "Google authorization couldn't be verified. Return to DropDrawer and try again."),
        "Google authorization was cancelled or denied" => t!("你已取消或拒绝了 Google 授权。", "You canceled or denied Google authorization."),
        "New account registration is disabled on this server" => t!("当前服务器已关闭新用户注册，仅允许已有账号登录。", "This server doesn't accept new accounts. Only existing accounts can sign in."),
        "Your DropDrawer account has been disabled by an administrator" => t!("该账号已被管理员禁用，请联系服务器管理员。", "An administrator has disabled this account. Contact the server administrator."),
        "Too many Google sign-in attempts. Try again shortly." => t!("Google 登录尝试过于频繁，请稍后再试。", "Too many Google sign-in attempts. Try again shortly."),
        "Could not create a DropDrawer session" => t!("创建登录会话失败，请稍后重试。", "Couldn't create a DropDrawer session. Try again later."),
        "An invitation code is required to sign up" => t!("当前服务器仅支持邀请码注册，请切换到注册页填写邀请码后再使用 Google 注册", "This server only accepts sign-ups with an invitation code. Switch to Create account, enter the code, then sign up with Google"),
        "The invitation code is invalid, used up or expired" => t!("邀请码无效、已用完或已过期，请核对后重试", "The invitation code is invalid, used up or expired. Check it and try again"),
        "New Google sign-ups are disabled on this server" => t!("当前服务器已关闭 Google 新用户注册，仅允许已有账号登录", "This server doesn't accept new Google sign-ups. Only existing accounts can sign in"),
        "This Google email domain is not allowed to sign up" => t!("该 Google 邮箱域名不在当前服务器允许注册范围内", "This Google email domain isn't allowed to sign up on this server"),
        _ => message,
    }
}

/// Renders a self-contained, CSP-safe OAuth result page shared by Google Sign-In
/// and Google Drive callbacks. All interpolated strings are server-authored literals.
pub(crate) fn render_oauth_result_page(
    status: StatusCode,
    ok: bool,
    title: &'static str,
    detail: &'static str,
    hint: &'static str,
) -> Response {
    let tone = if ok { "ok" } else { "err" };
    let badge_svg = if ok {
        r#"<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5 9.8 17.3 19 7.8"/></svg>"#
    } else {
        r#"<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 8v5.2M12 16.6h.01"/></svg>"#
    };
    let lang = crate::i18n::current().html_tag();
    let html = format!(
        r#"<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<title>{title} · DropDrawer</title>
<style>
:root{{color-scheme:light dark;--bg:#f4f6fa;--card:#ffffff;--line:rgba(15,23,42,.09);--text:#0f172a;--muted:#475569;--faint:#64748b;--accent:#0284c7;--glow:rgba(14,165,233,.12);--ok:#059669;--ok-bg:rgba(5,150,105,.1);--ok-line:rgba(5,150,105,.26);--err:#dc2626;--err-bg:rgba(220,38,38,.09);--err-line:rgba(220,38,38,.24);--shadow:0 22px 54px rgba(15,23,42,.1),0 2px 8px rgba(15,23,42,.04)}}
@media(prefers-color-scheme:dark){{:root{{--bg:#07090e;--card:#10141e;--line:rgba(255,255,255,.11);--text:#f4f6fa;--muted:#a2a9b8;--faint:#6e7588;--accent:#38bdf8;--glow:rgba(56,189,248,.13);--ok:#34d399;--ok-bg:rgba(52,211,153,.14);--ok-line:rgba(52,211,153,.32);--err:#f87171;--err-bg:rgba(248,113,113,.13);--err-line:rgba(248,113,113,.32);--shadow:0 26px 64px rgba(0,0,0,.55)}}}}
*{{box-sizing:border-box}}
body{{margin:0;min-height:100dvh;display:grid;place-items:center;padding:24px 16px;background:radial-gradient(880px 460px at 50% -10%,var(--glow),transparent 65%),var(--bg);color:var(--text);font:400 14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","SF Pro Text","Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}}
.card{{position:relative;width:100%;max-width:416px;padding:34px 30px 26px;border-radius:22px;background:var(--card);border:1px solid var(--line);box-shadow:var(--shadow);text-align:center}}
.card::before{{content:"";position:absolute;inset:-1px 28px auto 28px;height:1px;background:linear-gradient(90deg,transparent,var(--accent),transparent);opacity:.6}}
.brand{{display:inline-flex;align-items:center;gap:7px;padding:4px 11px;border-radius:999px;border:1px solid var(--line);font-size:12px;font-weight:600;color:var(--muted);margin-bottom:22px}}
.brand img{{width:18px;height:18px;display:block}}
.badge{{width:58px;height:58px;margin:0 auto 18px;border-radius:18px;display:grid;place-items:center}}
.badge svg{{width:28px;height:28px;fill:none;stroke:currentColor;stroke-width:2.3;stroke-linecap:round;stroke-linejoin:round}}
.ok .badge{{background:var(--ok-bg);border:1px solid var(--ok-line);color:var(--ok)}}
.err .badge{{background:var(--err-bg);border:1px solid var(--err-line);color:var(--err)}}
h1{{margin:0 0 8px;font-size:20px;font-weight:660;letter-spacing:-.02em}}
p.detail{{margin:0;color:var(--muted);font-size:14px;line-height:1.65}}
.foot{{margin-top:24px;padding-top:16px;border-top:1px solid var(--line);font-size:12px;color:var(--faint)}}
</style>
</head>
<body>
<main class="card {tone}">
  <div class="brand"><img src="/admin/assets/logo.svg" alt="">DropDrawer</div>
  <div class="badge">{badge_svg}</div>
  <h1>{title}</h1>
  <p class="detail">{detail}</p>
  <div class="foot">{hint}</div>
</main>
</body>
</html>"#
    );
    (
        status,
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::REFERRER_POLICY, "no-referrer"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
            (
                header::CONTENT_SECURITY_POLICY,
                "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            ),
        ],
        Html(html),
    )
        .into_response()
}

fn browser_page(result: Result<(), LoginError>) -> Response {
    match result {
        Ok(()) => render_oauth_result_page(
            StatusCode::OK,
            true,
            t!("Google 登录已完成", "Google sign-in complete"),
            t!("授权成功，请返回 DropDrawer 客户端继续使用。", "You're signed in. Return to DropDrawer to continue."),
            t!("此标签页可安全关闭", "You can close this tab"),
        ),
        Err(LoginError(status, message)) => render_oauth_result_page(
            status,
            false,
            t!("无法完成 Google 登录", "Couldn't finish Google sign-in"),
            localized_message(message),
            t!("你可以关闭此页面，返回 DropDrawer 重新尝试或更换登录方式", "You can close this page and return to DropDrawer to try again or use another sign-in method"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        Router,
        body::{Body, to_bytes},
        http::Request,
    };
    use serde_json::{Value, json};
    use tower::ServiceExt;

    fn test_state() -> Arc<AppState> {
        let config = GoogleLoginConfig::from_settings(|key| match key {
            "DROPDRAWER_GOOGLE_CLIENT_ID" => Some("test-client".into()),
            "DROPDRAWER_GOOGLE_CLIENT_SECRET" => Some("test-secret".into()),
            "DROPDRAWER_GOOGLE_REDIRECT_URI" => Some(format!("https://example.com{CALLBACK_PATH}")),
            _ => None,
        })
        .unwrap();
        AppState::with_google_login(
            crate::db::Database::open(":memory:").unwrap(),
            "dropdrawer-test-key".into(),
            std::path::PathBuf::new(),
            config,
            None,
        )
    }

    async fn send(router: &Router, method: &str, uri: &str, body: Value) -> Response {
        router
            .clone()
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(uri)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
    }

    async fn response_json(response: Response) -> Value {
        serde_json::from_slice(&to_bytes(response.into_body(), 4096).await.unwrap()).unwrap()
    }

    #[tokio::test]
    async fn only_the_initiating_app_can_claim_the_session_once() {
        let state = test_state();
        let router = crate::routes::build_router(state.clone());
        let response = send(&router, "POST", "/api/auth/google/start", Value::Null).await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
        let start = response_json(response).await;
        let authorization_url = Url::parse(start["authorization_url"].as_str().unwrap()).unwrap();
        let params: HashMap<_, _> = authorization_url.query_pairs().collect();
        assert_eq!(params["scope"], "openid email");
        assert_eq!(params["code_challenge_method"], "S256");
        assert!(
            !authorization_url
                .as_str()
                .contains(start["poll_key"].as_str().unwrap())
        );

        let correct_poll = json!({"state": start["state"], "poll_key": start["poll_key"]});
        let wrong_poll = json!({"state": start["state"], "poll_key": "another-app"});
        let pending = send(
            &router,
            "POST",
            "/api/auth/google/poll",
            correct_poll.clone(),
        )
        .await;
        assert_eq!(response_json(pending).await, Value::Null);

        // Supply a completed authorization without contacting Google's services.
        let flow_id = Uuid::parse_str(start["state"].as_str().unwrap()).unwrap();
        let google = state.google_login().unwrap();
        let mut attempts = google.attempts.lock().await;
        let attempt = attempts.get_mut(&flow_id).unwrap();
        let proof = attempt.proof.take().unwrap();
        assert_eq!(params["nonce"], proof.nonce);
        assert_eq!(
            params["code_challenge"],
            URL_SAFE_NO_PAD.encode(Sha256::digest(proof.verifier))
        );
        let user = state
            .db
            .resolve_google_user("test-subject", "google@example.com", true)
            .unwrap()
            .unwrap();
        let token = crate::auth::create_jwt(&user.id, &user.username, &state.jwt_secret).unwrap();
        attempt.result = Some(Ok(AuthResponse { token, user }));
        drop(attempts);

        let wrong = send(&router, "POST", "/api/auth/google/poll", wrong_poll).await;
        assert_eq!(wrong.status(), StatusCode::NOT_FOUND);
        let claimed = send(
            &router,
            "POST",
            "/api/auth/google/poll",
            correct_poll.clone(),
        )
        .await;
        assert_eq!(claimed.status(), StatusCode::OK);
        let session = response_json(claimed).await;
        assert_eq!(session["user"]["username"], "google@example.com");
        assert!(
            crate::auth::decode_jwt(session["token"].as_str().unwrap(), &state.jwt_secret).is_ok()
        );
        let replay = send(&router, "POST", "/api/auth/google/poll", correct_poll).await;
        assert_eq!(replay.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn denied_callback_completes_the_attempt_and_cannot_be_replayed() {
        let router = crate::routes::build_router(test_state());
        let start =
            response_json(send(&router, "POST", "/api/auth/google/start", Value::Null).await).await;
        let callback_uri = format!(
            "{CALLBACK_PATH}?state={}&error=access_denied",
            start["state"].as_str().unwrap()
        );
        let denied = send(&router, "GET", &callback_uri, Value::Null).await;
        assert_eq!(denied.status(), StatusCode::BAD_REQUEST);
        assert_eq!(denied.headers()[header::REFERRER_POLICY], "no-referrer");
        let replay = send(&router, "GET", &callback_uri, Value::Null).await;
        assert_eq!(replay.status(), StatusCode::NOT_FOUND);
        let poll = json!({"state": start["state"], "poll_key": start["poll_key"]});
        assert_eq!(
            send(&router, "POST", "/api/auth/google/poll", poll)
                .await
                .status(),
            StatusCode::BAD_REQUEST
        );
    }

    #[test]
    fn google_subject_is_stable_and_does_not_claim_password_accounts() {
        let state = test_state();
        let db = &state.db;
        let local = db
            .create_user("local-id", "shared@example.com", "password-hash")
            .unwrap();
        let google = db
            .resolve_google_user("first-subject", &local.username, true)
            .unwrap()
            .unwrap();
        assert_ne!(local.id, google.id);
        assert_ne!(local.username, google.username);
        assert_eq!(
            db.find_user_by_username(&local.username)
                .unwrap()
                .unwrap()
                .id,
            local.id
        );
        assert_eq!(
            db.resolve_google_user("first-subject", "new@example.com", false)
                .unwrap()
                .unwrap()
                .id,
            google.id
        );
        assert!(
            db.resolve_google_user("second-subject", &local.username, false)
                .unwrap()
                .is_none()
        );
        let second = db
            .resolve_google_user("second-subject", &local.username, true)
            .unwrap()
            .unwrap();
        assert_ne!(second.id, google.id);
        assert!(!crate::auth::verify_password(
            "",
            &db.find_user_by_username(&google.username)
                .unwrap()
                .unwrap()
                .password_hash
        ));
    }

    #[test]
    fn google_invite_only_signup_consumes_invite_and_lets_existing_users_sign_in() {
        use crate::db::{GoogleResolveError, GoogleSignupPolicy};

        let state = test_state();
        let db = &state.db;
        db.create_invite_code("INVITE01", Some("test"), 1, None).unwrap();

        // Missing invite code returns InviteRequired instead of RegistrationClosed.
        assert_eq!(
            db.resolve_google_user_with_policy(
                "sub-1",
                "newuser@example.com",
                GoogleSignupPolicy::InviteOnly(None),
            )
            .unwrap()
            .unwrap_err(),
            GoogleResolveError::InviteRequired
        );

        // Wrong invite code returns InviteInvalid.
        assert_eq!(
            db.resolve_google_user_with_policy(
                "sub-1",
                "newuser@example.com",
                GoogleSignupPolicy::InviteOnly(Some("WRONG")),
            )
            .unwrap()
            .unwrap_err(),
            GoogleResolveError::InviteInvalid
        );

        // Valid invite code creates user and atomically consumes 1 use.
        let created = db
            .resolve_google_user_with_policy(
                "sub-1",
                "newuser@example.com",
                GoogleSignupPolicy::InviteOnly(Some("invite01")),
            )
            .unwrap()
            .unwrap();
        assert_eq!(created.email.as_deref(), Some("newuser@example.com"));

        // Existing Google user logs back in without needing an invite code.
        let existing = db
            .resolve_google_user_with_policy(
                "sub-1",
                "newuser@example.com",
                GoogleSignupPolicy::InviteOnly(None),
            )
            .unwrap()
            .unwrap();
        assert_eq!(existing.id, created.id);

        // Second brand-new user reusing the single-use invite fails with InviteInvalid.
        assert_eq!(
            db.resolve_google_user_with_policy(
                "sub-2",
                "other@example.com",
                GoogleSignupPolicy::InviteOnly(Some("INVITE01")),
            )
            .unwrap()
            .unwrap_err(),
            GoogleResolveError::InviteInvalid
        );
    }
}
