//! Error types for the merge daemon

use thiserror::Error;

/// Errors that can occur in the merge daemon
#[derive(Error, Debug)]
pub enum DaemonError {
    #[error("Git error: {0}")]
    Git(#[from] git2::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Agent not found: {0}")]
    AgentNotFound(String),

    #[error("Session not found: {0}")]
    SessionNotFound(String),

    #[error("Branch not found: {0}")]
    BranchNotFound(String),

    #[error("Merge conflict in files: {0:?}")]
    MergeConflict(Vec<String>),

    #[error("Queue is full (max: {0})")]
    QueueFull(usize),

    #[error("Agent already in queue: {0}")]
    AgentAlreadyQueued(String),

    #[error("Invalid request: {0}")]
    InvalidRequest(String),

    #[error("Worktree error: {0}")]
    Worktree(String),

    #[error("Rebase failed: {0}")]
    RebaseFailed(String),

    #[error("Max retries exceeded for agent: {0}")]
    MaxRetriesExceeded(String),

    #[error("Daemon shutdown in progress")]
    ShuttingDown,

    #[error("Configuration error: {0}")]
    Config(String),
}

/// Result type alias for daemon operations
pub type DaemonResult<T> = Result<T, DaemonError>;
