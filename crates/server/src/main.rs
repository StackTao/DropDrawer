use std::path::{Path, PathBuf};

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
    let jwt_secret = resolve_jwt_secret(&db_path)?;
    let cleanup_secs: u64 = std::env::var("DROPDRAWER_TTL_CLEANUP_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);

    let db = Database::open(&db_path)?;
    let state = AppState::new(db, jwt_secret, PathBuf::from(local_storage));
    let allow_registration = std::env::var("DROPDRAWER_ALLOW_REGISTRATION")
        .map(|v| !matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "no" | "off"))
        .unwrap_or(true);
    state.set_registration_open(allow_registration);
    if !allow_registration {
        tracing::info!("new account registration is disabled");
    }
    spawn_ttl_cleanup_task(state.clone(), cleanup_secs);

    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!("DropDrawer server listening on http://{bind_addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

/// Placeholder secrets that once shipped as defaults; anyone could forge sessions with them.
const KNOWN_PLACEHOLDER_SECRETS: &[&str] = &[
    "dropdrawer-dev-secret-please-change-in-prod",
    "change-me-to-a-long-random-secret",
];

/// Uses `DROPDRAWER_JWT_SECRET` when it is set to a real value. Otherwise generates a
/// random secret once and keeps it next to the database so sessions survive restarts.
fn resolve_jwt_secret(db_path: &str) -> anyhow::Result<String> {
    let configured = std::env::var("DROPDRAWER_JWT_SECRET").unwrap_or_default();
    let configured = configured.trim();
    if !configured.is_empty() && !KNOWN_PLACEHOLDER_SECRETS.contains(&configured) {
        if configured.len() < 32 {
            tracing::warn!("DROPDRAWER_JWT_SECRET is shorter than 32 characters; use a longer random value");
        }
        return Ok(configured.to_string());
    }
    if !configured.is_empty() {
        tracing::warn!("ignoring the placeholder DROPDRAWER_JWT_SECRET; using a generated secret instead");
    }

    let dir = Path::new(db_path).parent().filter(|p| !p.as_os_str().is_empty());
    let path = dir.unwrap_or(Path::new(".")).join("jwt_secret");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim();
        if existing.len() >= 32 {
            return Ok(existing.to_string());
        }
    }
    if let Some(dir) = dir {
        std::fs::create_dir_all(dir)?;
    }
    let mut bytes = [0u8; 32];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut bytes);
    let secret = hex::encode(bytes);
    write_private_file(&path, secret.as_bytes())?;
    tracing::info!("generated a new JWT secret at {}", path.display());
    Ok(secret)
}

fn write_private_file(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)?.write_all(contents)
}
