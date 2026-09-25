use axum::{
    extract::Extension,
    routing::{get, post},
    Router,
};
use std::net::SocketAddr;

mod db;
mod handlers;
mod resolve;
mod search;
mod spawn_zones;
mod zone_names;

use db::Db;

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Open the database (readonly)
    let db_path = std::env::var("SENTINEL_DB")
        .unwrap_or_else(|_| "./tbcmangos.sqlite".to_string());
    let db = Db::new(&db_path);

    // Build the router
    let app = Router::new()
        // Liveness probe for hosted deployments and the thin-client installer's health check.
        // Deliberately DB-free so it answers 200 even while the world DB is being (re)provisioned.
        .route("/health", get(health))
        .route("/quests/search", get(handlers::search_quests))
        .route("/quest/:id", get(handlers::get_quest))
        .route("/quest/:id/chain", get(handlers::get_quest_chain))
        .route("/quest/:id/objectives", get(handlers::get_quest_objectives))
        .route("/npc/search", get(handlers::search_npcs))
        .route("/npc/:entry", get(handlers::get_npc))
        .route("/vendor/:entry", get(handlers::get_vendor))
        .route("/trainer/:entry", get(handlers::get_trainer))
        .route("/flight/:entry", get(handlers::get_flight))
        .route("/object/:entry", get(handlers::get_object))
        .route("/item/:item", get(handlers::get_item))
        .route("/item/:item/sources", get(handlers::get_item_sources))
        .route("/creatures/polygon", get(handlers::creatures_polygon))
        .route("/search", get(handlers::search))
        // Declared before `/spawns/:type/:entry`: axum's router would otherwise never see this
        // path, since "nearby" matches `:type` and the entry segment is what distinguishes them.
        .route("/spawns/nearby", get(handlers::spawns_nearby))
        .route("/spawns/:type/:entry", get(handlers::get_spawns))
        .route("/zone/:id/spawns", get(handlers::zone_spawns))
        .route("/spawns/density/:zone", get(handlers::spawn_density))
        .route("/resolve", post(handlers::resolve))
        .route("/validate", post(handlers::validate))
        .route("/travel/estimate", post(handlers::travel_estimate))
        .route("/travel/route", post(handlers::travel_route))
        .layer(Extension(db))
        .fallback(handler_404);

    // Run it.
    //
    // Bind address is configurable so a HOSTED QueryServer can serve remote game clients
    // (the thin-client runtime resolves NPC spawns / item quality against it), while the
    // default stays loopback-only for a local dev box:
    //   * SENTINEL_QUERY_BIND — full socket address, e.g. "0.0.0.0:3030" (wins if set)
    //   * SENTINEL_QUERY_PORT — port only, bound on 127.0.0.1 (e.g. "3030")
    //   * neither               — 127.0.0.1:3030 (unchanged historical default)
    let addr = resolve_bind_addr();
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    tracing::info!("listening on {}", addr);
    axum::serve(listener, app).await.unwrap();
}

/// Resolve the listen address from the environment, defaulting to the historical
/// `127.0.0.1:3030`. `SENTINEL_QUERY_BIND` takes precedence over `SENTINEL_QUERY_PORT`.
fn resolve_bind_addr() -> SocketAddr {
    if let Ok(bind) = std::env::var("SENTINEL_QUERY_BIND") {
        let trimmed = bind.trim();
        if !trimmed.is_empty() {
            return trimmed.parse().unwrap_or_else(|e| {
                panic!("SENTINEL_QUERY_BIND ('{trimmed}') must be host:port, e.g. 0.0.0.0:3030: {e}")
            });
        }
    }
    let port: u16 = std::env::var("SENTINEL_QUERY_PORT")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(3030);
    SocketAddr::from(([127, 0, 0, 1], port))
}

async fn health() -> impl axum::response::IntoResponse {
    (axum::http::StatusCode::OK, "ok")
}

async fn handler_404() -> impl axum::response::IntoResponse {
    (axum::http::StatusCode::NOT_FOUND, "Not found")
}