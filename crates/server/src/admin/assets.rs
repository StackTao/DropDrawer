//! Serves the single-page admin console from `ui/` (compiled into the binary).
//!
//! Everything is same-origin and the CSP forbids inline script and style, so a
//! value that slipped past the UI's DOM-only rendering still could not execute.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::{header, HeaderName, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};

use crate::state::AppState;

const INDEX_HTML: &str = include_str!("ui/index.html");
const ADMIN_CSS: &str = include_str!("ui/admin.css");
const ADMIN_JS: &str = include_str!("ui/admin.js");
const LOGO_SVG: &str = include_str!("ui/logo.svg");
const DISABLED_HTML: &str = include_str!("ui/disabled.html");

const CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; \
connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

const TURNSTILE_CSP: &str = "default-src 'none'; script-src 'self' https://challenges.cloudflare.com; \
style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-src https://challenges.cloudflare.com; \
font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

fn respond(status: StatusCode, content_type: &'static str, body: &'static str, csp: &'static str) -> Response {
    let headers = [
        (header::CONTENT_TYPE, HeaderValue::from_static(content_type)),
        (header::CACHE_CONTROL, HeaderValue::from_static("no-cache")),
        (header::CONTENT_SECURITY_POLICY, HeaderValue::from_static(csp)),
        (header::X_FRAME_OPTIONS, HeaderValue::from_static("DENY")),
        (header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff")),
        (header::REFERRER_POLICY, HeaderValue::from_static("no-referrer")),
        (
            HeaderName::from_static("cross-origin-opener-policy"),
            HeaderValue::from_static("same-origin"),
        ),
    ];
    (status, headers, body).into_response()
}

pub(super) async fn page(State(state): State<Arc<AppState>>) -> Response {
    if !state.admin_enabled {
        return respond(StatusCode::NOT_FOUND, "text/html; charset=utf-8", DISABLED_HTML, CSP);
    }
    let csp = if state.runtime_settings().admin_turnstile.enabled { TURNSTILE_CSP } else { CSP };
    respond(StatusCode::OK, "text/html; charset=utf-8", INDEX_HTML, csp)
}

pub(super) async fn asset(State(state): State<Arc<AppState>>, Path(file): Path<String>) -> Response {
    // The disabled page needs the stylesheet and logo too.
    let (content_type, body) = match file.as_str() {
        "admin.css" => ("text/css; charset=utf-8", ADMIN_CSS),
        "logo.svg" => ("image/svg+xml", LOGO_SVG),
        "admin.js" if state.admin_enabled => ("text/javascript; charset=utf-8", ADMIN_JS),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    respond(StatusCode::OK, content_type, body, CSP)
}
