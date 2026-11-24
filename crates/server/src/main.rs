use std::path::PathBuf;

use dropdrawer_server::{
    db::Database, routes::build_router, spawn_ttl_cleanup_task, state::AppState,
};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let bind_addr =
        std::env::var("DROPDRAWER_BIND").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let db_path =
        std::env::var("DROPDRAWER_DB_PATH").unwrap_or_else(|_| "./data/dropdrawer.db".to_string());
    let local_storage = std::env::var("DROPDRAWER_LOCAL_STORAGE")
        .unwrap_or_else(|_| "./data/blobs".to_string());
    let jwt_secret = std::env::var("DROPDRAWER_JWT_SECRET")
        .unwrap_or_else(|_| "dropdrawer-dev-secret-please-change-in-prod".to_string());
    let cleanup_secs: u64 = std::env::var("DROPDRAWER_TTL_CLEANUP_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);

    let db = Database::open(&db_path)?;
    let state = AppState::new(db, jwt_secret, PathBuf::from(local_storage));
    spawn_ttl_cleanup_task(state.clone(), cleanup_secs);

    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!("DropDrawer server listening on http://{bind_addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
