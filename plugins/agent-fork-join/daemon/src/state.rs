//! Persistent state management using SQLite

use crate::error::DaemonResult;
use crate::queue::QueueEntry;
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing::debug;
use uuid::Uuid;

/// Manages persistent state in SQLite
#[derive(Clone)]
pub struct StateManager {
    conn: Arc<Mutex<Connection>>,
}

impl StateManager {
    /// Create a new state manager
    pub async fn new(db_path: &Path) -> DaemonResult<Self> {
        // Ensure parent directory exists
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let conn = Connection::open(db_path)?;

        // Initialize schema
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS queue_entries (
                id TEXT PRIMARY KEY,
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                branch TEXT NOT NULL,
                worktree TEXT NOT NULL,
                target_branch TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                queued_at TEXT NOT NULL,
                status TEXT NOT NULL,
                last_error TEXT,
                conflict_files TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );

            CREATE INDEX IF NOT EXISTS idx_queue_agent ON queue_entries(agent_id);
            CREATE INDEX IF NOT EXISTS idx_queue_session ON queue_entries(session_id);
            CREATE INDEX IF NOT EXISTS idx_queue_status ON queue_entries(status);

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                feature_branch TEXT NOT NULL,
                base_branch TEXT NOT NULL,
                original_prompt TEXT,
                created_at TEXT NOT NULL,
                state TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );

            CREATE TABLE IF NOT EXISTS merge_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                commit_sha TEXT,
                merged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (entry_id) REFERENCES queue_entries(id)
            );
            "#,
        )?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Save a queue entry
    pub async fn save_entry(&self, entry: &QueueEntry) -> DaemonResult<()> {
        let conn = self.conn.lock().await;

        let conflict_files = serde_json::to_string(&entry.conflict_files)?;

        conn.execute(
            r#"
            INSERT OR REPLACE INTO queue_entries
            (id, agent_id, session_id, branch, worktree, target_branch, attempts, queued_at, status, last_error, conflict_files, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, CURRENT_TIMESTAMP)
            "#,
            params![
                entry.id.to_string(),
                entry.agent_id,
                entry.session_id,
                entry.branch,
                entry.worktree.to_string_lossy(),
                entry.target_branch,
                entry.attempts,
                entry.queued_at.to_rfc3339(),
                serde_json::to_string(&entry.status)?,
                entry.last_error,
                conflict_files,
            ],
        )?;

        debug!("Saved entry {} for agent {}", entry.id, entry.agent_id);
        Ok(())
    }

    /// Delete a queue entry
    pub async fn delete_entry(&self, id: &Uuid) -> DaemonResult<()> {
        let conn = self.conn.lock().await;

        conn.execute(
            "DELETE FROM queue_entries WHERE id = ?1",
            params![id.to_string()],
        )?;

        debug!("Deleted entry {}", id);
        Ok(())
    }

    /// Load all pending entries (for recovery)
    pub async fn load_pending_entries(&self) -> DaemonResult<Vec<QueueEntry>> {
        let conn = self.conn.lock().await;

        let mut stmt = conn.prepare(
            r#"
            SELECT id, agent_id, session_id, branch, worktree, target_branch, attempts, queued_at, status, last_error, conflict_files
            FROM queue_entries
            WHERE status IN ('"Pending"', '"Processing"')
            ORDER BY queued_at ASC
            "#,
        )?;

        let entries = stmt
            .query_map([], |row| {
                let id: String = row.get(0)?;
                let conflict_files: String = row.get(10)?;
                let status: String = row.get(8)?;

                Ok(QueueEntry {
                    id: Uuid::parse_str(&id).unwrap_or_else(|_| Uuid::new_v4()),
                    agent_id: row.get(1)?,
                    session_id: row.get(2)?,
                    branch: row.get(3)?,
                    worktree: std::path::PathBuf::from(row.get::<_, String>(4)?),
                    target_branch: row.get(5)?,
                    attempts: row.get(6)?,
                    queued_at: chrono::DateTime::parse_from_rfc3339(&row.get::<_, String>(7)?)
                        .map(|dt| dt.with_timezone(&chrono::Utc))
                        .unwrap_or_else(|_| chrono::Utc::now()),
                    status: serde_json::from_str(&status).unwrap_or(crate::queue::EntryStatus::Pending),
                    last_error: row.get(9)?,
                    conflict_files: serde_json::from_str(&conflict_files).unwrap_or_default(),
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(entries)
    }

    /// Record a successful merge in history
    pub async fn record_merge(
        &self,
        entry_id: &Uuid,
        agent_id: &str,
        session_id: &str,
        commit_sha: &str,
    ) -> DaemonResult<()> {
        let conn = self.conn.lock().await;

        conn.execute(
            r#"
            INSERT INTO merge_history (entry_id, agent_id, session_id, commit_sha)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![entry_id.to_string(), agent_id, session_id, commit_sha],
        )?;

        Ok(())
    }

    /// Get merge history for a session
    pub async fn get_session_merges(&self, session_id: &str) -> DaemonResult<Vec<MergeRecord>> {
        let conn = self.conn.lock().await;

        let mut stmt = conn.prepare(
            r#"
            SELECT agent_id, commit_sha, merged_at
            FROM merge_history
            WHERE session_id = ?1
            ORDER BY merged_at ASC
            "#,
        )?;

        let records = stmt
            .query_map(params![session_id], |row| {
                Ok(MergeRecord {
                    agent_id: row.get(0)?,
                    commit_sha: row.get(1)?,
                    merged_at: row.get(2)?,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();

        Ok(records)
    }
}

/// Record of a completed merge
#[derive(Debug)]
pub struct MergeRecord {
    pub agent_id: String,
    pub commit_sha: String,
    pub merged_at: String,
}
