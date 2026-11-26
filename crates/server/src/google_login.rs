use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    Json,
    extract::{Query, State},
    http::{StatusCode, header},
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

use crate::{auth::create_jwt, state::AppState};

const CALLBACK_PATH: &str = "/api/auth/google/callback";
const LIFETIME: Duration = Duration::from_secs(300);
const MAX_ATTEMPTS: usize = 1024;
type LoginError = (StatusCode, &'static str);
const UNAVAILABLE: LoginError = (
    StatusCode::SERVICE_UNAVAILABLE,
    "Google sign-in is disabled on this server",
);
const EXPIRED: LoginError = (
    StatusCode::NOT_FOUND,
    "Google sign-in session is invalid or expired",
);
const FAILED: LoginError = (
    StatusCode::BAD_GATEWAY,
    "Google authorization could not be verified. Try signing in again.",
);
const DENIED: LoginError = (
    StatusCode::BAD_REQUEST,
    "Google authorization was cancelled or denied",
);
const REGISTRATION_CLOSED: LoginError = (
    StatusCode::FORBIDDEN,
    "New account registration is disabled on this server",
);
const INTERNAL: LoginError = (
    StatusCode::INTERNAL_SERVER_ERROR,
    "Could not create a DropDrawer session",
);

pub struct GoogleLoginConfig {
    client_id: String,
    client_secret: String,
    redirect_uri: Url,
}

impl GoogleLoginConfig {
    pub fn from_settings(get: impl Fn(&str) -> Option<String>) -> anyhow::Result<Option<Self>> {
        let read = |key| get(key).unwrap_or_default().trim().to_owned();
        let client_id = read("DROPDRAWER_GOOGLE_CLIENT_ID");
        let client_secret = read("DROPDRAWER_GOOGLE_CLIENT_SECRET");
        let redirect = read("DROPDRAWER_GOOGLE_REDIRECT_URI");
        if client_id.is_empty() && client_secret.is_empty() && redirect.is_empty() {
            return Ok(None);
        }
        anyhow::ensure!(
            !client_id.is_empty() && !client_secret.is_empty() && !redirect.is_empty(),
            "Google sign-in requires DROPDRAWER_GOOGLE_CLIENT_ID, DROPDRAWER_GOOGLE_CLIENT_SECRET and DROPDRAWER_GOOGLE_REDIRECT_URI"
        );
        let redirect_uri = Url::parse(&redirect)
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
        Ok(Some(Self {
            client_id,
            client_secret,
            redirect_uri,
        }))
    }
}

pub(crate) struct GoogleLogin {
    config: GoogleLoginConfig,
    attempts: Mutex<HashMap<Uuid, Attempt>>,
}

struct Attempt {
    poll_key: String,
    started: Instant,
    proof: Option<Proof>,
    result: Option<Result<AuthResponse, LoginError>>,
}

struct Proof {
    verifier: String,
    nonce: String,
}

impl GoogleLogin {
    pub(crate) fn new(config: GoogleLoginConfig) -> Self {
        Self {
            config,
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

pub(crate) async fn privacy_notice() -> &'static str {
    include_str!("google_privacy.txt")
}

pub(crate) async fn start(State(state): State<Arc<AppState>>) -> Result<Response, LoginError> {
    let google = state.google_login.as_ref().ok_or(UNAVAILABLE)?;
    let proof = Proof {
        verifier: random_secret(),
        nonce: random_secret(),
    };
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(proof.verifier.as_bytes()));
    let flow_id = Uuid::new_v4();
    let poll_key = random_secret();
    let mut authorization_url = Url::parse("https://accounts.google.com/o/oauth2/v2/auth")
        .expect("Google authorization URL");
    authorization_url.query_pairs_mut().extend_pairs([
        ("client_id", google.config.client_id.as_str()),
        ("redirect_uri", google.config.redirect_uri.as_str()),
        ("response_type", "code"),
        ("scope", "openid email"),
        ("state", &flow_id.to_string()),
        ("nonce", &proof.nonce),
        ("code_challenge", &challenge),
        ("code_challenge_method", "S256"),
        ("prompt", "select_account"),
    ]);
    let mut attempts = google.attempts.lock().await;
    attempts.retain(|_, attempt| attempt.started.elapsed() < LIFETIME);
    if attempts.len() >= MAX_ATTEMPTS {
        return Err((
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
    let google = state.google_login.as_ref().ok_or(UNAVAILABLE)?;
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
) -> Response {
    let Some(google) = state.google_login.as_ref() else {
        return browser_page(Err(UNAVAILABLE));
    };
    let Some(flow_id) = query.state else {
        return browser_page(Err(EXPIRED));
    };
    let proof = google
        .attempts
        .lock()
        .await
        .get_mut(&flow_id)
        .filter(|attempt| attempt.started.elapsed() < LIFETIME)
        .and_then(|attempt| attempt.proof.take());
    let Some(proof) = proof else {
        return browser_page(Err(EXPIRED));
    };
    let result = match query.code.as_deref() {
        Some(code) if query.error.is_none() => complete(&state, &google.config, code, &proof).await,
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
struct GoogleClaims {
    sub: String,
    nonce: String,
    email: String,
    email_verified: bool,
    azp: Option<String>,
}

async fn complete(
    state: &AppState,
    config: &GoogleLoginConfig,
    code: &str,
    proof: &Proof,
) -> Result<AuthResponse, LoginError> {
    let identity = verify_google_identity(&state.http, config, code, proof)
        .await
        .map_err(|_| FAILED)?;
    let user = state
        .db
        .resolve_google_user(&identity.sub, &identity.email, state.registration_open())
        .map_err(|_| INTERNAL)?
        .ok_or(REGISTRATION_CLOSED)?;
    let token = create_jwt(&user.id, &user.username, &state.jwt_secret).map_err(|_| INTERNAL)?;
    Ok(AuthResponse { token, user })
}

async fn verify_google_identity(
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

fn random_secret() -> String {
    let mut bytes = [0; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn browser_page(result: Result<(), LoginError>) -> Response {
    let (status, title, detail) = match result {
        Ok(()) => (
            StatusCode::OK,
            "Google authorization complete",
            "You can close this tab and return to DropDrawer.",
        ),
        Err((status, message)) => (status, "Google sign-in could not finish", message),
    };
    (
        status,
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::REFERRER_POLICY, "no-referrer"),
            (header::CONTENT_SECURITY_POLICY, "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"),
        ],
        Html(format!(r#"<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · DropDrawer</title>
<style>body{{font:16px system-ui,sans-serif;color-scheme:light dark;margin:15vh auto;padding:0 24px;max-width:36rem}}h1{{font-size:1.8rem}}</style>
<main><p>DropDrawer</p><h1>{title}</h1><p>{detail}</p></main></html>"#)),
    ).into_response()
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
        let google = state.google_login.as_ref().unwrap();
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
        let token = create_jwt(&user.id, &user.username, &state.jwt_secret).unwrap();
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
}
