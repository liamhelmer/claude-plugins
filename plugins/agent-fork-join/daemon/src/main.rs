//! Merge Daemon - FIFO merge queue for multi-agent git workflows
//!
//! This daemon manages a queue of agent branches waiting to be merged into
//! a feature branch. It handles conflict detection, rebase coordination,
//! and maintains persistent state across restarts.

mod config;
mod error;
mod ipc;
mod merger;
mod queue;
mod state;

use anyhow::Result;
use clap::Parser;
use std::path::PathBuf;
use tokio::signal;
use tracing::{info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use crate::config::Config;
use crate::ipc::IpcServer;
use crate::queue::MergeQueue;
use crate::state::StateManager;

/// Merge daemon for multi-agent git workflows
#[derive(Parser, Debug)]
#[command(name = "merge-daemon")]
#[command(about = "FIFO merge queue daemon for multi-agent git workflows")]
struct Args {
    /// Path to the git repository
    #[arg(short, long, default_value = ".")]
    repo: PathBuf,

    /// Unix socket path
    #[arg(short, long, default_value = "/tmp/merge-daemon.sock")]
    socket: PathBuf,

    /// State database path
    #[arg(short, long, default_value = ".fork-join/state.db")]
    db: PathBuf,

    /// Log level (trace, debug, info, warn, error)
    #[arg(short, long, default_value = "info")]
    log_level: String,

    /// Run in foreground (don't daemonize)
    #[arg(short, long)]
    foreground: bool,

    /// Configuration file path
    #[arg(short, long)]
    config: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Initialize logging
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(&args.log_level));

    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer())
        .init();

    info!("Starting merge daemon v{}", env!("CARGO_PKG_VERSION"));
    info!("Repository: {:?}", args.repo);
    info!("Socket: {:?}", args.socket);

    // Load configuration
    let config = if let Some(config_path) = &args.config {
        Config::from_file(config_path)?
    } else {
        Config::default()
    };

    // Initialize state manager (persistent storage)
    let state_manager = StateManager::new(&args.db).await?;
    info!("State database initialized at {:?}", args.db);

    // Initialize merge queue
    let queue = MergeQueue::new(args.repo.clone(), state_manager.clone(), config.clone());

    // Recover any pending merges from previous run
    let recovered = queue.recover().await?;
    if recovered > 0 {
        info!("Recovered {} pending merge(s) from previous session", recovered);
    }

    // Start IPC server
    let server = IpcServer::new(args.socket.clone(), queue.clone(), state_manager.clone())?;

    // Remove stale socket file if it exists
    if args.socket.exists() {
        warn!("Removing stale socket file: {:?}", args.socket);
        std::fs::remove_file(&args.socket)?;
    }

    // Spawn the IPC server
    let server_handle = tokio::spawn(async move {
        if let Err(e) = server.run().await {
            tracing::error!("IPC server error: {}", e);
        }
    });

    // Spawn the merge processor
    let processor_handle = tokio::spawn({
        let queue = queue.clone();
        async move {
            queue.process_loop().await;
        }
    });

    info!("Merge daemon started successfully");
    info!("Listening on: {:?}", args.socket);

    // Wait for shutdown signal
    shutdown_signal().await;

    info!("Shutdown signal received, cleaning up...");

    // Graceful shutdown
    queue.shutdown().await;
    server_handle.abort();
    processor_handle.abort();

    // Cleanup socket file
    if args.socket.exists() {
        std::fs::remove_file(&args.socket)?;
    }

    info!("Merge daemon stopped");
    Ok(())
}

/// Wait for shutdown signals (SIGINT, SIGTERM)
async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
