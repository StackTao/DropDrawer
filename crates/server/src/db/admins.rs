//! Named administrator accounts (in addition to the `DROPDRAWER_ADMIN_TOKEN` owner login).

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use super::{parse_opt_ts, parse_ts, Database};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdminRole {
    /// Everything, including administrator accounts and database backups.
    Super,
    /// Settings and user governance.
    Admin,
    /// Read-only access.
    Viewer,
}

impl AdminRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Super => "super",
            Self::Admin => "admin",
            Self::Viewer => "viewer",
        }
    }

    fn parse(raw: &str) -> Self {
        match raw {
            "super" => Self::Super,
            "admin" => Self::Admin,
            _ => Self::Viewer,
        }
    }
}

#[derive(Debug, Clone)]
pub struct AdminAccount {
    pub id: String,
    pub username: String,
    pub password_hash: String,
    pub role: AdminRole,
    pub totp_secret: Option<String>,
    pub totp_enabled: bool,
    pub totp_last_step: i64,
    pub disabled: bool,
    pub token_version: u64,
    pub created_at: DateTime<Utc>,
    pub last_login_at: Option<DateTime<Utc>>,
}

/// Account as listed in the console (no secrets).
#[derive(Debug, Clone, Serialize)]
pub struct AdminAccountSummary {
    pub id: String,
    pub username: String,
    pub role: AdminRole,
    pub totp_enabled: bool,
    pub disabled: bool,
    pub created_at: DateTime<Utc>,
    pub last_login_at: Option<DateTime<Utc>>,
}

impl From<&AdminAccount> for AdminAccountSummary {
    fn from(a: &AdminAccount) -> Self {
        Self {
            id: a.id.clone(),
            username: a.username.clone(),
            role: a.role,
            totp_enabled: a.totp_enabled,
            disabled: a.disabled,
            created_at: a.created_at,
            last_login_at: a.last_login_at,
        }
    }
}

pub(super) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS admin_accounts (
             id TEXT PRIMARY KEY,
             username TEXT NOT NULL UNIQUE COLLATE NOCASE,
             password_hash TEXT NOT NULL,
             role TEXT NOT NULL,
             totp_secret TEXT,
             totp_enabled INTEGER NOT NULL DEFAULT 0,
             totp_last_step INTEGER NOT NULL DEFAULT 0,
             disabled INTEGER NOT NULL DEFAULT 0,
             token_version INTEGER NOT NULL DEFAULT 0,
             created_at TEXT NOT NULL,
             last_login_at TEXT
         );
         CREATE TABLE IF NOT EXISTS admin_google_identities (
             account_id TEXT PRIMARY KEY REFERENCES admin_accounts(id) ON DELETE CASCADE,
             subject TEXT NOT NULL UNIQUE
         );",
    )
}

const ACCOUNT_COLUMNS: &str = "id, username, password_hash, role, totp_secret, totp_enabled, \
     totp_last_step, disabled, token_version, created_at, last_login_at";

fn map_account(
    secrets: &crate::secret_box::SecretBox,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<AdminAccount> {
    let id: String = row.get(0)?;
    let role: String = row.get(3)?;
    let totp_secret = row
        .get::<_, Option<String>>(4)?
        .map(|stored| secrets.open(&super::totp_context(&id), &stored))
        .transpose()
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, e.into())
        })?;
    let created: String = row.get(9)?;
    Ok(AdminAccount {
        id,
        username: row.get(1)?,
        password_hash: row.get(2)?,
        role: AdminRole::parse(&role),
        totp_secret,
        totp_enabled: row.get::<_, i64>(5)? != 0,
        totp_last_step: row.get(6)?,
        disabled: row.get::<_, i64>(7)? != 0,
        token_version: row.get::<_, i64>(8)?.max(0) as u64,
        created_at: parse_ts(&created),
        last_login_at: parse_opt_ts(row.get(10)?),
    })
}

impl Database {
    pub fn create_admin_account(
        &self,
        id: &str,
        username: &str,
        password_hash: &str,
        role: AdminRole,
    ) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO admin_accounts (id, username, password_hash, role, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, username, password_hash, role.as_str(), Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub fn list_admin_accounts(&self) -> anyhow::Result<Vec<AdminAccount>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {ACCOUNT_COLUMNS} FROM admin_accounts ORDER BY created_at"
        ))?;
        let rows = stmt.query_map([], |row| map_account(self.secrets(), row))?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn get_admin_account(&self, id: &str) -> anyhow::Result<Option<AdminAccount>> {
        let conn = self.lock_conn();
        conn.query_row(
            &format!("SELECT {ACCOUNT_COLUMNS} FROM admin_accounts WHERE id = ?1"),
            params![id],
            |row| map_account(self.secrets(), row),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn find_admin_account(&self, username: &str) -> anyhow::Result<Option<AdminAccount>> {
        let conn = self.lock_conn();
        conn.query_row(
            &format!("SELECT {ACCOUNT_COLUMNS} FROM admin_accounts WHERE username = ?1"),
            params![username.trim()],
            |row| map_account(self.secrets(), row),
        )
        .optional()
        .map_err(Into::into)
    }

    /// Pin a verified Google subject to a provisioned account, or match its
    /// existing binding. The unique constraints cover concurrent first logins.
    pub(crate) fn bind_admin_google_identity(&self, account_id: &str, subject: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT OR IGNORE INTO admin_google_identities (account_id, subject)
             SELECT id, ?2 FROM admin_accounts WHERE id = ?1 AND disabled = 0",
            params![account_id, subject],
        )?;
        conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM admin_google_identities
             WHERE account_id = ?1 AND subject = ?2)",
            params![account_id, subject],
            |r| r.get(0),
        ).map_err(Into::into)
    }

    pub fn update_admin_account(
        &self,
        id: &str,
        role: AdminRole,
        disabled: bool,
    ) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE admin_accounts SET role = ?1, disabled = ?2, token_version = token_version + 1
             WHERE id = ?3",
            params![role.as_str(), disabled as i32, id],
        )?;
        Ok(affected > 0)
    }

    /// Set a new password and end every session of the account.
    pub fn set_admin_password(&self, id: &str, password_hash: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE admin_accounts SET password_hash = ?1, token_version = token_version + 1 WHERE id = ?2",
            params![password_hash, id],
        )?;
        Ok(affected > 0)
    }

    pub fn bump_admin_token_version(&self, id: &str) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "UPDATE admin_accounts SET token_version = token_version + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// Store a not-yet-confirmed TOTP secret (enrollment in progress).
    pub fn set_admin_totp_pending(&self, id: &str, secret: &str) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "UPDATE admin_accounts SET totp_secret = ?1, totp_enabled = 0 WHERE id = ?2",
            params![self.secrets().seal(&super::totp_context(id), secret), id],
        )?;
        Ok(())
    }

    pub fn set_admin_totp_enabled(&self, id: &str, enabled: bool) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        if enabled {
            conn.execute(
                "UPDATE admin_accounts SET totp_enabled = 1 WHERE id = ?1 AND totp_secret IS NOT NULL",
                params![id],
            )?;
        } else {
            conn.execute(
                "UPDATE admin_accounts SET totp_enabled = 0, totp_secret = NULL, totp_last_step = 0 WHERE id = ?1",
                params![id],
            )?;
        }
        Ok(())
    }

    /// Record a consumed TOTP step; `false` if it (or a later one) was already used.
    pub fn consume_admin_totp_step(&self, id: &str, step: i64) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE admin_accounts SET totp_last_step = ?1 WHERE id = ?2 AND totp_last_step < ?1",
            params![step, id],
        )?;
        Ok(affected > 0)
    }

    pub fn touch_admin_login(&self, id: &str) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "UPDATE admin_accounts SET last_login_at = ?1 WHERE id = ?2",
            params![Utc::now().to_rfc3339(), id],
        )?;
        Ok(())
    }

    pub fn delete_admin_account(&self, id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        Ok(conn.execute("DELETE FROM admin_accounts WHERE id = ?1", params![id])? > 0)
    }

    /// Write a consistent copy of the whole database to `dest` (`VACUUM INTO`).
    pub fn backup_to(&self, dest: &std::path::Path) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute("VACUUM INTO ?1", params![dest.to_string_lossy()])?;
        Ok(())
    }
}
