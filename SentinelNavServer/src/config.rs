//! Configuration loading and types.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;

/// Main configuration structure.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub server: ServerConfig,
    pub navmesh: NavmeshConfig,
    pub pathfinding: PathfindingConfig,
}

/// Server configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    /// Host to bind to.
    #[serde(default = "default_host")]
    pub host: String,
    /// Port to listen on.
    #[serde(default = "default_port")]
    pub port: u16,
    /// Maximum concurrent requests.
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent_requests: usize,
}

/// Navmesh configuration with multi-game support.
///
/// Supports two modes:
/// 1. **Multi-game** (preferred): `[navmesh.games.<name>]` sections define per-game mmap sources
/// 2. **Legacy**: single `mmap_path` + `preload_maps` fields (treated as the default game)
#[derive(Debug, Clone, Deserialize)]
pub struct NavmeshConfig {
    /// Default game to use when no `game` parameter is specified in requests.
    #[serde(default = "default_game")]
    pub default_game: String,

    /// Per-game mmap configurations.
    /// Keys are game identifiers (e.g., "tbc", "retail").
    #[serde(default)]
    pub games: HashMap<String, GameConfig>,

    // -- Legacy fields (for backward compatibility) --
    /// Path to mmap files directory (legacy single-game mode).
    pub mmap_path: Option<PathBuf>,
    /// Maps to preload at startup (legacy single-game mode).
    #[serde(default)]
    pub preload_maps: Vec<u32>,
}

/// Configuration for a single game's mmap data.
#[derive(Debug, Clone, Deserialize)]
pub struct GameConfig {
    /// Path to the mmap files directory for this game.
    pub mmap_path: PathBuf,
    /// Maps to preload at startup for this game.
    #[serde(default)]
    pub preload_maps: Vec<u32>,
}

impl NavmeshConfig {
    /// Resolve the effective game configurations.
    ///
    /// If `games` map is empty but legacy `mmap_path` is set, creates a
    /// single-game config using the default_game name.
    pub fn resolved_games(&self) -> HashMap<String, GameConfig> {
        if !self.games.is_empty() {
            return self.games.clone();
        }

        // Legacy mode: use mmap_path as the default game
        let mut games = HashMap::new();
        if let Some(path) = &self.mmap_path {
            games.insert(
                self.default_game.clone(),
                GameConfig {
                    mmap_path: path.clone(),
                    preload_maps: self.preload_maps.clone(),
                },
            );
        }
        games
    }
}

/// Pathfinding configuration.
#[derive(Debug, Clone, Deserialize)]
pub struct PathfindingConfig {
    /// Maximum path length in waypoints.
    #[serde(default = "default_max_path_length")]
    pub max_path_length: usize,
    /// Query pool size per map.
    #[serde(default = "default_query_pool_size")]
    pub query_pool_size: usize,
    /// Tiered polygon search extents [tight, medium, wide] in yards.
    #[serde(default = "default_search_extents")]
    pub search_extents: [f32; 3],
    /// Max segment length before densification (yards).
    #[serde(default = "default_max_segment_length")]
    pub max_segment_length: f32,
    /// Default area costs [ground, water, lava].
    #[serde(default = "default_area_costs")]
    pub default_area_costs: [f32; 3],
    /// Maximum A* search nodes per NavMeshQuery.
    /// Higher values allow pathfinding through denser navmeshes (GO-injected areas).
    /// Each node uses ~36 bytes. 1048576 nodes ~ 40 MB per query pool.
    #[serde(default = "default_max_query_nodes")]
    pub max_query_nodes: u32,
}

fn default_host() -> String {
    "0.0.0.0".to_string()
}

fn default_port() -> u16 {
    47110
}

fn default_max_concurrent() -> usize {
    100
}

fn default_game() -> String {
    "tbc".to_string()
}

fn default_max_path_length() -> usize {
    2048
}

fn default_query_pool_size() -> usize {
    4
}

fn default_search_extents() -> [f32; 3] {
    [6.0, 10.0, 50.0]
}

fn default_max_segment_length() -> f32 {
    3.0
}

fn default_area_costs() -> [f32; 3] {
    [1.0, 1.5, 100.0]
}

fn default_max_query_nodes() -> u32 {
    1048576
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: default_host(),
            port: default_port(),
            max_concurrent_requests: default_max_concurrent(),
        }
    }
}

impl Default for PathfindingConfig {
    fn default() -> Self {
        Self {
            max_path_length: default_max_path_length(),
            query_pool_size: default_query_pool_size(),
            search_extents: default_search_extents(),
            max_segment_length: default_max_segment_length(),
            default_area_costs: default_area_costs(),
            max_query_nodes: default_max_query_nodes(),
        }
    }
}

impl Config {
    /// Load configuration from an explicit path, the `SENTINEL_NAV_SERVER_CONFIG` env var, or the
    /// default `config.toml` in the current directory — in that precedence order. Falls back to
    /// built-in defaults only when none of those files exist.
    pub fn load(explicit_path: Option<PathBuf>) -> anyhow::Result<Self> {
        let config_path = explicit_path
            .map(|p| p.to_string_lossy().into_owned())
            .or_else(|| std::env::var("SENTINEL_NAV_SERVER_CONFIG").ok())
            .unwrap_or_else(|| "config.toml".to_string());

        if let Ok(content) = std::fs::read_to_string(&config_path) {
            let config: Config = toml::from_str(&content)?;
            return Ok(config);
        }

        // Use defaults
        Ok(Self {
            server: ServerConfig::default(),
            navmesh: NavmeshConfig {
                default_game: default_game(),
                games: HashMap::new(),
                mmap_path: Some(PathBuf::from("./mmaps")),
                preload_maps: vec![],
            },
            pathfinding: PathfindingConfig::default(),
        })
    }
}
