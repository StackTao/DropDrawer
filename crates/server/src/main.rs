use std::{
    collections::HashMap,
    env,
    num::NonZeroU64,
    path::{Path, PathBuf},
};

use dropdrawer_server::{
    admin::{self, TrustProxy},
    db::Database,
    google_login::GoogleLoginConfig,
    routes::build_router_with_cors,
    settings::{GoogleProviderSettings, RegistrationMode, RuntimeSettings, SmtpSettings},
    spawn_ttl_cleanup_task,
    state::AppState,
};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let settings = load_env_file()?;
    let get = |key: &str| env::var(key).ok().or_else(|| settings.get(key).cloned());
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::new(get("RUST_LOG").as_deref().unwrap_or("info")))
        .init();

    let bind_addr = get("DROPDRAWER_BIND").unwrap_or_else(|| "0.0.0.0:8080".to_string());
    let db_path = get("DROPDRAWER_DB_PATH").unwrap_or_else(|| "./data/dropdrawer.db".to_string());
    let args: Vec<_> = env::args().skip(1).collect();
    let secret_key = get("DROPDRAWER_SECRET_KEY")
        .filter(|value| !value.trim().is_empty())
        .map(|value| dropdrawer_server::secret_box::parse_key(&value))
        .transpose()
        .map_err(|err| anyhow::anyhow!("DROPDRAWER_SECRET_KEY: {err}"))?;
    if args.first().is_some_and(|arg| arg == "db-export-for-downgrade") {
        let [_, output] = args.as_slice() else {
            anyhow::bail!("Usage: dropdrawer-server db-export-for-downgrade <new-database-file>");
        };
        anyhow::ensure!(Path::new(&db_path).is_file(), "source database does not exist");
        Database::open_with_secret_key(&db_path, secret_key)?
            .export_legacy_database(Path::new(output))?;
        return Ok(());
    }
    let local_storage =
        get("DROPDRAWER_LOCAL_STORAGE").unwrap_or_else(|| "./data/blobs".to_string());
    let local_max_file_bytes = get("DROPDRAWER_LOCAL_MAX_FILE_BYTES")
        .filter(|value| !value.trim().is_empty())
        .map(|value| value.trim().parse::<NonZeroU64>().map(NonZeroU64::get))
        .transpose()
        .map_err(|_| anyhow::anyhow!("DROPDRAWER_LOCAL_MAX_FILE_BYTES must be a positive byte count"))?;
    let default_user_local_quota_bytes = get("DROPDRAWER_LOCAL_USER_QUOTA_BYTES")
        .filter(|value| !value.trim().is_empty())
        .map(|value| value.trim().parse::<NonZeroU64>().map(NonZeroU64::get))
        .transpose()
        .map_err(|_| anyhow::anyhow!("DROPDRAWER_LOCAL_USER_QUOTA_BYTES must be a positive byte count"))?;
    let jwt_secret = resolve_jwt_secret(&db_path, get("DROPDRAWER_JWT_SECRET").as_deref())?;
    let cleanup_secs: u64 = get("DROPDRAWER_TTL_CLEANUP_SECS")
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);
    let google_config = GoogleLoginConfig::from_settings(get)?;
    let allow_registration = get("DROPDRAWER_ALLOW_REGISTRATION")
        .map(|v| {
            !matches!(
                v.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "no" | "off"
            )
        })
        .unwrap_or(true);
    let mut env_defaults = RuntimeSettings {
        registration_mode: if allow_registration {
            RegistrationMode::Open
        } else {
            RegistrationMode::Closed
        },
        local_max_file_bytes,
        default_user_local_quota_bytes,
        smtp: SmtpSettings::from_env(&get),
        ..RuntimeSettings::default()
    };
    if let Some(cfg) = &google_config {
        env_defaults.google = GoogleProviderSettings::from_google_config(cfg);
    }
    let admin_enabled = get("DROPDRAWER_ADMIN_ENABLED")
        .filter(|value| !value.trim().is_empty())
        .map_or_else(
            || get("DROPDRAWER_ADMIN_TOKEN").is_some_and(|value| !value.trim().is_empty()),
            |value| matches!(value.trim().to_ascii_lowercase().as_str(), "true" | "1"),
        );
    if admin_enabled {
        tracing::info!("Admin console enabled at /admin");
    }

    let db = Database::open_with_secret_key(&db_path, secret_key)?;
    let state = AppState::with_full_config(
        db,
        jwt_secret,
        PathBuf::from(local_storage),
        env_defaults,
        admin_enabled,
    );
    if let Some(push) = dropdrawer_server::push::PushService::from_settings(get)? {
        let config = push.client_config();
        tracing::info!(apns = config.apns, fcm = config.fcm.is_some(), "push notifications are enabled");
        state.set_push_service(push);
    }
    if !args.is_empty() {
        return admin::local_account_command(&state, &args);
    }
    let effective = state.runtime_settings();
    if effective.google.enabled {
        tracing::info!("Google sign-in is enabled");
    }
    if effective.smtp.is_usable() {
        tracing::info!(host = %effective.smtp.host, "SMTP email delivery is enabled");
    }
    if let Some(limit) = effective.local_max_file_bytes {
        tracing::info!(limit, "server-local per-file upload limit is enabled");
    }
    if effective.registration_mode != RegistrationMode::Open {
        tracing::info!(mode = effective.registration_mode.as_str(), "restricted registration mode active");
    }
    spawn_ttl_cleanup_task(state.clone(), cleanup_secs);

    let cors_origins: Option<Vec<String>> = get("DROPDRAWER_CORS_ORIGINS")
        .map(|raw| {
            raw.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|list| !list.is_empty());
    if let Some(ref origins) = cors_origins {
        tracing::info!(?origins, "CORS allowed origins configured");
    }

    let trust_proxy = get("DROPDRAWER_TRUST_PROXY")
        .is_some_and(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "true" | "1"));
    let app = build_router_with_cors(state, cors_origins.as_deref())
        .layer(axum::Extension(TrustProxy(trust_proxy)));
    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!("DropDrawer server listening on http://{bind_addr}");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    tracing::info!("DropDrawer server shut down cleanly");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sigterm) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sigterm.recv().await;
        } else {
            std::future::pending::<()>().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received, draining in-flight requests");
}

fn load_env_file() -> anyhow::Result<HashMap<String, String>> {
    let explicit = env::var_os("DROPDRAWER_ENV_FILE");
    let path = explicit
        .as_deref()
        .map(Path::new)
        .unwrap_or(Path::new(".env"));
    let entries = match dotenvy::from_path_iter(path) {
        Ok(entries) => entries,
        Err(dotenvy::Error::Io(err))
            if explicit.is_none() && err.kind() == std::io::ErrorKind::NotFound =>
        {
            return Ok(HashMap::new());
        }
        Err(_) => anyhow::bail!(
            "Could not open the DropDrawer environment file {}",
            path.display()
        ),
    };
    entries.collect::<Result<_, _>>().map_err(|_| {
        anyhow::anyhow!(
            "Invalid setting in the DropDrawer environment file {}",
            path.display()
        )
    })
}

/// Placeholder secrets that once shipped as defaults; anyone could forge sessions with them.
const KNOWN_PLACEHOLDER_SECRETS: &[&str] = &[
    "dropdrawer-dev-secret-please-change-in-prod",
    "change-me-to-a-long-random-secret",
];

/// Uses `DROPDRAWER_JWT_SECRET` when it is set to a real value. Otherwise generates a
/// random secret once and keeps it next to the database so sessions survive restarts.
fn resolve_jwt_secret(db_path: &str, configured: Option<&str>) -> anyhow::Result<String> {
    let configured = configured.unwrap_or_default().trim();
    if !configured.is_empty() && !KNOWN_PLACEHOLDER_SECRETS.contains(&configured) {
        if configured.len() < 32 {
            tracing::warn!(
                "DROPDRAWER_JWT_SECRET is shorter than 32 characters; use a longer random value"
            );
        }
        return Ok(configured.to_string());
    }
    if !configured.is_empty() {
        tracing::warn!(
            "ignoring the placeholder DROPDRAWER_JWT_SECRET; using a generated secret instead"
        );
    }

    let dir = Path::new(db_path)
        .parent()
        .filter(|p| !p.as_os_str().is_empty());
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
