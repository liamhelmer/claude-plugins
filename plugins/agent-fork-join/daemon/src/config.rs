//! Configuration management for the merge daemon

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Daemon configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Maximum number of entries in the merge queue
    pub max_queue_size: usize,

    /// Maximum concurrent merge attempts (usually 1 for safety)
    pub max_concurrent_merges: usize,

    /// Maximum retry attempts for failed merges
    pub max_retries: u32,

    /// Merge strategy: "merge", "rebase", or "squash"
    pub merge_strategy: MergeStrategy,

    /// Timeout for merge operations in seconds
    pub merge_timeout_secs: u64,

    /// Whether to automatically rebase on conflict
    pub auto_rebase: bool,

    /// Branch prefix for agent branches
    pub agent_branch_prefix: String,

    /// Branch prefix for feature branches
    pub feature_branch_prefix: String,

    /// Worktree directory (relative to repo root)
    pub worktree_dir: String,

    /// Whether to preserve worktrees on merge success (for debugging)
    pub preserve_worktrees: bool,

    /// Cleanup stale sessions after this many seconds
    pub session_timeout_secs: u64,
}

/// Merge strategy options
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MergeStrategy {
    /// Standard merge commit
    Merge,
    /// Rebase and fast-forward
    Rebase,
    /// Squash all commits into one
    Squash,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_queue_size: 100,
            max_concurrent_merges: 1,
            max_retries: 3,
            merge_strategy: MergeStrategy::Rebase,
            merge_timeout_secs: 300,
            auto_rebase: true,
            agent_branch_prefix: "agent/".to_string(),
            feature_branch_prefix: "feature/".to_string(),
            worktree_dir: ".worktrees".to_string(),
            preserve_worktrees: false,
            session_timeout_secs: 3600,
        }
    }
}

impl Config {
    /// Load configuration from a JSON file
    pub fn from_file(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let config: Self = serde_json::from_str(&content)?;
        Ok(config)
    }

    /// Save configuration to a JSON file
    pub fn to_file(&self, path: &Path) -> Result<()> {
        let content = serde_json::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }
}
