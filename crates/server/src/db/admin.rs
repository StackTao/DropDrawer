//! Queries backing the `/admin` console: cross-user statistics, moderation,
//! per-user policy overrides and session revocation.

use chrono::{DateTime, Utc};
use protocol::{DevicePlatform, StorageBackendKind, TransferMode};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use super::{parse_opt_ts, parse_ts, Database};

#[derive(Debug, Clone, Serialize)]
pub struct AdminUserSummary {
    pub id: String,
    pub username: String,
    pub email: Option<String>,
    pub email_verified: bool,
    pub disabled: bool,
    pub google_linked: bool,
    pub device_count: i64,
    pub item_count: i64,
    pub storage_bytes: i64,
    pub share_count: i64,
    pub backend_count: i64,
    pub upload_blocked: bool,
    pub share_blocked: bool,
    pub local_quota_bytes: Option<u64>,
    pub note: Option<String>,
    pub last_login_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    /// Filled in by the handler from live WebSocket connections.
    pub online_devices: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdminOverviewStats {
    pub total_users: i64,
    pub disabled_users: i64,
    pub new_users_7d: i64,
    pub total_devices: i64,
    pub total_items: i64,
    pub total_item_bytes: i64,
    pub cloud_item_bytes: i64,
    pub items_expiring_24h: i64,
    pub total_shares: i64,
    pub total_share_downloads: i64,
    pub total_backends: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdminBackendKindCount {
    pub kind: StorageBackendKind,
    pub count: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdminShareRow {
    pub code: String,
    pub owner_id: String,
    pub owner_username: String,
    pub item_name: String,
    pub item_size: u64,
    /// Files in the share (batch shares hold several).
    pub item_count: u64,
    pub has_passcode: bool,
    pub max_downloads: Option<u64>,
    pub download_count: u64,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdminDeviceRow {
    pub id: String,
    pub name: String,
    pub platform: DevicePlatform,
    pub online: bool,
    pub has_p2p: bool,
    pub app_version: Option<String>,
    pub last_seen_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AdminVersionCount {
    pub platform: String,
    /// `None` for clients too old to report their version.
    pub version: Option<String>,
    pub devices: i64,
    /// Devices seen during the last 30 days.
    pub active_devices: i64,
}

/// Drawer item metadata for moderation. Text content and thumbnails are deliberately left out.
#[derive(Debug, Clone, Serialize)]
pub struct AdminItemRow {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub size: u64,
    pub transfer_mode: TransferMode,
    pub cloud_ready: bool,
    pub storage_backend_id: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Per-user overrides set by an administrator.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserPolicy {
    /// Server-local storage ceiling for this user; `None` falls back to the server default.
    #[serde(default)]
    pub local_quota_bytes: Option<u64>,
    #[serde(default)]
    pub upload_blocked: bool,
    #[serde(default)]
    pub share_blocked: bool,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct UserAuthState {
    pub disabled: bool,
    pub token_version: u64,
}

pub(super) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    // Idempotent: ALTER fails harmlessly once the column exists.
    for ddl in [
        "ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN local_quota_bytes INTEGER",
        "ALTER TABLE users ADD COLUMN upload_blocked INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN share_blocked INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN admin_note TEXT",
        "ALTER TABLE users ADD COLUMN last_login_at TEXT",
        "ALTER TABLE devices ADD COLUMN app_version TEXT",
    ] {
        let _ = conn.execute(ddl, []);
    }
    // Devices removed by an administrator. A session issued before the removal may
    // not re-register the same device (by id or iroh node); signing in again may.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS removed_devices (
             user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
             device_id TEXT NOT NULL,
             iroh_node_id TEXT,
             removed_at TEXT NOT NULL,
             PRIMARY KEY (user_id, device_id)
         );",
    )
}

const USER_SUMMARY_SELECT: &str = "SELECT
     u.id,
     u.username,
     u.email,
     u.email_verified,
     u.disabled,
     EXISTS(SELECT 1 FROM google_accounts g WHERE g.user_id = u.id),
     (SELECT COUNT(*) FROM devices d WHERE d.user_id = u.id),
     (SELECT COUNT(*) FROM drawer_items i WHERE i.user_id = u.id),
     (SELECT COALESCE(SUM(i.size), 0) FROM drawer_items i WHERE i.user_id = u.id AND i.cloud_ready = 1),
     (SELECT COUNT(*) FROM share_links s WHERE s.user_id = u.id),
     (SELECT COUNT(*) FROM storage_backends b WHERE b.user_id = u.id),
     u.upload_blocked,
     u.share_blocked,
     u.local_quota_bytes,
     u.admin_note,
     u.last_login_at,
     u.created_at
 FROM users u";

fn map_user_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<AdminUserSummary> {
    let flag = |idx: usize| -> rusqlite::Result<bool> { Ok(row.get::<_, i64>(idx)? != 0) };
    let created: String = row.get(16)?;
    Ok(AdminUserSummary {
        id: row.get(0)?,
        username: row.get(1)?,
        email: row.get(2)?,
        email_verified: flag(3)?,
        disabled: flag(4)?,
        google_linked: flag(5)?,
        device_count: row.get(6)?,
        item_count: row.get(7)?,
        storage_bytes: row.get(8)?,
        share_count: row.get(9)?,
        backend_count: row.get(10)?,
        upload_blocked: flag(11)?,
        share_blocked: flag(12)?,
        local_quota_bytes: row.get::<_, Option<i64>>(13)?.filter(|&v| v > 0).map(|v| v as u64),
        note: row.get(14)?,
        last_login_at: parse_opt_ts(row.get(15)?),
        created_at: parse_ts(&created),
        online_devices: 0,
    })
}

impl Database {
    pub fn admin_overview_stats(&self) -> anyhow::Result<AdminOverviewStats> {
        let conn = self.lock_conn();
        let count = |sql: &str| -> rusqlite::Result<i64> { conn.query_row(sql, [], |r| r.get(0)) };
        let week_ago = (Utc::now() - chrono::Duration::days(7)).to_rfc3339();
        let tomorrow = (Utc::now() + chrono::Duration::hours(24)).to_rfc3339();
        let (total_items, total_item_bytes, cloud_item_bytes): (i64, i64, i64) = conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(size), 0),
                    COALESCE(SUM(CASE WHEN cloud_ready = 1 THEN size ELSE 0 END), 0)
             FROM drawer_items",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        let (total_shares, total_share_downloads): (i64, i64) = conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(download_count), 0) FROM share_links",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(AdminOverviewStats {
            total_users: count("SELECT COUNT(*) FROM users")?,
            disabled_users: count("SELECT COUNT(*) FROM users WHERE disabled != 0")?,
            new_users_7d: conn.query_row(
                "SELECT COUNT(*) FROM users WHERE created_at >= ?1",
                params![week_ago],
                |r| r.get(0),
            )?,
            total_devices: count("SELECT COUNT(*) FROM devices")?,
            total_items,
            total_item_bytes,
            cloud_item_bytes,
            items_expiring_24h: conn.query_row(
                "SELECT COUNT(*) FROM drawer_items WHERE expires_at IS NOT NULL AND expires_at <= ?1",
                params![tomorrow],
                |r| r.get(0),
            )?,
            total_shares,
            total_share_downloads,
            total_backends: count("SELECT COUNT(*) FROM storage_backends")?,
        })
    }

    pub fn backend_kind_counts(&self) -> anyhow::Result<Vec<AdminBackendKindCount>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT kind, COUNT(*)
             FROM storage_backends GROUP BY kind ORDER BY COUNT(*) DESC",
        )?;
        let rows = stmt.query_map([], |row| {
            let kind: Option<String> = row.get(0)?;
            Ok((kind, row.get::<_, i64>(1)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (kind, count) = row?;
            let parsed = kind.and_then(|k| serde_json::from_value(serde_json::Value::String(k)).ok());
            if let Some(kind) = parsed {
                out.push(AdminBackendKindCount { kind, count });
            }
        }
        Ok(out)
    }

    pub fn list_users_admin_summary(&self) -> anyhow::Result<Vec<AdminUserSummary>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(&format!("{USER_SUMMARY_SELECT} ORDER BY u.created_at DESC"))?;
        let rows = stmt.query_map([], map_user_summary)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn admin_user_summary(&self, user_id: &str) -> anyhow::Result<Option<AdminUserSummary>> {
        let conn = self.lock_conn();
        conn.query_row(
            &format!("{USER_SUMMARY_SELECT} WHERE u.id = ?1"),
            params![user_id],
            map_user_summary,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_items_admin(&self, user_id: &str, limit: u32) -> anyhow::Result<Vec<AdminItemRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT id, kind, name, size, transfer_mode, cloud_ready, storage_backend_id, expires_at, created_at
             FROM drawer_items WHERE user_id = ?1 ORDER BY created_at DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![user_id, limit], |row| {
            let kind: String = row.get(1)?;
            let mode: String = row.get(4)?;
            let created: String = row.get(8)?;
            Ok(AdminItemRow {
                id: row.get(0)?,
                kind: serde_json::from_str(&kind).unwrap_or(kind),
                name: row.get(2)?,
                size: row.get::<_, i64>(3)?.max(0) as u64,
                transfer_mode: serde_json::from_str(&mode).unwrap_or(TransferMode::P2pOnly),
                cloud_ready: row.get::<_, i64>(5)? != 0,
                storage_backend_id: row.get(6)?,
                expires_at: parse_opt_ts(row.get(7)?),
                created_at: parse_ts(&created),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn list_all_share_links_admin(&self) -> anyhow::Result<Vec<AdminShareRow>> {
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT
                 s.code,
                 s.user_id,
                 u.username,
                 COALESCE(NULLIF(s.title, ''), i.name, ''),
                 COALESCE(i.size, 0),
                 s.passcode_hash IS NOT NULL,
                 s.max_downloads,
                 s.download_count,
                 s.expires_at,
                 s.created_at,
                 bundle.n,
                 bundle.total
             FROM share_links s
             LEFT JOIN (
                 SELECT si.share_code AS code, COUNT(*) AS n, SUM(di.size) AS total
                 FROM share_link_items si
                 JOIN drawer_items di ON di.id = si.item_id
                 GROUP BY si.share_code
             ) bundle ON bundle.code = s.code
             JOIN users u ON u.id = s.user_id
             LEFT JOIN drawer_items i ON i.id = s.item_id
             ORDER BY s.created_at DESC
             LIMIT 1000",
        )?;
        let rows = stmt.query_map([], |row| {
            let created: String = row.get(9)?;
            // Shares made before `share_link_items` existed hold just their primary item.
            let bundle_count = row.get::<_, Option<i64>>(10)?.unwrap_or(0).max(0) as u64;
            let primary_size = row.get::<_, i64>(4)?.max(0) as u64;
            let item_name: String = row.get(3)?;
            Ok(AdminShareRow {
                code: row.get(0)?,
                owner_id: row.get(1)?,
                owner_username: row.get(2)?,
                item_count: if bundle_count > 0 { bundle_count } else if item_name.is_empty() { 0 } else { 1 },
                item_name,
                item_size: if bundle_count > 0 {
                    row.get::<_, Option<i64>>(11)?.unwrap_or(0).max(0) as u64
                } else {
                    primary_size
                },
                has_passcode: row.get::<_, i64>(5)? != 0,
                max_downloads: row.get::<_, Option<i64>>(6)?.map(|v| v.max(0) as u64),
                download_count: row.get::<_, i64>(7)?.max(0) as u64,
                expires_at: parse_opt_ts(row.get(8)?),
                created_at: parse_ts(&created),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn delete_share_link_admin(&self, code: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute("DELETE FROM share_links WHERE code = ?1", params![code])?;
        Ok(affected > 0)
    }

    pub fn delete_share_links_for_user(&self, user_id: &str) -> anyhow::Result<usize> {
        let conn = self.lock_conn();
        Ok(conn.execute("DELETE FROM share_links WHERE user_id = ?1", params![user_id])?)
    }

    // ---- Per-user policy & sessions ----

    pub fn user_policy(&self, user_id: &str) -> anyhow::Result<UserPolicy> {
        let conn = self.lock_conn();
        let policy = conn
            .query_row(
                "SELECT local_quota_bytes, upload_blocked, share_blocked, admin_note FROM users WHERE id = ?1",
                params![user_id],
                |row| {
                    Ok(UserPolicy {
                        local_quota_bytes: row
                            .get::<_, Option<i64>>(0)?
                            .filter(|&v| v > 0)
                            .map(|v| v as u64),
                        upload_blocked: row.get::<_, i64>(1)? != 0,
                        share_blocked: row.get::<_, i64>(2)? != 0,
                        note: row.get(3)?,
                    })
                },
            )
            .optional()?;
        Ok(policy.unwrap_or_default())
    }

    pub fn set_user_policy(&self, user_id: &str, policy: &UserPolicy) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let note = policy
            .note
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let affected = conn.execute(
            "UPDATE users SET local_quota_bytes = ?1, upload_blocked = ?2, share_blocked = ?3, admin_note = ?4
             WHERE id = ?5",
            params![
                policy.local_quota_bytes.filter(|&v| v > 0).map(|v| v as i64),
                policy.upload_blocked as i32,
                policy.share_blocked as i32,
                note,
                user_id
            ],
        )?;
        Ok(affected > 0)
    }

    /// `None` when the user no longer exists.
    pub fn user_auth_state(&self, user_id: &str) -> anyhow::Result<Option<UserAuthState>> {
        let conn = self.lock_conn();
        conn.query_row(
            "SELECT disabled, token_version FROM users WHERE id = ?1",
            params![user_id],
            |row| {
                Ok(UserAuthState {
                    disabled: row.get::<_, i64>(0)? != 0,
                    token_version: row.get::<_, i64>(1)?.max(0) as u64,
                })
            },
        )
        .optional()
        .map_err(Into::into)
    }

    /// Invalidate every token issued so far. Returns `false` when the user does not exist.
    pub fn bump_token_version(&self, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "UPDATE users SET token_version = token_version + 1 WHERE id = ?1",
            params![user_id],
        )?;
        Ok(affected > 0)
    }

    pub fn touch_last_login(&self, user_id: &str) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "UPDATE users SET last_login_at = ?1 WHERE id = ?2",
            params![Utc::now().to_rfc3339(), user_id],
        )?;
        Ok(())
    }

    // ---- Devices & items ----

    pub fn count_devices(&self, user_id: &str) -> anyhow::Result<u64> {
        let conn = self.lock_conn();
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM devices WHERE user_id = ?1",
            params![user_id],
            |r| r.get(0),
        )?;
        Ok(n.max(0) as u64)
    }

    pub fn count_drawer_items(&self, user_id: &str) -> anyhow::Result<u64> {
        let conn = self.lock_conn();
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM drawer_items WHERE user_id = ?1",
            params![user_id],
            |r| r.get(0),
        )?;
        Ok(n.max(0) as u64)
    }

    /// Whether `upsert_device` would create a new row rather than update an existing device.
    /// Mirrors the matching rules used there (own device id, then same platform + iroh node).
    pub fn device_would_be_new(
        &self,
        requested_id: Option<&str>,
        user_id: &str,
        platform: DevicePlatform,
        iroh_node_id: Option<&str>,
    ) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        if let Some(id) = requested_id.filter(|id| !id.is_empty()) {
            let owned: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM devices WHERE id = ?1 AND user_id = ?2)",
                params![id, user_id],
                |r| r.get(0),
            )?;
            if owned {
                return Ok(false);
            }
        }
        if let Some(node_id) = iroh_node_id.filter(|id| !id.is_empty()) {
            let platform_str = serde_json::to_string(&platform)?;
            let matched: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM devices WHERE user_id = ?1 AND platform = ?2 AND iroh_node_id = ?3)",
                params![user_id, platform_str, node_id],
                |r| r.get(0),
            )?;
            if matched {
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// Remove a device and remember the removal so stale sessions cannot bring it back.
    pub fn remove_device_by_admin(&self, device_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let mut conn = self.lock_conn();
        let tx = conn.transaction()?;
        let node: Option<Option<String>> = tx
            .query_row(
                "SELECT iroh_node_id FROM devices WHERE id = ?1 AND user_id = ?2",
                params![device_id, user_id],
                |r| r.get(0),
            )
            .optional()?;
        let Some(node) = node else {
            return Ok(false);
        };
        tx.execute(
            "INSERT INTO removed_devices (user_id, device_id, iroh_node_id, removed_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(user_id, device_id) DO UPDATE SET
                 iroh_node_id = excluded.iroh_node_id, removed_at = excluded.removed_at",
            params![user_id, device_id, node, Utc::now().to_rfc3339()],
        )?;
        tx.execute(
            "DELETE FROM devices WHERE id = ?1 AND user_id = ?2",
            params![device_id, user_id],
        )?;
        tx.commit()?;
        Ok(true)
    }

    /// Whether a session issued at `issued_at` is barred from registering this device.
    pub fn device_removed_after(
        &self,
        user_id: &str,
        device_id: Option<&str>,
        iroh_node_id: Option<&str>,
        issued_at: DateTime<Utc>,
    ) -> anyhow::Result<bool> {
        let device_id = device_id.filter(|v| !v.is_empty());
        let iroh_node_id = iroh_node_id.filter(|v| !v.is_empty());
        if device_id.is_none() && iroh_node_id.is_none() {
            return Ok(false);
        }
        let conn = self.lock_conn();
        let mut stmt = conn.prepare(
            "SELECT removed_at FROM removed_devices
             WHERE user_id = ?1 AND ((?2 IS NOT NULL AND device_id = ?2) OR (?3 IS NOT NULL AND iroh_node_id = ?3))",
        )?;
        let rows = stmt.query_map(params![user_id, device_id, iroh_node_id], |r| r.get::<_, String>(0))?;
        for raw in rows {
            // Whole seconds: token `iat` has second precision, so a sign-in in the
            // same second as the removal counts as a fresh session.
            if parse_ts(&raw?).timestamp() > issued_at.timestamp() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Forget removals for this device once a fresh session registers it again.
    pub fn clear_device_removal(
        &self,
        user_id: &str,
        device_id: Option<&str>,
        iroh_node_id: Option<&str>,
    ) -> anyhow::Result<()> {
        let conn = self.lock_conn();
        conn.execute(
            "DELETE FROM removed_devices
             WHERE user_id = ?1 AND ((?2 IS NOT NULL AND device_id = ?2) OR (?3 IS NOT NULL AND iroh_node_id = ?3))",
            params![user_id, device_id, iroh_node_id],
        )?;
        Ok(())
    }

    pub fn client_version_counts(&self) -> anyhow::Result<Vec<AdminVersionCount>> {
        let conn = self.lock_conn();
        let cutoff = (Utc::now() - chrono::Duration::days(30)).to_rfc3339();
        let mut stmt = conn.prepare(
            "SELECT platform, app_version, COUNT(*), SUM(CASE WHEN last_seen_at >= ?1 THEN 1 ELSE 0 END)
             FROM devices GROUP BY platform, app_version ORDER BY COUNT(*) DESC",
        )?;
        let rows = stmt.query_map(params![cutoff], |row| {
            let platform: String = row.get(0)?;
            Ok(AdminVersionCount {
                platform: serde_json::from_str(&platform).unwrap_or(platform),
                version: row.get(1)?,
                devices: row.get(2)?,
                active_devices: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
    }

    pub fn delete_device(&self, device_id: &str, user_id: &str) -> anyhow::Result<bool> {
        let conn = self.lock_conn();
        let affected = conn.execute(
            "DELETE FROM devices WHERE id = ?1 AND user_id = ?2",
            params![device_id, user_id],
        )?;
        Ok(affected > 0)
    }
}
