//! Server-wide records that are not owned by a single user: runtime settings,
//! invite codes and the admin audit trail.

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;

use super::{parse_opt_ts, parse_ts, Database};

/// Keep the audit trail bounded; older rows are pruned on insert.
const AUDIT_LOG_MAX_ROWS: i64 = 5000;

#[derive(Debug, Clone, Serialize)]
pub struct InviteCodeRecord {
    pub code: String,
    pub note: Option<String>,
    pub max_uses: u32,
    pub used_count: u32,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AuditEntry {
    pub id: i64,
    pub at: DateTime<Utc>,
    pub actor: String,
    pub action: String,
    pub target: Option<String>,
    pub detail: Option<String>,
    pub ip: Option<String>,
}

pub(super) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS admin_audit_log (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             at TEXT NOT NULL,
             actor TEXT NOT NULL,
             action TEXT NOT NULL,
             target TEXT,
             detail TEXT,
             ip TEXT
         );",
    )
}

impl Database {
    // ---- System Settings ----

    pub fn get_setting(&self, key: &str) -> anyhow::Result<Option<String>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT value_json FROM system_settings WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn set_setting(&self, key: &str, value_json: &str) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO system_settings (key, value_json, updated_at)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at",
            params![key, value_json, Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    // ---- Invite Codes ----

    pub fn create_invite_code(
        &self,
        code: &str,
        note: Option<&str>,
        max_uses: u32,
        expires_at: Option<DateTime<Utc>>,
    ) -> anyhow::Result<InviteCodeRecord> {
        let now = Utc::now();
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO invite_codes (code, note, max_uses, used_count, expires_at, created_at)
             VALUES (?1, ?2, ?3, 0, ?4, ?5)",
            params![
                code,
                note,
                max_uses as i64,
                expires_at.map(|d| d.to_rfc3339()),
                now.to_rfc3339()
            ],
        )?;
        Ok(InviteCodeRecord {
            code: code.to_string(),
            note: note.map(str::to_string),
            max_uses,
            used_count: 0,
            expires_at,
            created_at: now,
        })
    }

    pub fn list_invite_codes(&self) -> anyhow::Result<Vec<InviteCodeRecord>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT code, note, max_uses, used_count, expires_at, created_at
             FROM invite_codes ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map([], |row| {
            let created: String = row.get(5)?;
            Ok(InviteCodeRecord {
                code: row.get(0)?,
                note: row.get(1)?,
                max_uses: row.get::<_, i64>(2)?.max(1) as u32,
                used_count: row.get::<_, i64>(3)?.max(0) as u32,
                expires_at: parse_opt_ts(row.get(4)?),
                created_at: parse_ts(&created),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn delete_invite_code(&self, code: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "DELETE FROM invite_codes WHERE UPPER(code) = UPPER(?1)",
            params![code.trim()],
        )?;
        Ok(affected > 0)
    }

    pub fn is_invite_code_valid(&self, code: &str) -> anyhow::Result<bool> {
        let trimmed = code.trim();
        if trimmed.is_empty() {
            return Ok(false);
        }
        let conn = self.lock_conn();
        let rec: Option<(i64, i64, Option<String>)> = conn
            .query_row(
                "SELECT max_uses, used_count, expires_at FROM invite_codes WHERE UPPER(code) = UPPER(?1)",
                params![trimmed],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let Some((max_uses, used_count, expires_raw)) = rec else {
            return Ok(false);
        };
        if used_count >= max_uses {
            return Ok(false);
        }
        if let Some(exp_str) = expires_raw
            && let Ok(exp) = DateTime::parse_from_rfc3339(&exp_str)
            && exp.with_timezone(&Utc) <= Utc::now()
        {
            return Ok(false);
        }
        Ok(true)
    }

    /// Atomically verify and increment `used_count` for an invite code.
    pub fn consume_invite_code(&self, code: &str) -> anyhow::Result<bool> {
        let trimmed = code.trim();
        if trimmed.is_empty() {
            return Ok(false);
        }
        let mut conn = self.lock_conn();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let rec: Option<(String, i64, i64, Option<String>)> = tx
            .query_row(
                "SELECT code, max_uses, used_count, expires_at FROM invite_codes WHERE UPPER(code) = UPPER(?1)",
                params![trimmed],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((exact_code, max_uses, used_count, expires_raw)) = rec else {
            return Ok(false);
        };
        if used_count >= max_uses {
            return Ok(false);
        }
        if let Some(exp_str) = expires_raw
            && let Ok(exp) = DateTime::parse_from_rfc3339(&exp_str)
            && exp.with_timezone(&Utc) <= Utc::now()
        {
            return Ok(false);
        }
        tx.execute(
            "UPDATE invite_codes SET used_count = used_count + 1 WHERE code = ?1",
            params![exact_code],
        )?;
        tx.commit()?;
        Ok(true)
    }

    // ---- Audit Log ----

    pub fn record_audit(
        &self,
        actor: &str,
        action: &str,
        target: Option<&str>,
        detail: Option<&str>,
        ip: Option<&str>,
    ) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "INSERT INTO admin_audit_log (at, actor, action, target, detail, ip)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![Utc::now().to_rfc3339(), actor, action, target, detail, ip],
        )?;
        let last_id = conn.last_insert_rowid();
        conn.execute(
            "DELETE FROM admin_audit_log WHERE id <= ?1",
            params![last_id - AUDIT_LOG_MAX_ROWS],
        )?;
        Ok(())
    }

    pub fn list_audit(&self, limit: u32) -> anyhow::Result<Vec<AuditEntry>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, at, actor, action, target, detail, ip
             FROM admin_audit_log ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit.clamp(1, 1000)], |row| {
            let at: String = row.get(1)?;
            Ok(AuditEntry {
                id: row.get(0)?,
                at: parse_ts(&at),
                actor: row.get(2)?,
                action: row.get(3)?,
                target: row.get(4)?,
                detail: row.get(5)?,
                ip: row.get(6)?,
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    /// Size of the SQLite database file (pages in use × page size).
    pub fn database_size_bytes(&self) -> anyhow::Result<u64> {
        let conn = self.lock_conn();
        let pages: i64 = conn.query_row("PRAGMA page_count", [], |r| r.get(0))?;
        let size: i64 = conn.query_row("PRAGMA page_size", [], |r| r.get(0))?;
        Ok((pages.max(0) * size.max(0)) as u64)
    }
}
