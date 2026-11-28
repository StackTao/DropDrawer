//! Push notification tokens, one per device.

use chrono::Utc;
use protocol::PushProvider;
use rusqlite::{params, Connection};

use super::Database;

#[derive(Debug, Clone)]
pub struct PushTokenRecord {
    pub device_id: String,
    pub user_id: String,
    pub provider: PushProvider,
    pub token: String,
    pub sandbox: bool,
    /// Language of the device's app, for the notification text ("zh" / "en").
    pub language: String,
}

pub(super) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS device_push_tokens (
             device_id TEXT PRIMARY KEY,
             user_id TEXT NOT NULL,
             provider TEXT NOT NULL,
             token TEXT NOT NULL,
             sandbox INTEGER NOT NULL DEFAULT 0,
             language TEXT NOT NULL DEFAULT 'zh',
             updated_at TEXT NOT NULL,
             FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE,
             FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
         );
         CREATE UNIQUE INDEX IF NOT EXISTS idx_device_push_tokens_token
             ON device_push_tokens(provider, token);
         CREATE INDEX IF NOT EXISTS idx_device_push_tokens_user
             ON device_push_tokens(user_id);",
    )
}

fn provider_str(provider: PushProvider) -> &'static str {
    match provider {
        PushProvider::Apns => "apns",
        PushProvider::Fcm => "fcm",
    }
}

impl Database {
    /// Stores the token for a device the caller owns. A token can belong to one
    /// device only: when a phone signs in to another account, the old account
    /// stops receiving notifications on it.
    pub fn upsert_push_token(
        &self,
        device_id: &str,
        user_id: &str,
        provider: PushProvider,
        token: &str,
        sandbox: bool,
        language: &str,
    ) -> anyhow::Result<bool> {
        let mut conn = self.lock_conn();
        let tx = conn.transaction()?;
        let owned: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM devices WHERE id = ?1 AND user_id = ?2)",
            params![device_id, user_id],
            |row| row.get(0),
        )?;
        if !owned {
            return Ok(false);
        }
        tx.execute(
            "DELETE FROM device_push_tokens WHERE provider = ?1 AND token = ?2 AND device_id != ?3",
            params![provider_str(provider), token, device_id],
        )?;
        tx.execute(
            "INSERT INTO device_push_tokens (device_id, user_id, provider, token, sandbox, language, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(device_id) DO UPDATE SET
                 user_id = excluded.user_id, provider = excluded.provider, token = excluded.token,
                 sandbox = excluded.sandbox, language = excluded.language, updated_at = excluded.updated_at",
            params![
                device_id,
                user_id,
                provider_str(provider),
                token,
                sandbox as i32,
                language,
                Utc::now().to_rfc3339()
            ],
        )?;
        tx.commit()?;
        Ok(true)
    }

    pub fn delete_push_token(&self, device_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        Ok(conn.execute(
            "DELETE FROM device_push_tokens WHERE device_id = ?1 AND user_id = ?2",
            params![device_id, user_id],
        )? > 0)
    }

    pub(crate) fn is_current_push_token(&self, target: &PushTokenRecord) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        Ok(conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM device_push_tokens
                    WHERE device_id = ?1 AND user_id = ?2 AND provider = ?3 AND token = ?4 AND sandbox = ?5)",
            params![target.device_id, target.user_id, provider_str(target.provider), target.token, target.sandbox],
            |row| row.get(0),
        )?)
    }

    pub(crate) fn delete_push_token_if_current(&self, target: &PushTokenRecord) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "DELETE FROM device_push_tokens
             WHERE device_id = ?1 AND user_id = ?2 AND provider = ?3 AND token = ?4 AND sandbox = ?5",
            params![target.device_id, target.user_id, provider_str(target.provider), target.token, target.sandbox],
        )?;
        Ok(())
    }

    /// Signed-out devices stop receiving notifications too.
    pub fn delete_push_tokens_except(
        &self,
        user_id: &str,
        keep_device_id: Option<&str>,
    ) -> anyhow::Result<usize> {
        let conn = self.lock_conn();
        Ok(conn.execute(
            "DELETE FROM device_push_tokens WHERE user_id = ?1 AND (?2 IS NULL OR device_id != ?2)",
            params![user_id, keep_device_id],
        )?)
    }

    pub fn list_push_tokens(&self, user_id: &str) -> anyhow::Result<Vec<PushTokenRecord>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT device_id, user_id, provider, token, sandbox, language
             FROM device_push_tokens WHERE user_id = ?1",
        )?;
        let rows = stmt.query_map(params![user_id], |row| {
            let provider: String = row.get(2)?;
            Ok((
                provider,
                PushTokenRecord {
                    device_id: row.get(0)?,
                    user_id: row.get(1)?,
                    provider: PushProvider::Apns,
                    token: row.get(3)?,
                    sandbox: row.get::<_, i64>(4)? != 0,
                    language: row.get(5)?,
                },
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (provider, mut record) = row?;
            record.provider = match provider.as_str() {
                "apns" => PushProvider::Apns,
                "fcm" => PushProvider::Fcm,
                _ => continue,
            };
            out.push(record);
        }
        Ok(out)
    }
}
