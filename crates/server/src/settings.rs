use protocol::{AuthProviderInfo, AuthPublicConfig, StorageBackendKind};
use serde::{Deserialize, Serialize};

use crate::google_login::GoogleLoginConfig;

pub const RUNTIME_SETTINGS_KEY: &str = "runtime_settings";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RegistrationMode {
    #[default]
    Open,
    InviteOnly,
    Closed,
}

impl RegistrationMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::InviteOnly => "invite_only",
            Self::Closed => "closed",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GoogleProviderSettings {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub admin_enabled: bool,
    #[serde(default)]
    pub client_id: String,
    #[serde(default)]
    pub client_secret: String,
    #[serde(default)]
    pub redirect_uri: String,
}

impl GoogleProviderSettings {
    pub fn from_google_config(cfg: &GoogleLoginConfig) -> Self {
        Self {
            enabled: true,
            admin_enabled: false,
            client_id: cfg.client_id().to_owned(),
            client_secret: cfg.client_secret().to_owned(),
            redirect_uri: cfg.redirect_uri().to_owned(),
        }
    }

    pub fn to_google_config(&self) -> anyhow::Result<Option<GoogleLoginConfig>> {
        if !self.enabled && !self.admin_enabled {
            return Ok(None);
        }
        GoogleLoginConfig::from_parts(&self.client_id, &self.client_secret, &self.redirect_uri)
            .map(Some)
    }
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdminTurnstileSettings {
    pub enabled: bool,
    pub site_key: String,
    pub secret_key: String,
    pub hostname: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SanitizedAdminTurnstileSettings {
    pub enabled: bool,
    pub site_key: String,
    pub has_secret_key: bool,
    pub hostname: String,
}

#[derive(Deserialize)]
pub struct UpdateAdminTurnstileInput {
    pub enabled: bool,
    pub site_key: String,
    pub secret_key: Option<String>,
    pub hostname: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SmtpSecurity {
    #[default]
    StartTls,
    Tls,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SmtpSettings {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub host: String,
    #[serde(default = "default_smtp_port")]
    pub port: u16,
    #[serde(default)]
    pub security: SmtpSecurity,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub from_address: String,
    #[serde(default = "default_from_name")]
    pub from_name: String,
}

fn default_smtp_port() -> u16 {
    587
}

fn default_from_name() -> String {
    "DropDrawer".to_string()
}

impl Default for SmtpSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            host: String::new(),
            port: default_smtp_port(),
            security: SmtpSecurity::StartTls,
            username: String::new(),
            password: String::new(),
            from_address: String::new(),
            from_name: default_from_name(),
        }
    }
}

impl SmtpSettings {
    pub fn is_usable(&self) -> bool {
        self.enabled
            && !self.host.trim().is_empty()
            && self.port > 0
            && !self.from_address.trim().is_empty()
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        if !self.enabled {
            return Ok(());
        }
        anyhow::ensure!(!self.host.trim().is_empty(), t!("SMTP 主机不能为空", "SMTP host can't be empty"));
        anyhow::ensure!(self.port > 0, t!("SMTP 端口无效", "Invalid SMTP port"));
        anyhow::ensure!(
            is_valid_email(&self.from_address),
            t!("SMTP 发件人邮箱格式无效", "Invalid SMTP sender email address")
        );
        Ok(())
    }

    pub fn from_env(get: &impl Fn(&str) -> Option<String>) -> Self {
        let host = get("DROPDRAWER_SMTP_HOST").unwrap_or_default().trim().to_owned();
        if host.is_empty() {
            return Self::default();
        }
        let port = get("DROPDRAWER_SMTP_PORT")
            .and_then(|v| v.trim().parse::<u16>().ok())
            .unwrap_or_else(default_smtp_port);
        let security = match get("DROPDRAWER_SMTP_SECURITY")
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "tls" | "smtps" | "ssl" => SmtpSecurity::Tls,
            "none" | "plain" => SmtpSecurity::None,
            _ => SmtpSecurity::StartTls,
        };
        let username = get("DROPDRAWER_SMTP_USERNAME").unwrap_or_default().trim().to_owned();
        let password = get("DROPDRAWER_SMTP_PASSWORD").unwrap_or_default();
        let from_address = get("DROPDRAWER_SMTP_FROM")
            .unwrap_or_else(|| username.clone())
            .trim()
            .to_owned();
        let from_name = get("DROPDRAWER_SMTP_FROM_NAME")
            .map(|v| v.trim().to_owned())
            .filter(|v| !v.is_empty())
            .unwrap_or_else(default_from_name);
        let enabled = !from_address.is_empty();
        Self {
            enabled,
            host,
            port,
            security,
            username,
            password,
            from_address,
            from_name,
        }
    }
}

/// Placeholder descriptor for future pluggable identity providers (GitHub / Apple / OIDC).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtraAuthProvider {
    pub id: String,
    pub name: String,
    pub kind: String,
    #[serde(default)]
    pub enabled: bool,
}

/// Server-wide feature switches. Every switch defaults to "on" so that databases
/// saved before a switch existed keep their previous behaviour.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeatureFlags {
    /// First-time Google sign-in may create a new account (still subject to the registration mode).
    #[serde(default = "default_true")]
    pub google_signup_enabled: bool,
    /// Self-service password reset by email code.
    #[serde(default = "default_true")]
    pub password_reset_enabled: bool,
    /// Uploading drawer files to server-local storage or a cloud drive. P2P transfers are unaffected.
    #[serde(default = "default_true")]
    pub cloud_upload_enabled: bool,
    /// Users may create new public share links.
    #[serde(default = "default_true")]
    pub share_create_enabled: bool,
    /// Existing public share links can be opened and downloaded.
    #[serde(default = "default_true")]
    pub share_access_enabled: bool,
}

impl Default for FeatureFlags {
    fn default() -> Self {
        Self {
            google_signup_enabled: true,
            password_reset_enabled: true,
            cloud_upload_enabled: true,
            share_create_enabled: true,
            share_access_enabled: true,
        }
    }
}

/// Rules applied when users create public share links.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SharePolicy {
    #[serde(default)]
    pub require_passcode: bool,
    /// Upper bound (and default) for a share link's lifetime.
    #[serde(default)]
    pub max_expires_hours: Option<u64>,
    /// Upper bound (and default) for a share link's download count.
    #[serde(default)]
    pub max_downloads_cap: Option<u64>,
}

/// Which storage backends users may add and where they may point.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StoragePolicy {
    #[serde(default)]
    pub disabled_backend_kinds: Vec<StorageBackendKind>,
    /// Refuse WebDAV / S3 / API endpoints that resolve to loopback, private or link-local addresses.
    #[serde(default)]
    pub block_private_endpoints: bool,
}

impl StoragePolicy {
    pub fn kind_allowed(&self, kind: StorageBackendKind) -> bool {
        !self.disabled_backend_kinds.contains(&kind)
    }
}

/// Per-user usage ceilings. `None` means unlimited.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageLimits {
    #[serde(default)]
    pub max_devices_per_user: Option<u64>,
    #[serde(default)]
    pub max_items_per_user: Option<u64>,
    /// Lifetime of a drawer item when the client does not ask for one (built-in default: 7 days).
    #[serde(default)]
    pub default_item_ttl_hours: Option<u64>,
    #[serde(default)]
    pub max_item_ttl_hours: Option<u64>,
}

pub const BUILTIN_ITEM_TTL_HOURS: u64 = 24 * 7;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnnouncementLevel {
    #[default]
    Info,
    Warning,
    Critical,
}

impl AnnouncementLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Critical => "critical",
        }
    }
}

/// Banner shown in every client while enabled.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Announcement {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub level: AnnouncementLevel,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub message: String,
    /// Set by the server whenever the content changes; doubles as the banner id.
    #[serde(default)]
    pub updated_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl Announcement {
    pub fn same_content(&self, other: &Self) -> bool {
        self.enabled == other.enabled
            && self.level == other.level
            && self.title == other.title
            && self.message == other.message
    }
}

/// Requirements for connecting clients.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClientPolicy {
    /// Devices reporting an older app version (or none at all) cannot register.
    #[serde(default)]
    pub min_version: Option<String>,
}

/// Parse `"1.2.3"`, `"v1.2.3"` or `"1.2.3+45"` into numeric components.
pub fn parse_version(raw: &str) -> Option<Vec<u64>> {
    let core = raw.trim().trim_start_matches(['v', 'V']);
    let core = core.split(['+', '-', ' ']).next()?;
    if core.is_empty() {
        return None;
    }
    core.split('.').map(|p| p.parse::<u64>().ok()).collect()
}

/// `true` when `version` is older than `minimum`. Unparseable versions count as older.
pub fn version_below(version: Option<&str>, minimum: &str) -> bool {
    let Some(min) = parse_version(minimum) else {
        return false;
    };
    let Some(mut have) = version.and_then(parse_version) else {
        return true;
    };
    let mut min = min;
    let len = have.len().max(min.len());
    have.resize(len, 0);
    min.resize(len, 0);
    have < min
}

impl UsageLimits {
    /// Effective lifetime for a new drawer item.
    pub fn item_ttl_hours(&self, requested: Option<u64>) -> u64 {
        let hours = requested
            .or(self.default_item_ttl_hours)
            .unwrap_or(BUILTIN_ITEM_TTL_HOURS);
        match self.max_item_ttl_hours {
            Some(max) => hours.min(max),
            None => hours,
        }
    }
}

fn positive(v: Option<u64>) -> Option<u64> {
    v.filter(|&n| n > 0)
}

#[derive(Clone, Serialize, Deserialize)]
pub struct RuntimeSettings {
    #[serde(default)]
    pub registration_mode: RegistrationMode,
    #[serde(default = "default_true")]
    pub password_login_enabled: bool,
    #[serde(default)]
    pub email_verification_required: bool,
    #[serde(default)]
    pub email_allowed_domains: Vec<String>,
    #[serde(default)]
    pub email_blocked_domains: Vec<String>,
    #[serde(default)]
    pub local_max_file_bytes: Option<u64>,
    #[serde(default)]
    pub default_user_local_quota_bytes: Option<u64>,
    #[serde(default)]
    pub google: GoogleProviderSettings,
    #[serde(default)]
    pub admin_turnstile: AdminTurnstileSettings,
    #[serde(default)]
    pub smtp: SmtpSettings,
    #[serde(default)]
    pub extra_providers: Vec<ExtraAuthProvider>,
    #[serde(default)]
    pub features: FeatureFlags,
    #[serde(default)]
    pub share_policy: SharePolicy,
    #[serde(default)]
    pub storage_policy: StoragePolicy,
    #[serde(default)]
    pub limits: UsageLimits,
    #[serde(default)]
    pub announcement: Announcement,
    #[serde(default)]
    pub client_policy: ClientPolicy,
}

fn default_true() -> bool {
    true
}

impl Default for RuntimeSettings {
    fn default() -> Self {
        Self {
            registration_mode: RegistrationMode::Open,
            password_login_enabled: true,
            email_verification_required: false,
            email_allowed_domains: Vec::new(),
            email_blocked_domains: Vec::new(),
            local_max_file_bytes: None,
            default_user_local_quota_bytes: None,
            google: GoogleProviderSettings::default(),
            admin_turnstile: AdminTurnstileSettings::default(),
            smtp: SmtpSettings::default(),
            extra_providers: Vec::new(),
            features: FeatureFlags::default(),
            share_policy: SharePolicy::default(),
            storage_policy: StoragePolicy::default(),
            limits: UsageLimits::default(),
            announcement: Announcement::default(),
            client_policy: ClientPolicy::default(),
        }
    }
}

impl RuntimeSettings {
    /// Collapse zero values to "unlimited" and drop duplicate entries.
    pub fn normalize(&mut self) {
        self.local_max_file_bytes = positive(self.local_max_file_bytes);
        self.default_user_local_quota_bytes = positive(self.default_user_local_quota_bytes);
        self.share_policy.max_expires_hours = positive(self.share_policy.max_expires_hours);
        self.share_policy.max_downloads_cap = positive(self.share_policy.max_downloads_cap);
        self.limits.max_devices_per_user = positive(self.limits.max_devices_per_user);
        self.limits.max_items_per_user = positive(self.limits.max_items_per_user);
        self.limits.default_item_ttl_hours = positive(self.limits.default_item_ttl_hours);
        self.limits.max_item_ttl_hours = positive(self.limits.max_item_ttl_hours);
        let mut kinds = Vec::new();
        for kind in self.storage_policy.disabled_backend_kinds.drain(..) {
            if !kinds.contains(&kind) {
                kinds.push(kind);
            }
        }
        self.storage_policy.disabled_backend_kinds = kinds;
        self.announcement.title = self.announcement.title.trim().chars().take(80).collect();
        self.announcement.message = self.announcement.message.trim().chars().take(1000).collect();
        self.client_policy.min_version = self
            .client_policy
            .min_version
            .take()
            .map(|v| v.trim().trim_start_matches(['v', 'V']).to_string())
            .filter(|v| !v.is_empty());
    }

    /// Announcement as shown to clients, if one is active.
    pub fn client_announcement(&self) -> Option<protocol::ClientAnnouncement> {
        let a = &self.announcement;
        if !a.enabled || (a.title.is_empty() && a.message.is_empty()) {
            return None;
        }
        Some(protocol::ClientAnnouncement {
            id: a
                .updated_at
                .map(|t| t.timestamp_millis().to_string())
                .unwrap_or_else(|| "0".to_string()),
            level: a.level.as_str().to_string(),
            title: a.title.clone(),
            message: a.message.clone(),
        })
    }

    /// Whether a brand-new account may be created through Google sign-in for `email`.
    pub fn google_signup_allowed(&self, email: &str) -> bool {
        self.registration_mode == RegistrationMode::Open
            && self.features.google_signup_enabled
            && self.check_email_domain(email).is_ok()
    }

    pub fn to_public_auth_config(&self, has_email_delivery: bool) -> AuthPublicConfig {
        let mut providers = Vec::new();
        if self.google.enabled && self.google.to_google_config().ok().flatten().is_some() {
            providers.push(AuthProviderInfo {
                id: "google".to_string(),
                name: "Google".to_string(),
                kind: "oauth2_oidc".to_string(),
                enabled: true,
            });
        }
        for p in &self.extra_providers {
            if p.enabled {
                providers.push(AuthProviderInfo {
                    id: p.id.clone(),
                    name: p.name.clone(),
                    kind: p.kind.clone(),
                    enabled: true,
                });
            }
        }
        let email_ready = has_email_delivery || self.smtp.is_usable();
        AuthPublicConfig {
            registration_mode: self.registration_mode.as_str().to_string(),
            password_login_enabled: self.password_login_enabled,
            email_verification_required: self.email_verification_required && email_ready,
            email_password_reset_enabled: email_ready && self.features.password_reset_enabled,
            providers,
        }
    }

    pub fn to_sanitized(&self) -> SanitizedRuntimeSettings {
        SanitizedRuntimeSettings {
            registration_mode: self.registration_mode,
            password_login_enabled: self.password_login_enabled,
            email_verification_required: self.email_verification_required,
            email_allowed_domains: self.email_allowed_domains.clone(),
            email_blocked_domains: self.email_blocked_domains.clone(),
            local_max_file_bytes: self.local_max_file_bytes,
            default_user_local_quota_bytes: self.default_user_local_quota_bytes,
            google: SanitizedGoogleProviderSettings {
                enabled: self.google.enabled,
                admin_enabled: self.google.admin_enabled,
                client_id: self.google.client_id.clone(),
                has_client_secret: !self.google.client_secret.trim().is_empty(),
                redirect_uri: self.google.redirect_uri.clone(),
            },
            admin_turnstile: SanitizedAdminTurnstileSettings {
                enabled: self.admin_turnstile.enabled,
                site_key: self.admin_turnstile.site_key.clone(),
                has_secret_key: !self.admin_turnstile.secret_key.is_empty(),
                hostname: self.admin_turnstile.hostname.clone(),
            },
            smtp: SanitizedSmtpSettings {
                enabled: self.smtp.enabled,
                host: self.smtp.host.clone(),
                port: self.smtp.port,
                security: self.smtp.security,
                username: self.smtp.username.clone(),
                has_password: !self.smtp.password.is_empty(),
                from_address: self.smtp.from_address.clone(),
                from_name: self.smtp.from_name.clone(),
            },
            features: self.features.clone(),
            share_policy: self.share_policy.clone(),
            storage_policy: self.storage_policy.clone(),
            limits: self.limits.clone(),
            announcement: self.announcement.clone(),
            client_policy: self.client_policy.clone(),
        }
    }

    pub fn check_email_domain(&self, email: &str) -> Result<(), String> {
        let Some((_, domain)) = email.trim().rsplit_once('@') else {
            return Err(t!("邮箱格式无效", "Invalid email address").to_string());
        };
        let domain = domain.to_ascii_lowercase();
        if !self.email_allowed_domains.is_empty()
            && !self
                .email_allowed_domains
                .iter()
                .any(|d| d.eq_ignore_ascii_case(&domain))
        {
            return Err(tf!("当前服务器仅允许特定域名邮箱注册（不支持 @{domain}）", "This server only allows sign-ups from specific email domains (@{domain} isn't allowed)"));
        }
        if self
            .email_blocked_domains
            .iter()
            .any(|d| d.eq_ignore_ascii_case(&domain))
        {
            return Err(tf!("邮箱域名 @{domain} 已被禁止注册", "Sign-ups from @{domain} are blocked"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SanitizedGoogleProviderSettings {
    pub enabled: bool,
    pub admin_enabled: bool,
    pub client_id: String,
    pub has_client_secret: bool,
    pub redirect_uri: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SanitizedSmtpSettings {
    pub enabled: bool,
    pub host: String,
    pub port: u16,
    pub security: SmtpSecurity,
    pub username: String,
    pub has_password: bool,
    pub from_address: String,
    pub from_name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SanitizedRuntimeSettings {
    pub registration_mode: RegistrationMode,
    pub password_login_enabled: bool,
    pub email_verification_required: bool,
    pub email_allowed_domains: Vec<String>,
    pub email_blocked_domains: Vec<String>,
    pub local_max_file_bytes: Option<u64>,
    pub default_user_local_quota_bytes: Option<u64>,
    pub google: SanitizedGoogleProviderSettings,
    pub admin_turnstile: SanitizedAdminTurnstileSettings,
    pub smtp: SanitizedSmtpSettings,
    pub features: FeatureFlags,
    pub share_policy: SharePolicy,
    pub storage_policy: StoragePolicy,
    pub limits: UsageLimits,
    pub announcement: Announcement,
    pub client_policy: ClientPolicy,
}

#[derive(Deserialize)]
pub struct UpdateGoogleProviderInput {
    pub enabled: bool,
    pub admin_enabled: Option<bool>,
    #[serde(default)]
    pub client_id: String,
    /// Leave `None` or empty string to keep existing secret unchanged.
    #[serde(default)]
    pub client_secret: Option<String>,
    #[serde(default)]
    pub redirect_uri: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdateSmtpInput {
    pub enabled: bool,
    #[serde(default)]
    pub host: String,
    #[serde(default = "default_smtp_port")]
    pub port: u16,
    #[serde(default)]
    pub security: SmtpSecurity,
    #[serde(default)]
    pub username: String,
    /// Leave `None` or empty string to keep existing password unchanged.
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub from_address: String,
    #[serde(default = "default_from_name")]
    pub from_name: String,
}

#[derive(Deserialize)]
pub struct UpdateSettingsRequest {
    pub registration_mode: RegistrationMode,
    pub password_login_enabled: bool,
    pub email_verification_required: bool,
    #[serde(default)]
    pub email_allowed_domains: Vec<String>,
    #[serde(default)]
    pub email_blocked_domains: Vec<String>,
    #[serde(default)]
    pub local_max_file_bytes: Option<u64>,
    #[serde(default)]
    pub default_user_local_quota_bytes: Option<u64>,
    pub google: UpdateGoogleProviderInput,
    pub admin_turnstile: Option<UpdateAdminTurnstileInput>,
    pub smtp: UpdateSmtpInput,
    /// Omitted sections keep their current values (older admin pages / scripts).
    #[serde(default)]
    pub features: Option<FeatureFlags>,
    #[serde(default)]
    pub share_policy: Option<SharePolicy>,
    #[serde(default)]
    pub storage_policy: Option<StoragePolicy>,
    #[serde(default)]
    pub limits: Option<UsageLimits>,
    #[serde(default)]
    pub announcement: Option<Announcement>,
    #[serde(default)]
    pub client_policy: Option<ClientPolicy>,
}

pub fn normalize_domain_list(raw: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for entry in raw {
        for part in entry.split([',', ';', '\n', ' ']) {
            let cleaned = part.trim().trim_start_matches('@').to_ascii_lowercase();
            if !cleaned.is_empty() && !out.contains(&cleaned) {
                out.push(cleaned);
            }
        }
    }
    out
}

pub fn is_valid_email(raw: &str) -> bool {
    let s = raw.trim();
    if s.len() < 5 || s.len() > 254 || s.chars().any(char::is_whitespace) {
        return false;
    }
    let Some((local, domain)) = s.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && !domain.contains('@')
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_comparison_handles_prefixes_and_build_suffixes() {
        assert!(version_below(Some("0.1.4"), "0.1.5"));
        assert!(!version_below(Some("0.1.5"), "0.1.5"));
        assert!(!version_below(Some("v0.2"), "0.1.9"));
        assert!(!version_below(Some("0.1.5+12"), "0.1.5"));
        assert!(version_below(Some("0.1"), "0.1.1"));
        assert!(version_below(None, "0.1.0"), "clients that do not report a version are too old");
        assert!(version_below(Some("garbage"), "0.1.0"));
        assert!(!version_below(Some("1.0.0"), "not-a-version"));
    }

    #[test]
    fn settings_saved_before_new_sections_keep_permissive_defaults() {
        let old: RuntimeSettings =
            serde_json::from_str(r#"{"registration_mode":"invite_only"}"#).unwrap();
        assert_eq!(old.registration_mode, RegistrationMode::InviteOnly);
        assert!(old.password_login_enabled);
        assert!(old.features.share_create_enabled && old.features.cloud_upload_enabled);
        assert!(old.storage_policy.disabled_backend_kinds.is_empty());
        assert!(old.limits.max_devices_per_user.is_none());
        assert!(!old.announcement.enabled);
        assert!(old.client_policy.min_version.is_none());
        assert_eq!(old.limits.item_ttl_hours(None), BUILTIN_ITEM_TTL_HOURS);
    }
}
