//! Sentinel Navigation Server - High-performance navigation server for WoW pathfinding.
//!
//! This server provides HTTP endpoints for pathfinding using CMaNGOS or TrinityCore
//! navigation mesh files (mmaps). Supports multiple game versions simultaneously.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use tower_http::timeout::TimeoutLayer;

mod blackboard;
mod cache;
mod config;
mod error;
mod pipeline;
mod routes;
mod services;
mod state;
mod validation;

use blackboard::{GameBundle, ServerBlackboard};
use cache::PathCache;
use config::Config;
use services::cache_impl::MokaCache;
use services::pathfinding::DetourPathfinder;
use services::routing::DetourRouter;

use services::spatial::DetourSpatial;
use services::tactical::DetourTactical;
use state::Metrics;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging with multiple directives
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("sentinel_nav_server=info".parse()?)
                .add_directive("mmap_loader=info".parse()?)
                .add_directive("detour=warn".parse()?),
        )
        .init();

    // Initialize metrics counters/histograms
    state::init_metrics();

    tracing::info!(
        "Sentinel Navigation Server v{} starting...",
        env!("CARGO_PKG_VERSION")
    );

    // Load configuration. Honor `--config <path>` (or `--config=<path>`) so a launcher can point at
    // an absolute config regardless of the working directory; otherwise fall back to the env var /
    // ./config.toml (see Config::load).
    let config = Config::load(config_path_from_args())?;
    tracing::info!(
        "Configuration loaded: host={}, port={}, default_game={}",
        config.server.host,
        config.server.port,
        config.navmesh.default_game
    );

    // Resolve game configurations (handles legacy single-game mode)
    let game_configs = config.navmesh.resolved_games();

    if game_configs.is_empty() {
        anyhow::bail!(
            "No game configurations found. Define [navmesh.games.<name>] sections in config.toml \
             or set navmesh.mmap_path for legacy single-game mode."
        );
    }

    // Build a GameBundle per game
    let mut games: HashMap<String, Arc<GameBundle>> = HashMap::new();

    for (game_name, game_config) in &game_configs {
        tracing::info!(
            "Initializing game '{}': mmap_path={:?}",
            game_name,
            game_config.mmap_path
        );

        let mmap_manager = Arc::new(mmap_loader::MmapManager::new(
            &game_config.mmap_path,
            config.pathfinding.query_pool_size,
            config.pathfinding.max_query_nodes,
        ));

        // Preload configured maps for this game
        for &map_id in &game_config.preload_maps {
            tracing::info!("Preloading map {} for game '{}'", map_id, game_name);
            match mmap_manager.get_or_load_mesh(map_id) {
                Ok(_) => tracing::info!(
                    "Successfully preloaded map {} for game '{}'",
                    map_id,
                    game_name
                ),
                Err(e) => tracing::warn!(
                    "Failed to preload map {} for game '{}': {}",
                    map_id,
                    game_name,
                    e
                ),
            }
        }

        // Build service implementations for this game
        let pathfinder: Arc<dyn services::PathfindingService> =
            Arc::new(DetourPathfinder::new(mmap_manager.clone()));
        let router: Arc<dyn services::RoutingService> =
            Arc::new(DetourRouter::new(mmap_manager.clone()));
        let spatial: Arc<dyn services::SpatialService> =
            Arc::new(DetourSpatial::new(mmap_manager.clone()));
        let tactical: Arc<dyn services::TacticalService> =
            Arc::new(DetourTactical::new(mmap_manager.clone()));

        games.insert(
            game_name.clone(),
            Arc::new(GameBundle {
                mmap_manager,
                pathfinding: pathfinder,
                routing: router,
                spatial,
                tactical,
            }),
        );

        tracing::info!("Game '{}' initialized", game_name);
    }

    let path_cache = Arc::new(PathCache::new());
    let cache: Arc<dyn services::CacheService> =
        Arc::new(MokaCache::new(path_cache.clone()));

    // Assemble the ServerBlackboard
    let blackboard = Arc::new(ServerBlackboard {
        games,
        default_game: config.navmesh.default_game.clone(),
        cache,
        request_semaphore: Arc::new(Semaphore::new(config.server.max_concurrent_requests)),
        path_cache,
        config: Arc::new(config.clone()),
        metrics: Arc::new(Metrics::new()),
        start_time: Instant::now(),
    });

    tracing::info!(
        "ServerBlackboard initialized: {} game(s), {} total maps preloaded",
        blackboard.games.len(),
        blackboard.total_loaded_map_count()
    );

    // Build router with timeout middleware
    let app = routes::build_router(blackboard)
        .layer(TimeoutLayer::new(Duration::from_secs(30)));

    // Start server
    let addr: SocketAddr = format!("{}:{}", config.server.host, config.server.port)
        .parse()
        .map_err(|e| anyhow::anyhow!(
            "Invalid listen address '{}:{}': {}",
            config.server.host, config.server.port, e
        ))?;

    tracing::info!("Listening on http://{}", addr);

    let shutdown_token = shutdown_token();
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_token.cancelled().await;
        })
        .await?;

    tracing::info!("Server shutdown complete");
    Ok(())
}

/// Parse an optional `--config <path>` / `--config=<path>` argument.
fn config_path_from_args() -> Option<std::path::PathBuf> {
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if let Some(rest) = arg.strip_prefix("--config=") {
            return Some(std::path::PathBuf::from(rest));
        }
        if arg == "--config" {
            return args.next().map(std::path::PathBuf::from);
        }
    }
    None
}

/// Create a cancellation token that fires on Ctrl+C or SIGTERM.
fn shutdown_token() -> CancellationToken {
    let token = CancellationToken::new();
    let cloned = token.clone();

    #[cfg(unix)]
    tokio::spawn(async move {
        let mut sigterm =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("Failed to install SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => tracing::info!("Received Ctrl+C, shutting down..."),
            _ = sigterm.recv() => tracing::info!("Received SIGTERM, shutting down..."),
        }
        cloned.cancel();
    });

    #[cfg(not(unix))]
    tokio::spawn(async move {
        tokio::signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
        tracing::info!("Received Ctrl+C, shutting down...");
        cloned.cancel();
    });

    token
}
