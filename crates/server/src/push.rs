//! Push notifications for devices that are not connected.
//!
//! When something is put in the drawer, other devices of the account with a
//! push token receive a notification if they are in the background or offline.
//! A background device can keep its WebSocket for active transfers:
//!
//! - iOS through Apple Push Notification service (token-based `.p8` auth, HTTP/2);
//! - Android through Firebase Cloud Messaging HTTP v1 (service account).
//!
//! Both are optional and configured with environment variables (see
//! `docs/CONFIGURATION.md`). Notifications name the sending device and the file;
//! text content never leaves the server. Tokens the provider reports as invalid
//! are deleted.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use protocol::{DrawerItem, DrawerItemKind, FcmClientOptions, PushClientConfig, PushProvider};
use serde::Deserialize;
use serde_json::json;

use crate::db::PushTokenRecord;
use crate::i18n::{self, Lang};
use crate::state::AppState;

const APNS_PRODUCTION: &str = "https://api.push.apple.com";
const APNS_SANDBOX: &str = "https://api.sandbox.push.apple.com";
const FCM_API: &str = "https://fcm.googleapis.com";
const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
/// Android notification channel created by the app (`MainActivity.kt`).
pub const ANDROID_CHANNEL_ID: &str = "drawer_items";

pub struct ApnsConfig {
    pub key_id: String,
    pub team_id: String,
    /// The iOS app's bundle identifier.
    pub topic: String,
    key: EncodingKey,
    /// Overrides both APNs hosts (tests).
    pub base_url: Option<String>,
}

pub struct FcmConfig {
    pub client_email: String,
    pub token_uri: String,
    key: EncodingKey,
    pub client: FcmClientOptions,
    /// Overrides the FCM API host (tests).
    pub api_base_url: Option<String>,
}

#[derive(Deserialize)]
struct ServiceAccount {
    project_id: String,
    client_email: String,
    private_key: String,
    #[serde(default = "default_token_uri")]
    token_uri: String,
}

fn default_token_uri() -> String {
    "https://oauth2.googleapis.com/token".to_string()
}

impl ApnsConfig {
    pub fn new(key_pem: &str, key_id: &str, team_id: &str, topic: &str) -> anyhow::Result<Self> {
        Ok(Self {
            key_id: key_id.trim().to_string(),
            team_id: team_id.trim().to_string(),
            topic: topic.trim().to_string(),
            key: EncodingKey::from_ec_pem(key_pem.as_bytes())
                .context("the APNs key must be the .p8 file from Apple (PEM)")?,
            base_url: None,
        })
    }
}

impl FcmConfig {
    /// `service_account_json` is the key file downloaded from the Firebase
    /// console; the rest comes from the Android app's Firebase settings.
    pub fn new(
        service_account_json: &str,
        application_id: &str,
        api_key: &str,
        sender_id: &str,
    ) -> anyhow::Result<Self> {
        let account: ServiceAccount = serde_json::from_str(service_account_json)
            .context("the FCM service account file is not valid JSON")?;
        Ok(Self {
            key: EncodingKey::from_rsa_pem(account.private_key.as_bytes())
                .context("the FCM service account has an invalid private key")?,
            client_email: account.client_email,
            token_uri: account.token_uri,
            client: FcmClientOptions {
                project_id: account.project_id,
                application_id: application_id.trim().to_string(),
                api_key: api_key.trim().to_string(),
                sender_id: sender_id.trim().to_string(),
            },
            api_base_url: None,
        })
    }
}

struct CachedToken {
    value: String,
    refresh_after: Instant,
}

pub struct PushService {
    http: reqwest::Client,
    apns: Option<ApnsConfig>,
    fcm: Option<FcmConfig>,
    apns_token: Mutex<Option<CachedToken>>,
    fcm_token: tokio::sync::Mutex<Option<CachedToken>>,
}

/// What happened to one delivery.
#[derive(Debug, PartialEq, Eq)]
pub enum Delivery {
    Sent,
    /// The provider says the token is no longer valid; it gets deleted.
    InvalidToken,
}

impl PushService {
    pub fn new(apns: Option<ApnsConfig>, fcm: Option<FcmConfig>) -> Option<Arc<Self>> {
        if apns.is_none() && fcm.is_none() {
            return None;
        }
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()
            .ok()?;
        Some(Arc::new(Self {
            http,
            apns,
            fcm,
            apns_token: Mutex::new(None),
            fcm_token: tokio::sync::Mutex::new(None),
        }))
    }

    /// Reads the push configuration from the environment. Returns `Ok(None)`
    /// when neither service is configured, and an error when one is configured
    /// incompletely, so a typo does not silently disable notifications.
    pub fn from_settings(get: impl Fn(&str) -> Option<String>) -> anyhow::Result<Option<Arc<Self>>> {
        let value = |key: &str| get(key).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let file_or_value = |inline: &str, path: &str| -> anyhow::Result<Option<String>> {
            if let Some(v) = value(inline) {
                return Ok(Some(v.replace("\\n", "\n")));
            }
            value(path)
                .map(|p| std::fs::read_to_string(&p).with_context(|| format!("cannot read {path}={p}")))
                .transpose()
        };

        let apns = match file_or_value("DROPDRAWER_APNS_KEY", "DROPDRAWER_APNS_KEY_PATH")? {
            Some(pem) => {
                let need = |key: &str| value(key).ok_or_else(|| anyhow!("{key} is required when an APNs key is set"));
                let mut cfg = ApnsConfig::new(
                    &pem,
                    &need("DROPDRAWER_APNS_KEY_ID")?,
                    &need("DROPDRAWER_APNS_TEAM_ID")?,
                    &value("DROPDRAWER_APNS_TOPIC").unwrap_or_else(|| "com.dropdrawer.ios".to_string()),
                )?;
                cfg.base_url = value("DROPDRAWER_APNS_BASE_URL");
                Some(cfg)
            }
            None => None,
        };
        let fcm = match file_or_value(
            "DROPDRAWER_FCM_SERVICE_ACCOUNT",
            "DROPDRAWER_FCM_SERVICE_ACCOUNT_PATH",
        )? {
            Some(json) => {
                let need = |key: &str| {
                    value(key).ok_or_else(|| anyhow!("{key} is required when an FCM service account is set"))
                };
                let mut cfg = FcmConfig::new(
                    &json,
                    &need("DROPDRAWER_FCM_APP_ID")?,
                    &need("DROPDRAWER_FCM_API_KEY")?,
                    &need("DROPDRAWER_FCM_SENDER_ID")?,
                )?;
                cfg.api_base_url = value("DROPDRAWER_FCM_BASE_URL");
                Some(cfg)
            }
            None => None,
        };
        Ok(Self::new(apns, fcm))
    }

    pub fn client_config(&self) -> PushClientConfig {
        PushClientConfig {
            apns: self.apns.is_some(),
            fcm: self.fcm.as_ref().map(|f| f.client.clone()),
        }
    }

    pub fn supports(&self, provider: PushProvider) -> bool {
        match provider {
            PushProvider::Apns => self.apns.is_some(),
            PushProvider::Fcm => self.fcm.is_some(),
        }
    }

    pub async fn send(
        &self,
        target: &PushTokenRecord,
        title: &str,
        body: &str,
        item_id: &str,
    ) -> anyhow::Result<Delivery> {
        match target.provider {
            PushProvider::Apns => self.send_apns(target, title, body, item_id).await,
            PushProvider::Fcm => self.send_fcm(target, title, body, item_id).await,
        }
    }

    fn apns_jwt(&self, cfg: &ApnsConfig) -> anyhow::Result<String> {
        let mut cached = self.apns_token.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(token) = cached.as_ref().filter(|t| t.refresh_after > Instant::now()) {
            return Ok(token.value.clone());
        }
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(cfg.key_id.clone());
        let claims = json!({ "iss": cfg.team_id, "iat": chrono::Utc::now().timestamp() });
        let value = jsonwebtoken::encode(&header, &claims, &cfg.key)?;
        // Apple accepts a provider token for an hour and rejects refreshing it
        // more often than every 20 minutes.
        *cached = Some(CachedToken {
            value: value.clone(),
            refresh_after: Instant::now() + Duration::from_secs(45 * 60),
        });
        Ok(value)
    }

    async fn send_apns(
        &self,
        target: &PushTokenRecord,
        title: &str,
        body: &str,
        item_id: &str,
    ) -> anyhow::Result<Delivery> {
        let cfg = self.apns.as_ref().ok_or_else(|| anyhow!("APNs is not configured"))?;
        let host = cfg.base_url.as_deref().unwrap_or(if target.sandbox {
            APNS_SANDBOX
        } else {
            APNS_PRODUCTION
        });
        let response = self
            .http
            .post(format!("{}/3/device/{}", host.trim_end_matches('/'), target.token))
            .bearer_auth(self.apns_jwt(cfg)?)
            .header("apns-topic", &cfg.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-collapse-id", item_id)
            .json(&json!({
                "aps": {
                    "alert": { "title": title, "body": body },
                    "sound": "default",
                    "thread-id": "drawer",
                },
                "item_id": item_id,
            }))
            .send()
            .await?;
        let status = response.status();
        if status.is_success() {
            return Ok(Delivery::Sent);
        }
        let reason = response
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|v| v.get("reason").and_then(|r| r.as_str()).map(str::to_owned))
            .unwrap_or_default();
        if status == reqwest::StatusCode::GONE
            || matches!(reason.as_str(), "BadDeviceToken" | "Unregistered" | "DeviceTokenNotForTopic")
        {
            return Ok(Delivery::InvalidToken);
        }
        bail!("APNs returned {status} {reason}")
    }

    async fn fcm_access_token(&self, cfg: &FcmConfig) -> anyhow::Result<String> {
        let mut cached = self.fcm_token.lock().await;
        if let Some(token) = cached.as_ref().filter(|t| t.refresh_after > Instant::now()) {
            return Ok(token.value.clone());
        }
        let now = chrono::Utc::now().timestamp();
        let assertion = jsonwebtoken::encode(
            &Header::new(Algorithm::RS256),
            &json!({
                "iss": cfg.client_email,
                "scope": FCM_SCOPE,
                "aud": cfg.token_uri,
                "iat": now,
                "exp": now + 3600,
            }),
            &cfg.key,
        )?;
        #[derive(Deserialize)]
        struct TokenResponse {
            access_token: String,
            #[serde(default)]
            expires_in: Option<u64>,
        }
        let response = self
            .http
            .post(&cfg.token_uri)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .send()
            .await?;
        if !response.status().is_success() {
            bail!("FCM token exchange returned {}", response.status());
        }
        let token: TokenResponse = response.json().await?;
        let lifetime = token.expires_in.unwrap_or(3600).saturating_sub(120).max(60);
        *cached = Some(CachedToken {
            value: token.access_token.clone(),
            refresh_after: Instant::now() + Duration::from_secs(lifetime),
        });
        Ok(token.access_token)
    }

    async fn send_fcm(
        &self,
        target: &PushTokenRecord,
        title: &str,
        body: &str,
        item_id: &str,
    ) -> anyhow::Result<Delivery> {
        let cfg = self.fcm.as_ref().ok_or_else(|| anyhow!("FCM is not configured"))?;
        let access_token = self.fcm_access_token(cfg).await?;
        let base = cfg.api_base_url.as_deref().unwrap_or(FCM_API).trim_end_matches('/');
        let response = self
            .http
            .post(format!(
                "{base}/v1/projects/{}/messages:send",
                cfg.client.project_id
            ))
            .bearer_auth(access_token)
            .json(&json!({
                "message": {
                    "token": target.token,
                    "notification": { "title": title, "body": body },
                    "data": { "item_id": item_id },
                    "android": {
                        "priority": "high",
                        "collapse_key": item_id,
                        "notification": { "channel_id": ANDROID_CHANNEL_ID, "tag": item_id },
                    },
                }
            }))
            .send()
            .await?;
        let status = response.status();
        if status.is_success() {
            return Ok(Delivery::Sent);
        }
        let error = response.json::<serde_json::Value>().await.unwrap_or_default();
        let code = error
            .pointer("/error/details")
            .and_then(|d| d.as_array())
            .and_then(|details| {
                details
                    .iter()
                    .find_map(|d| d.get("errorCode").and_then(|c| c.as_str()))
            })
            .or_else(|| error.pointer("/error/status").and_then(|s| s.as_str()))
            .unwrap_or_default()
            .to_string();
        if status == reqwest::StatusCode::NOT_FOUND
            || matches!(code.as_str(), "UNREGISTERED" | "INVALID_ARGUMENT" | "SENDER_ID_MISMATCH")
        {
            return Ok(Delivery::InvalidToken);
        }
        bail!("FCM returned {status} {code}")
    }
}

/// Text of the notification for a new item, in the receiving device's language.
fn item_notification(item: &DrawerItem) -> (String, String) {
    let device = item
        .owner_device_name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty());
    let title = match device {
        Some(device) => tf!("来自 {device}", "From {device}"),
        None => t!("抽屉里有新内容", "New in your drawer").to_string(),
    };
    let body = match item.kind {
        // Never send the text itself through Apple or Google.
        DrawerItemKind::Text => t!("一段文字", "A text snippet").to_string(),
        DrawerItemKind::File => item.name.clone(),
    };
    (title, body)
}

/// Notifies the account's other background or disconnected devices.
/// Runs in the background; failures are logged, never returned to the sender.
pub fn notify_item_added(state: &Arc<AppState>, user_id: &str, item: &DrawerItem) {
    let Some(push) = state.push() else {
        return;
    };
    let targets = match state.db.list_push_tokens(user_id) {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!("cannot list push tokens: {err}");
            return;
        }
    };
    let targets: Vec<_> = targets
        .into_iter()
        .filter(|t| t.device_id != item.owner_device_id)
        .filter(|t| push.supports(t.provider))
        .filter(|t| {
            let key = (user_id.to_string(), t.device_id.clone());
            !state.connections.contains_key(&key) || state.background_push_devices.contains(&key)
        })
        .collect();
    if targets.is_empty() {
        return;
    }
    let state = state.clone();
    let item = item.clone();
    tokio::spawn(async move {
        for target in targets {
            // A queued delivery must still belong to the registered device
            // after a sign-out or token replacement.
            if !matches!(state.db.is_current_push_token(&target), Ok(true)) {
                continue;
            }
            let lang = Lang::from_accept_language(Some(&target.language));
            let (title, body) = i18n::scope(lang, async { item_notification(&item) }).await;
            match push.send(&target, &title, &body, &item.id).await {
                Ok(Delivery::Sent) => {}
                Ok(Delivery::InvalidToken) => {
                    tracing::info!(device = %target.device_id, "removing an expired push token");
                    let _ = state.db.delete_push_token_if_current(&target);
                }
                Err(err) => {
                    tracing::warn!(device = %target.device_id, "push notification failed: {err}")
                }
            }
        }
    });
}
