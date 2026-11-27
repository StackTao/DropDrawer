use std::path::Path;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, Utc};
use protocol::{
    DeviceInfo, DevicePlatform, DrawerItem, DrawerItemKind, RegisterDeviceRequest,
    StorageBackendConfig,
    StorageBackendSummary, TransferMode, UserProfile,
};
use rusqlite::{params, Connection, OptionalExtension};

mod admin;
mod admins;
mod system;

pub use admins::{AdminAccount, AdminAccountSummary, AdminRole};

pub use admin::{
    AdminBackendKindCount, AdminDeviceRow, AdminItemRow, AdminOverviewStats, AdminShareRow,
    AdminUserSummary, AdminVersionCount, UserAuthState, UserPolicy,
};
pub use system::{AuditEntry, InviteCodeRecord};

#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

#[derive(Debug, Clone)]
pub struct UserRecord {
    pub id: String,
    pub username: String,
    pub password_hash: String,
    pub email: Option<String>,
    pub email_verified: bool,
    pub disabled: bool,
    pub created_at: DateTime<Utc>,
    /// Bumped to revoke every JWT issued to this user (forced sign-out, password change).
    pub token_version: u64,
}

#[derive(Debug, Clone)]
pub struct StorageBackendRecord {
    pub id: String,
    pub user_id: String,
    pub name: String,
    pub config: StorageBackendConfig,
    pub is_default: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct DrawerItemRow {
    pub id: String,
    pub user_id: String,
    pub owner_device_id: String,
    pub kind: DrawerItemKind,
    pub name: String,
    pub size: u64,
    pub mime_type: Option<String>,
    pub blake3_hash: Option<String>,
    pub text_content: Option<String>,
    pub thumbnail_base64: Option<String>,
    pub transfer_mode: TransferMode,
    pub storage_backend_id: Option<String>,
    pub storage_path: Option<String>,
    pub cloud_ready: bool,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct ShareLinkRow {
    pub code: String,
    pub user_id: String,
    pub item_id: String,
    pub title: Option<String>,
    pub passcode_hash: Option<String>,
    pub max_downloads: Option<u64>,
    pub download_count: u64,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GoogleResolveError {
    RegistrationClosed,
    InviteRequired,
    InviteInvalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GoogleSignupPolicy<'a> {
    Closed,
    Open,
    InviteOnly(Option<&'a str>),
}

impl Database {
    pub fn open(path: impl AsRef<Path>) -> anyhow::Result<Self> {
        if let Some(parent) = path.as_ref().parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA busy_timeout = 5000;
             PRAGMA foreign_keys = ON;

             CREATE TABLE IF NOT EXISTS users (
                 id TEXT PRIMARY KEY,
                 username TEXT NOT NULL UNIQUE,
                 password_hash TEXT NOT NULL,
                 created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS google_accounts (
                 subject TEXT PRIMARY KEY,
                 user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE
             );

             CREATE TABLE IF NOT EXISTS devices (
                 id TEXT PRIMARY KEY,
                 user_id TEXT NOT NULL,
                 name TEXT NOT NULL,
                 platform TEXT NOT NULL,
                 iroh_node_id TEXT,
                 iroh_relay_url TEXT,
                 direct_addrs_json TEXT NOT NULL DEFAULT '[]',
                 last_seen_at TEXT NOT NULL,
                 FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
             );

             CREATE TABLE IF NOT EXISTS storage_backends (
                 id TEXT PRIMARY KEY,
                 user_id TEXT NOT NULL,
                 name TEXT NOT NULL,
                 config_json TEXT NOT NULL,
                 is_default INTEGER NOT NULL DEFAULT 0,
                 created_at TEXT NOT NULL,
                 FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
             );

             CREATE TABLE IF NOT EXISTS drawer_items (
                 id TEXT PRIMARY KEY,
                 user_id TEXT NOT NULL,
                 owner_device_id TEXT NOT NULL,
                 kind TEXT NOT NULL,
                 name TEXT NOT NULL,
                 size INTEGER NOT NULL,
                 mime_type TEXT,
                 blake3_hash TEXT,
                 text_content TEXT,
                 thumbnail_base64 TEXT,
                 transfer_mode TEXT NOT NULL,
                 storage_backend_id TEXT,
                 storage_path TEXT,
                 content_sha256 TEXT,
                 cloud_ready INTEGER NOT NULL DEFAULT 0,
                 expires_at TEXT,
                 created_at TEXT NOT NULL,
                 FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
             );

             CREATE INDEX IF NOT EXISTS idx_drawer_items_user_created
                 ON drawer_items(user_id, created_at DESC);
             CREATE INDEX IF NOT EXISTS idx_drawer_items_expires
                 ON drawer_items(expires_at);

             CREATE TABLE IF NOT EXISTS share_links (
                 code TEXT PRIMARY KEY,
                 user_id TEXT NOT NULL,
                 item_id TEXT NOT NULL,
                 title TEXT,
                 passcode_hash TEXT,
                 max_downloads INTEGER,
                 download_count INTEGER NOT NULL DEFAULT 0,
                 expires_at TEXT,
                 created_at TEXT NOT NULL,
                 FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
                 FOREIGN KEY(item_id) REFERENCES drawer_items(id) ON DELETE CASCADE
             );

             CREATE TABLE IF NOT EXISTS share_link_items (
                 share_code TEXT NOT NULL,
                 item_id TEXT NOT NULL,
                 position INTEGER NOT NULL DEFAULT 0,
                 PRIMARY KEY (share_code, item_id),
                 FOREIGN KEY(share_code) REFERENCES share_links(code) ON DELETE CASCADE,
                 FOREIGN KEY(item_id) REFERENCES drawer_items(id) ON DELETE CASCADE
             );

             CREATE INDEX IF NOT EXISTS idx_share_links_user
                 ON share_links(user_id, created_at DESC);
             CREATE INDEX IF NOT EXISTS idx_devices_user
                 ON devices(user_id);
             CREATE INDEX IF NOT EXISTS idx_storage_backends_user
                 ON storage_backends(user_id);

             CREATE TABLE IF NOT EXISTS system_settings (
                 key TEXT PRIMARY KEY,
                 value_json TEXT NOT NULL,
                 updated_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS invite_codes (
                 code TEXT PRIMARY KEY,
                 note TEXT,
                 max_uses INTEGER NOT NULL DEFAULT 1,
                 used_count INTEGER NOT NULL DEFAULT 0,
                 expires_at TEXT,
                 created_at TEXT NOT NULL
             );

             CREATE TABLE IF NOT EXISTS email_verifications (
                 id TEXT PRIMARY KEY,
                 email TEXT NOT NULL,
                 purpose TEXT NOT NULL,
                 code_hash TEXT NOT NULL,
                 attempts INTEGER NOT NULL DEFAULT 0,
                 expires_at TEXT NOT NULL,
                 consumed INTEGER NOT NULL DEFAULT 0,
                 created_at TEXT NOT NULL
             );

             CREATE INDEX IF NOT EXISTS idx_email_verifications_lookup
                 ON email_verifications(email, purpose, created_at DESC);
            ",
        )?;
        // Idempotent migrations for databases created before newer columns were added.
        let _ = conn.execute("ALTER TABLE share_links ADD COLUMN title TEXT", []);
        let _ = conn.execute(
            "ALTER TABLE drawer_items ADD COLUMN content_sha256 TEXT",
            [],
        );
        let _ = conn.execute("ALTER TABLE users ADD COLUMN email TEXT", []);
        let _ = conn.execute(
            "ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0",
            [],
        );
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_drawer_items_dedup
             ON drawer_items(user_id, storage_backend_id, content_sha256, size)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_users_email_lower
             ON users(LOWER(email))",
            [],
        )?;
        system::migrate(&conn)?;
        admin::migrate(&conn)?;
        admins::migrate(&conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    fn lock_conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn create_user(
        &self,
        id: &str,
        username: &str,
        password_hash: &str,
    ) -> anyhow::Result<UserProfile> {
        self.create_user_with_email(id, username, password_hash, None, false)
    }

    pub fn create_user_with_email(
        &self,
        id: &str,
        username: &str,
        password_hash: &str,
        email: Option<&str>,
        email_verified: bool,
    ) -> anyhow::Result<UserProfile> {
        let now = Utc::now();
        let norm_email = email
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| s.to_ascii_lowercase());
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO users (id, username, password_hash, email, email_verified, disabled, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6)",
            params![
                id,
                username,
                password_hash,
                norm_email,
                email_verified as i32,
                now.to_rfc3339()
            ],
        )?;
        Ok(UserProfile {
            id: id.to_string(),
            username: username.to_string(),
            email: norm_email,
            created_at: now,
        })
    }

    pub fn resolve_google_user(
        &self,
        subject: &str,
        email: &str,
        registration_open: bool,
    ) -> anyhow::Result<Option<UserProfile>> {
        let policy = if registration_open {
            GoogleSignupPolicy::Open
        } else {
            GoogleSignupPolicy::Closed
        };
        match self.resolve_google_user_with_policy(subject, email, policy)? {
            Ok(profile) => Ok(Some(profile)),
            Err(_) => Ok(None),
        }
    }

    pub fn resolve_google_user_with_policy(
        &self,
        subject: &str,
        email: &str,
        signup_policy: GoogleSignupPolicy<'_>,
    ) -> anyhow::Result<Result<UserProfile, GoogleResolveError>> {
        let mut conn = self.lock_conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let existing = tx.query_row(
            "SELECT u.id, u.username, u.email, u.created_at FROM google_accounts g
             JOIN users u ON u.id = g.user_id WHERE g.subject = ?1",
            [subject],
            |row| {
                let created: String = row.get(3)?;
                Ok(UserProfile {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    email: row.get(2)?,
                    created_at: DateTime::parse_from_rfc3339(&created)
                        .map(|d| d.with_timezone(&Utc))
                        .unwrap_or_else(|_| Utc::now()),
                })
            },
        ).optional()?;
        if let Some(profile) = existing {
            return Ok(Ok(profile));
        }

        match signup_policy {
            GoogleSignupPolicy::Closed => return Ok(Err(GoogleResolveError::RegistrationClosed)),
            GoogleSignupPolicy::Open => {}
            GoogleSignupPolicy::InviteOnly(raw_code) => {
                let code = raw_code.map(str::trim).unwrap_or("");
                if code.is_empty() {
                    return Ok(Err(GoogleResolveError::InviteRequired));
                }
                let rec: Option<(String, i64, i64, Option<String>)> = tx
                    .query_row(
                        "SELECT code, max_uses, used_count, expires_at FROM invite_codes WHERE UPPER(code) = UPPER(?1)",
                        params![code],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                    )
                    .optional()?;
                let Some((exact_code, max_uses, used_count, expires_raw)) = rec else {
                    return Ok(Err(GoogleResolveError::InviteInvalid));
                };
                if used_count >= max_uses {
                    return Ok(Err(GoogleResolveError::InviteInvalid));
                }
                if let Some(exp_str) = expires_raw
                    && let Ok(exp) = DateTime::parse_from_rfc3339(&exp_str)
                    && exp.with_timezone(&Utc) <= Utc::now()
                {
                    return Ok(Err(GoogleResolveError::InviteInvalid));
                }
                tx.execute(
                    "UPDATE invite_codes SET used_count = used_count + 1 WHERE code = ?1",
                    params![exact_code],
                )?;
            }
        }

        let id = uuid::Uuid::new_v4().to_string();
        let created_at = Utc::now();
        let username_taken: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM users WHERE username = ?1)",
            [email],
            |row| row.get(0),
        )?;
        let username = if username_taken { format!("{email} ({id})") } else { email.to_owned() };
        let norm_email = email.trim().to_ascii_lowercase();
        let email_taken: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM users WHERE LOWER(email) = ?1)",
            [&norm_email],
            |row| row.get(0),
        )?;
        let stored_email = (!email_taken && !norm_email.is_empty()).then_some(norm_email);
        tx.execute(
            "INSERT INTO users (id, username, password_hash, email, email_verified, disabled, created_at)
             VALUES (?1, ?2, '', ?3, ?4, 0, ?5)",
            params![
                id,
                username,
                stored_email,
                stored_email.is_some() as i32,
                created_at.to_rfc3339()
            ],
        )?;
        tx.execute(
            "INSERT INTO google_accounts (subject, user_id) VALUES (?1, ?2)",
            params![subject, id],
        )?;
        tx.commit()?;
        Ok(Ok(UserProfile {
            id,
            username,
            email: stored_email,
            created_at,
        }))
    }

    fn map_user_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<UserRecord> {
        let email_verified: i32 = row.get(4)?;
        let disabled: i32 = row.get(5)?;
        let created: String = row.get(6)?;
        Ok(UserRecord {
            id: row.get(0)?,
            username: row.get(1)?,
            password_hash: row.get(2)?,
            email: row.get(3)?,
            email_verified: email_verified != 0,
            disabled: disabled != 0,
            created_at: DateTime::parse_from_rfc3339(&created)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now()),
            token_version: row.get::<_, i64>(7)?.max(0) as u64,
        })
    }

    pub fn find_user_by_username(&self, username: &str) -> anyhow::Result<Option<UserRecord>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, username, password_hash, email, email_verified, disabled, created_at, token_version
             FROM users WHERE username = ?1",
            params![username],
            Self::map_user_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn find_user_by_id(&self, id: &str) -> anyhow::Result<Option<UserRecord>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, username, password_hash, email, email_verified, disabled, created_at, token_version
             FROM users WHERE id = ?1",
            params![id],
            Self::map_user_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn find_user_by_email(&self, email: &str) -> anyhow::Result<Option<UserRecord>> {
        let norm = email.trim().to_ascii_lowercase();
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, username, password_hash, email, email_verified, disabled, created_at, token_version
             FROM users WHERE LOWER(email) = ?1",
            params![norm],
            Self::map_user_row,
        )
        .optional()
        .map_err(Into::into)
    }

    /// Look up by exact username first, then fall back to verified email (case-insensitive).
    pub fn find_user_by_identifier(&self, identifier: &str) -> anyhow::Result<Option<UserRecord>> {
        let trimmed = identifier.trim();
        if let Some(u) = self.find_user_by_username(trimmed)? {
            return Ok(Some(u));
        }
        let norm = trimmed.to_ascii_lowercase();
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, username, password_hash, email, email_verified, disabled, created_at, token_version
             FROM users WHERE LOWER(email) = ?1 AND email_verified = 1",
            params![norm],
            Self::map_user_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn is_user_disabled_or_missing(&self, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let disabled: Option<i32> = conn
            .query_row(
                "SELECT disabled FROM users WHERE id = ?1",
                params![user_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(match disabled {
            None => true,
            Some(d) => d != 0,
        })
    }

    pub fn set_user_disabled(&self, user_id: &str, disabled: bool) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE users SET disabled = ?1 WHERE id = ?2",
            params![disabled as i32, user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn update_user_password(&self, user_id: &str, password_hash: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE users SET password_hash = ?1 WHERE id = ?2",
            params![password_hash, user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn user_has_google_link(&self, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM google_accounts WHERE user_id = ?1)",
            params![user_id],
            |row| row.get(0),
        )
        .map_err(Into::into)
    }

    pub fn set_user_verified_email(&self, user_id: &str, email: &str) -> anyhow::Result<bool> {
        let norm = email.trim().to_ascii_lowercase();
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE users SET email = ?1, email_verified = 1 WHERE id = ?2",
            params![norm, user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn delete_user(&self, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute("DELETE FROM users WHERE id = ?1", params![user_id])?;
        Ok(affected > 0)
    }

    // ---- Email Verification Codes ----

    pub fn last_email_verification_at(
        &self,
        email: &str,
        purpose: &str,
    ) -> anyhow::Result<Option<DateTime<Utc>>> {
        let norm = email.trim().to_ascii_lowercase();
        let conn = self.lock_conn();
        let raw: Option<String> = conn
            .query_row(
                "SELECT created_at FROM email_verifications
                 WHERE email = ?1 AND purpose = ?2
                 ORDER BY created_at DESC LIMIT 1",
                params![norm, purpose],
                |row| row.get(0),
            )
            .optional()?;
        Ok(raw.and_then(|s| {
            DateTime::parse_from_rfc3339(&s)
                .ok()
                .map(|d| d.with_timezone(&Utc))
        }))
    }

    pub fn create_email_verification(
        &self,
        email: &str,
        purpose: &str,
        code_hash: &str,
        expires_at: DateTime<Utc>,
    ) -> anyhow::Result<()> {
        let norm = email.trim().to_ascii_lowercase();
        let now = Utc::now();
        let id = uuid::Uuid::new_v4().to_string();
        let mut conn = self.lock_conn();
        let tx = conn.transaction()?;
        // Invalidate previous active codes for the same (email, purpose).
        tx.execute(
            "UPDATE email_verifications SET consumed = 1
             WHERE email = ?1 AND purpose = ?2 AND consumed = 0",
            params![norm, purpose],
        )?;
        tx.execute(
            "INSERT INTO email_verifications (id, email, purpose, code_hash, attempts, expires_at, consumed, created_at)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, 0, ?6)",
            params![
                id,
                norm,
                purpose,
                code_hash,
                expires_at.to_rfc3339(),
                now.to_rfc3339()
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Verify a 6-digit email verification code hash (max 5 attempts, 10-minute TTL).
    pub fn verify_and_consume_email_code(
        &self,
        email: &str,
        purpose: &str,
        code_hash: &str,
    ) -> anyhow::Result<bool> {
        const MAX_ATTEMPTS: i64 = 5;
        let norm = email.trim().to_ascii_lowercase();
        let mut conn = self.lock_conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let row: Option<(String, String, i64, String)> = tx
            .query_row(
                "SELECT id, code_hash, attempts, expires_at
                 FROM email_verifications
                 WHERE email = ?1 AND purpose = ?2 AND consumed = 0
                 ORDER BY created_at DESC LIMIT 1",
                params![norm, purpose],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let Some((id, stored_hash, attempts, expires_raw)) = row else {
            return Ok(false);
        };
        let expired = DateTime::parse_from_rfc3339(&expires_raw)
            .map(|d| d.with_timezone(&Utc) <= Utc::now())
            .unwrap_or(true);
        if expired || attempts >= MAX_ATTEMPTS {
            tx.execute(
                "UPDATE email_verifications SET consumed = 1 WHERE id = ?1",
                params![id],
            )?;
            tx.commit()?;
            return Ok(false);
        }
        let matches = stored_hash.len() == code_hash.len()
            && stored_hash
                .bytes()
                .zip(code_hash.bytes())
                .fold(0u8, |acc, (a, b)| acc | (a ^ b))
                == 0;
        if matches {
            tx.execute(
                "UPDATE email_verifications SET consumed = 1 WHERE id = ?1",
                params![id],
            )?;
            tx.commit()?;
            Ok(true)
        } else {
            let next_attempts = attempts + 1;
            tx.execute(
                "UPDATE email_verifications
                 SET attempts = ?1, consumed = CASE WHEN ?1 >= ?2 THEN 1 ELSE 0 END
                 WHERE id = ?3",
                params![next_attempts, MAX_ATTEMPTS, id],
            )?;
            tx.commit()?;
            Ok(false)
        }
    }

    pub fn upsert_device(
        &self,
        user_id: &str,
        device: &RegisterDeviceRequest,
    ) -> anyhow::Result<DeviceInfo> {
        let now = Utc::now();
        let app_version = device
            .app_version
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty());
        let platform_str = serde_json::to_string(&device.platform)?;
        let addrs_json = serde_json::to_string(&device.direct_addrs)?;
        let conn = self.lock_conn();
        let requested_id = device.device_id.as_deref().filter(|id| !id.is_empty());
        let iroh_node_id = device.iroh_node_id.as_deref().filter(|id| !id.is_empty());
        let requested_owner: Option<String> = if let Some(id) = requested_id {
            conn.query_row("SELECT user_id FROM devices WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .optional()?
        } else {
            None
        };
        let id = if let Some(id) =
            requested_id.filter(|_| requested_owner.as_deref() == Some(user_id))
        {
            id.to_owned()
        } else {
            let matching_device: Option<String> = if let Some(node_id) = iroh_node_id {
                conn.query_row(
                    "SELECT id FROM devices WHERE user_id = ?1 AND platform = ?2 AND iroh_node_id = ?3
                     ORDER BY last_seen_at DESC, id LIMIT 1",
                    params![user_id, platform_str, node_id],
                    |row| row.get(0),
                )
                .optional()?
            } else {
                None
            };
            matching_device
                .or_else(|| {
                    requested_id
                        .filter(|_| requested_owner.is_none())
                        .map(str::to_owned)
                })
                .unwrap_or_else(|| uuid::Uuid::new_v4().to_string())
        };
        conn.execute(
            "INSERT INTO devices (id, user_id, name, platform, iroh_node_id, iroh_relay_url, direct_addrs_json, last_seen_at, app_version)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 platform = excluded.platform,
                 iroh_node_id = COALESCE(excluded.iroh_node_id, devices.iroh_node_id),
                 iroh_relay_url = COALESCE(excluded.iroh_relay_url, devices.iroh_relay_url),
                 direct_addrs_json = excluded.direct_addrs_json,
                 last_seen_at = excluded.last_seen_at,
                 app_version = COALESCE(excluded.app_version, devices.app_version)
             WHERE devices.user_id = excluded.user_id",
            params![
                id,
                user_id,
                device.name,
                platform_str,
                iroh_node_id,
                device.iroh_relay_url,
                addrs_json,
                now.to_rfc3339(),
                app_version
            ],
        )?;
        conn.query_row(
            "SELECT id, user_id, name, platform, iroh_node_id, iroh_relay_url, direct_addrs_json, last_seen_at, app_version
             FROM devices WHERE id = ?1 AND user_id = ?2",
            params![id, user_id],
            Self::map_device_row,
        )
        .map_err(Into::into)
    }

    pub fn update_device_node_addr(
        &self,
        device_id: &str,
        user_id: &str,
        iroh_node_id: &str,
        iroh_relay_url: Option<&str>,
        direct_addrs: &[String],
    ) -> anyhow::Result<Option<DeviceInfo>> {
        let now = Utc::now();
        let addrs_json = serde_json::to_string(direct_addrs)?;
        let conn = self.lock_conn();
        conn.execute(
            "UPDATE devices SET iroh_node_id = ?1, iroh_relay_url = ?2, direct_addrs_json = ?3, last_seen_at = ?4
             WHERE id = ?5 AND user_id = ?6",
            params![
                iroh_node_id,
                iroh_relay_url,
                addrs_json,
                now.to_rfc3339(),
                device_id,
                user_id
            ],
        )?;
        drop(conn);
        self.get_device(device_id, user_id)
    }

    pub fn get_device(&self, device_id: &str, user_id: &str) -> anyhow::Result<Option<DeviceInfo>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, user_id, name, platform, iroh_node_id, iroh_relay_url, direct_addrs_json, last_seen_at, app_version
             FROM devices WHERE id = ?1 AND user_id = ?2",
            params![device_id, user_id],
            Self::map_device_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_devices(&self, user_id: &str) -> anyhow::Result<Vec<DeviceInfo>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, user_id, name, platform, iroh_node_id, iroh_relay_url, direct_addrs_json, last_seen_at, app_version
             FROM devices WHERE user_id = ?1 ORDER BY last_seen_at DESC",
        )?;
        let rows = stmt.query_map(params![user_id], Self::map_device_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    fn map_device_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceInfo> {
        let platform_str: String = row.get(3)?;
        let addrs_json: String = row.get(6)?;
        let last_seen: String = row.get(7)?;
        Ok(DeviceInfo {
            replica_items: Vec::new(),
            id: row.get(0)?,
            user_id: row.get(1)?,
            name: row.get(2)?,
            platform: serde_json::from_str(&platform_str).unwrap_or(DevicePlatform::Web),
            iroh_node_id: row.get(4)?,
            iroh_relay_url: row.get(5)?,
            direct_addrs: serde_json::from_str(&addrs_json).unwrap_or_default(),
            online: false,
            last_seen_at: DateTime::parse_from_rfc3339(&last_seen)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now()),
            app_version: row.get(8)?,
        })
    }

    // ---- Storage Backends ----

    pub fn create_storage_backend(
        &self,
        id: &str,
        user_id: &str,
        name: &str,
        config: &StorageBackendConfig,
        is_default: bool,
    ) -> anyhow::Result<StorageBackendRecord> {
        let now = Utc::now();
        let config_json = serde_json::to_string(config)?;
        let conn = self.lock_conn();
        if is_default {
            conn.execute(
                "UPDATE storage_backends SET is_default = 0 WHERE user_id = ?1",
                params![user_id],
            )?;
        }
        conn.execute(
            "INSERT INTO storage_backends (id, user_id, name, config_json, is_default, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, user_id, name, config_json, is_default as i32, now.to_rfc3339()],
        )?;
        Ok(StorageBackendRecord {
            id: id.to_string(),
            user_id: user_id.to_string(),
            name: name.to_string(),
            config: config.clone(),
            is_default,
            created_at: now,
        })
    }

    pub fn list_storage_backends(&self, user_id: &str) -> anyhow::Result<Vec<StorageBackendRecord>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, user_id, name, config_json, is_default, created_at
             FROM storage_backends WHERE user_id = ?1 ORDER BY is_default DESC, created_at DESC",
        )?;
        let rows = stmt.query_map(params![user_id], Self::map_backend_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn get_storage_backend(
        &self,
        backend_id: &str,
        user_id: &str,
    ) -> anyhow::Result<Option<StorageBackendRecord>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, user_id, name, config_json, is_default, created_at
             FROM storage_backends WHERE id = ?1 AND user_id = ?2",
            params![backend_id, user_id],
            Self::map_backend_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_default_storage_backend(
        &self,
        user_id: &str,
    ) -> anyhow::Result<Option<StorageBackendRecord>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, user_id, name, config_json, is_default, created_at
             FROM storage_backends WHERE user_id = ?1 ORDER BY is_default DESC, created_at ASC LIMIT 1",
            params![user_id],
            Self::map_backend_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn update_storage_backend(
        &self,
        backend_id: &str,
        user_id: &str,
        name: &str,
        patch: &serde_json::Map<String, serde_json::Value>,
    ) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE storage_backends SET name = ?3, config_json = json_patch(config_json, ?4)
             WHERE id = ?1 AND user_id = ?2",
            params![backend_id, user_id, name, serde_json::to_string(patch)?],
        )?;
        Ok(affected > 0)
    }

    pub fn set_default_storage_backend(&self, backend_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        // The same statement checks ownership and changes the default. A missing
        // or foreign ID cannot clear any of this account's existing settings.
        let affected = conn.execute(
            "UPDATE storage_backends SET is_default = (id = ?1)
             WHERE user_id = ?2 AND EXISTS (
                 SELECT 1 FROM storage_backends WHERE id = ?1 AND user_id = ?2
             )",
            params![backend_id, user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn delete_storage_backend(&self, backend_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "DELETE FROM storage_backends WHERE id = ?1 AND user_id = ?2",
            params![backend_id, user_id],
        )?;
        Ok(affected > 0)
    }

    fn map_backend_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StorageBackendRecord> {
        let cfg_json: String = row.get(3)?;
        let is_default: i32 = row.get(4)?;
        let created: String = row.get(5)?;
        let config: StorageBackendConfig = serde_json::from_str(&cfg_json).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e))
        })?;
        Ok(StorageBackendRecord {
            id: row.get(0)?,
            user_id: row.get(1)?,
            name: row.get(2)?,
            config,
            is_default: is_default != 0,
            created_at: DateTime::parse_from_rfc3339(&created)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now()),
        })
    }

    // ---- Drawer Items ----

    pub fn create_drawer_item(&self, item: &DrawerItemRow) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO drawer_items (
                 id, user_id, owner_device_id, kind, name, size, mime_type,
                 blake3_hash, text_content, thumbnail_base64, transfer_mode,
                 storage_backend_id, storage_path, cloud_ready, expires_at, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
            params![
                item.id,
                item.user_id,
                item.owner_device_id,
                serde_json::to_string(&item.kind)?,
                item.name,
                item.size as i64,
                item.mime_type,
                item.blake3_hash,
                item.text_content,
                item.thumbnail_base64,
                serde_json::to_string(&item.transfer_mode)?,
                item.storage_backend_id,
                item.storage_path,
                item.cloud_ready as i32,
                item.expires_at.map(|d| d.to_rfc3339()),
                item.created_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn mark_item_cloud_ready(
        &self,
        item_id: &str,
        user_id: &str,
        storage_backend_id: &str,
        storage_path: &str,
        size: Option<u64>,
        blake3_hash: Option<&str>,
    ) -> anyhow::Result<bool> {
        self.mark_item_cloud_ready_with_sha256(
            item_id,
            user_id,
            storage_backend_id,
            storage_path,
            size,
            blake3_hash,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn mark_item_cloud_ready_with_sha256(
        &self,
        item_id: &str,
        user_id: &str,
        storage_backend_id: &str,
        storage_path: &str,
        size: Option<u64>,
        blake3_hash: Option<&str>,
        content_sha256: Option<&str>,
    ) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE drawer_items
             SET storage_backend_id = ?1,
                 storage_path = ?2,
                 cloud_ready = 1,
                 transfer_mode = CASE WHEN transfer_mode = '\"p2p_only\"' THEN '\"hybrid\"' ELSE transfer_mode END,
                 size = COALESCE(?3, size),
                 blake3_hash = COALESCE(?4, blake3_hash),
                 content_sha256 = COALESCE(?5, content_sha256)
             WHERE id = ?6 AND user_id = ?7",
            params![
                storage_backend_id,
                storage_path,
                size.map(|s| s as i64),
                blake3_hash,
                content_sha256,
                item_id,
                user_id
            ],
        )?;
        Ok(affected > 0)
    }

    /// Find an existing cloud-ready storage path for the exact same user,
    /// storage backend, SHA-256 digest, and byte size.
    pub fn find_reusable_cloud_object(
        &self,
        user_id: &str,
        storage_backend_id: &str,
        content_sha256: &str,
        size: u64,
        exclude_item_id: &str,
    ) -> anyhow::Result<Option<String>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT storage_path FROM drawer_items
             WHERE user_id = ?1
               AND storage_backend_id = ?2
               AND content_sha256 = ?3
               AND size = ?4
               AND cloud_ready = 1
               AND storage_path IS NOT NULL
               AND storage_path != ''
               AND id != ?5
             ORDER BY created_at DESC
             LIMIT 1",
            params![
                user_id,
                storage_backend_id,
                content_sha256,
                size as i64,
                exclude_item_id,
            ],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Count other drawer items belonging to the same user that still point at
    /// the same `(storage_backend_id, storage_path)` blob.
    pub fn count_other_storage_refs(
        &self,
        user_id: &str,
        storage_backend_id: &str,
        storage_path: &str,
        exclude_item_id: &str,
    ) -> anyhow::Result<i64> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT COUNT(*) FROM drawer_items
             WHERE user_id = ?1
               AND storage_backend_id = ?2
               AND storage_path = ?3
               AND id != ?4",
            params![user_id, storage_backend_id, storage_path, exclude_item_id],
            |row| row.get::<_, i64>(0),
        )
        .map_err(Into::into)
    }

    /// Scope a session's complete files to this account. Only the original
    /// device can establish an item's canonical digest for replica downloads.
    pub fn ready_replicas(
        &self,
        user: &str,
        device: &str,
        files: &std::collections::BTreeMap<String, String>,
    ) -> anyhow::Result<std::collections::BTreeMap<String, String>> {
        let mut conn = self.lock_conn();
        let tx = conn.transaction()?;
        let mut replicas = std::collections::BTreeMap::new();
        {
            let mut catalog = tx.prepare("SELECT id, owner_device_id FROM drawer_items WHERE user_id = ?1")?;
            let mut rows = catalog.query([user])?;
            let mut set_hash = tx.prepare(
                "UPDATE drawer_items SET blake3_hash = ?1 WHERE id = ?2 AND user_id = ?3
                 AND (blake3_hash IS NULL OR blake3_hash = '')",
            )?;
            while let Some(row) = rows.next()? {
                let id: String = row.get(0)?;
                let Some(hash) = files.get(&id) else { continue };
                if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) { continue; }
                let source: String = row.get(1)?;
                if source == device {
                    set_hash.execute(params![hash, id, user])?;
                } else {
                    replicas.insert(id, hash.clone());
                }
            }
        }
        tx.commit()?;
        Ok(replicas)
    }

    pub fn get_drawer_item(
        &self,
        item_id: &str,
        user_id: &str,
    ) -> anyhow::Result<Option<DrawerItemRow>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, user_id, owner_device_id, kind, name, size, mime_type,
                    blake3_hash, text_content, thumbnail_base64, transfer_mode,
                    storage_backend_id, storage_path, cloud_ready, expires_at, created_at
             FROM drawer_items WHERE id = ?1 AND user_id = ?2",
            params![item_id, user_id],
            Self::map_item_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_drawer_items(&self, user_id: &str) -> anyhow::Result<Vec<DrawerItemRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, user_id, owner_device_id, kind, name, size, mime_type,
                    blake3_hash, text_content, thumbnail_base64, transfer_mode,
                    storage_backend_id, storage_path, cloud_ready, expires_at, created_at
             FROM drawer_items WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 200",
        )?;
        let rows = stmt.query_map(params![user_id], Self::map_item_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn delete_drawer_item(&self, item_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "DELETE FROM drawer_items WHERE id = ?1 AND user_id = ?2",
            params![item_id, user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn list_expired_items(&self, now: DateTime<Utc>) -> anyhow::Result<Vec<DrawerItemRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, user_id, owner_device_id, kind, name, size, mime_type,
                    blake3_hash, text_content, thumbnail_base64, transfer_mode,
                    storage_backend_id, storage_path, cloud_ready, expires_at, created_at
             FROM drawer_items WHERE expires_at IS NOT NULL AND expires_at <= ?1",
        )?;
        let rows = stmt.query_map(params![now.to_rfc3339()], Self::map_item_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    fn map_item_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DrawerItemRow> {
        let kind_str: String = row.get(3)?;
        let mode_str: String = row.get(10)?;
        let cloud_ready: i32 = row.get(13)?;
        let expires: Option<String> = row.get(14)?;
        let created: String = row.get(15)?;
        Ok(DrawerItemRow {
            id: row.get(0)?,
            user_id: row.get(1)?,
            owner_device_id: row.get(2)?,
            kind: serde_json::from_str(&kind_str).unwrap_or(DrawerItemKind::File),
            name: row.get(4)?,
            size: row.get::<_, i64>(5)?.max(0) as u64,
            mime_type: row.get(6)?,
            blake3_hash: row.get(7)?,
            text_content: row.get(8)?,
            thumbnail_base64: row.get(9)?,
            transfer_mode: serde_json::from_str(&mode_str).unwrap_or(TransferMode::P2pOnly),
            storage_backend_id: row.get(11)?,
            storage_path: row.get(12)?,
            cloud_ready: cloud_ready != 0,
            expires_at: expires.and_then(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .ok()
                    .map(|d| d.with_timezone(&Utc))
            }),
            created_at: DateTime::parse_from_rfc3339(&created)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now()),
        })
    }

    // ---- Share Links ----

    pub fn create_share_link(
        &self,
        row: &ShareLinkRow,
        item_ids: &[String],
    ) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO share_links (code, user_id, item_id, title, passcode_hash, max_downloads, download_count, expires_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                row.code,
                row.user_id,
                row.item_id,
                row.title,
                row.passcode_hash,
                row.max_downloads.map(|v| v as i64),
                row.download_count as i64,
                row.expires_at.map(|d| d.to_rfc3339()),
                row.created_at.to_rfc3339(),
            ],
        )?;
        for (idx, iid) in item_ids.iter().enumerate() {
            conn.execute(
                "INSERT OR IGNORE INTO share_link_items (share_code, item_id, position)
                 VALUES (?1, ?2, ?3)",
                params![row.code, iid, idx as i64],
            )?;
        }
        Ok(())
    }

    pub fn get_share_link(&self, code: &str) -> anyhow::Result<Option<ShareLinkRow>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT code, user_id, item_id, title, passcode_hash, max_downloads, download_count, expires_at, created_at
             FROM share_links WHERE code = ?1",
            params![code],
            Self::map_share_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn get_share_link_items(
        &self,
        code: &str,
        fallback_item_id: &str,
    ) -> anyhow::Result<Vec<DrawerItemRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT d.id, d.user_id, d.owner_device_id, d.kind, d.name, d.size, d.mime_type,
                    d.blake3_hash, d.text_content, d.thumbnail_base64, d.transfer_mode,
                    d.storage_backend_id, d.storage_path, d.cloud_ready, d.expires_at, d.created_at
             FROM share_link_items si
             JOIN drawer_items d ON d.id = si.item_id
             WHERE si.share_code = ?1
             ORDER BY si.position ASC",
        )?;
        let rows = stmt.query_map(params![code], Self::map_item_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        if !out.is_empty() {
            return Ok(out);
        }
        // Fallback for shares created prior to `share_link_items` table.
        if let Some(single) = conn
            .query_row(
                "SELECT id, user_id, owner_device_id, kind, name, size, mime_type,
                        blake3_hash, text_content, thumbnail_base64, transfer_mode,
                        storage_backend_id, storage_path, cloud_ready, expires_at, created_at
                 FROM drawer_items WHERE id = ?1",
                params![fallback_item_id],
                Self::map_item_row,
            )
            .optional()?
        {
            out.push(single);
        }
        Ok(out)
    }

    pub fn get_drawer_item_by_id(&self, item_id: &str) -> anyhow::Result<Option<DrawerItemRow>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT id, user_id, owner_device_id, kind, name, size, mime_type,
                    blake3_hash, text_content, thumbnail_base64, transfer_mode,
                    storage_backend_id, storage_path, cloud_ready, expires_at, created_at
             FROM drawer_items WHERE id = ?1",
            params![item_id],
            Self::map_item_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_share_links(&self, user_id: &str) -> anyhow::Result<Vec<ShareLinkRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT code, user_id, item_id, title, passcode_hash, max_downloads, download_count, expires_at, created_at
             FROM share_links WHERE user_id = ?1 ORDER BY created_at DESC LIMIT 100",
        )?;
        let rows = stmt.query_map(params![user_id], Self::map_share_row)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn increment_share_download(&self, code: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE share_links
             SET download_count = download_count + 1
             WHERE code = ?1 AND (max_downloads IS NULL OR download_count < max_downloads)",
            params![code],
        )?;
        Ok(affected > 0)
    }

    pub fn delete_share_link(&self, code: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "DELETE FROM share_links WHERE code = ?1 AND user_id = ?2",
            params![code, user_id],
        )?;
        Ok(affected > 0)
    }

    fn map_share_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ShareLinkRow> {
        let max_dl: Option<i64> = row.get(5)?;
        let dl_count: i64 = row.get(6)?;
        let expires: Option<String> = row.get(7)?;
        let created: String = row.get(8)?;
        Ok(ShareLinkRow {
            code: row.get(0)?,
            user_id: row.get(1)?,
            item_id: row.get(2)?,
            title: row.get(3)?,
            passcode_hash: row.get(4)?,
            max_downloads: max_dl.map(|v| v.max(0) as u64),
            download_count: dl_count.max(0) as u64,
            expires_at: expires.and_then(|s| {
                DateTime::parse_from_rfc3339(&s)
                    .ok()
                    .map(|d| d.with_timezone(&Utc))
            }),
            created_at: DateTime::parse_from_rfc3339(&created)
                .map(|d| d.with_timezone(&Utc))
                .unwrap_or_else(|_| Utc::now()),
        })
    }
}

impl StorageBackendRecord {
    pub fn to_summary(&self) -> StorageBackendSummary {
        let display_target = match &self.config {
            StorageBackendConfig::Local { root_dir, .. } => root_dir.clone(),
            StorageBackendConfig::GoogleDrive { folder_id, .. } => {
                format!("Google Drive (folder: {folder_id})")
            }
            StorageBackendConfig::Quark { root_folder_id, .. } => {
                tf!("夸克网盘 (fid: {root_folder_id})", "Quark Drive (fid: {root_folder_id})")
            }
            StorageBackendConfig::BaiduNetdisk { root_path, .. } => {
                tf!("百度网盘 ({root_path})", "Baidu Netdisk ({root_path})")
            }
            StorageBackendConfig::WebDav { base_url, .. } => base_url.clone(),
            StorageBackendConfig::S3 {
                endpoint,
                bucket,
                prefix,
                ..
            } => {
                if prefix.is_empty() {
                    format!("{}/{}", endpoint.trim_end_matches('/'), bucket)
                } else {
                    format!(
                        "{}/{}/{}",
                        endpoint.trim_end_matches('/'),
                        bucket,
                        prefix.trim_matches('/')
                    )
                }
            }
        };
        StorageBackendSummary {
            id: self.id.clone(),
            name: self.name.clone(),
            kind: self.config.kind(),
            is_default: self.is_default,
            created_at: self.created_at,
            display_target,
        }
    }
}

pub fn hydrate_drawer_item(
    row: &DrawerItemRow,
    devices: &[DeviceInfo],
    backends: &[StorageBackendRecord],
) -> DrawerItem {
    let device = devices.iter().find(|d| d.id == row.owner_device_id);
    let backend = row
        .storage_backend_id
        .as_ref()
        .and_then(|bid| backends.iter().find(|b| &b.id == bid));

    DrawerItem {
        id: row.id.clone(),
        user_id: row.user_id.clone(),
        owner_device_id: row.owner_device_id.clone(),
        owner_device_name: device.map(|d| d.name.clone()),
        owner_online: device.map(|d| d.online).unwrap_or(false),
        owner_iroh_node_id: device.and_then(|d| d.iroh_node_id.clone()),
        owner_iroh_relay_url: device.and_then(|d| d.iroh_relay_url.clone()),
        owner_direct_addrs: device.map(|d| d.direct_addrs.clone()).unwrap_or_default(),
        kind: row.kind,
        name: row.name.clone(),
        size: row.size,
        mime_type: row.mime_type.clone(),
        blake3_hash: row.blake3_hash.clone(),
        text_content: row.text_content.clone(),
        thumbnail_base64: row.thumbnail_base64.clone(),
        transfer_mode: row.transfer_mode,
        storage_backend_id: row.storage_backend_id.clone(),
        storage_backend_name: backend.map(|b| b.name.clone()),
        cloud_ready: row.cloud_ready,
        expires_at: row.expires_at,
        created_at: row.created_at,
    }
}

/// Parse a stored RFC 3339 timestamp, falling back to "now" for corrupt rows.
pub(crate) fn parse_ts(raw: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(raw)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now())
}

pub(crate) fn parse_opt_ts(raw: Option<String>) -> Option<DateTime<Utc>> {
    raw.and_then(|s| DateTime::parse_from_rfc3339(&s).ok().map(|d| d.with_timezone(&Utc)))
}
