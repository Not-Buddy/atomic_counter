mod flush;
mod local_redis;
mod readcache;
mod routes;

use axum::{routing::{get, post}, Router};
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use local_redis::LocalRedis;
use readcache::ReadCache;
use routes::AppState;

struct Config {
    local_redis_host: String,
    local_redis_port: u16,
    readcache_host: String,
    readcache_port: u16,
    port: u16,
    database_url: String,
    flush_interval_ms: u64,
}

impl Config {
    fn from_env() -> Self {
        Self {
            local_redis_host: std::env::var("LOCAL_REDIS_HOST")
                .unwrap_or_else(|_| "localhost".into()),
            local_redis_port: std::env::var("LOCAL_REDIS_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(6379),
            readcache_host: std::env::var("READCACHE_HOST")
                .unwrap_or_else(|_| "redis-readcache".into()),
            readcache_port: std::env::var("READCACHE_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(6379),
            port: std::env::var("PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(3000),
            database_url: std::env::var("DATABASE_URL")
                .expect("DATABASE_URL must be set"),
            flush_interval_ms: std::env::var("FLUSH_INTERVAL_MS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(10000),
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config = Config::from_env();

    let local_redis_url = format!(
        "redis://{}:{}",
        config.local_redis_host, config.local_redis_port
    );
    let local_client =
        redis::Client::open(local_redis_url.as_str()).expect("Failed to open local Redis client");
    let local_conn = redis::aio::ConnectionManager::new(local_client)
        .await
        .expect("Failed to connect to local Redis");
    let local_redis = LocalRedis::new(local_conn.clone());

    let readcache_url = format!(
        "redis://{}:{}",
        config.readcache_host, config.readcache_port
    );
    let readcache_client = redis::Client::open(readcache_url.as_str())
        .expect("Failed to open read cache Redis client");
    let readcache_conn = redis::aio::ConnectionManager::new(readcache_client)
        .await
        .expect("Failed to connect to read cache Redis");
    let readcache = ReadCache::new(readcache_conn.clone());

    // Connect to Postgres for self-flushing (retry up to 30s for startup ordering)
    let pool = {
        let mut attempts = 0;
        loop {
            match sqlx::PgPool::connect(&config.database_url).await {
                Ok(pool) => break pool,
                Err(e) => {
                    attempts += 1;
                    if attempts >= 10 {
                        panic!("Failed to connect to Postgres after {} attempts: {}", attempts, e);
                    }
                    tracing::warn!("Postgres not ready (attempt {}): {}, retrying in 3s...", attempts, e);
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                }
            }
        }
    };

    // Ensure the counters table exists (idempotent migration)
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS counters (
            key         VARCHAR(255) PRIMARY KEY,
            value       BIGINT NOT NULL DEFAULT 0,
            last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )",
    )
    .execute(&pool)
    .await
    .expect("Failed to run migration");

    // Spawn the self-flush loop: this gateway replica periodically drains
    // its own local Redis → Postgres → read cache. No cross-container
    // connections needed, completely avoiding Docker Swarm IPVS issues.
    let flush_interval = config.flush_interval_ms;
    tokio::spawn(flush::flush_loop(
        local_conn,
        pool,
        readcache_conn,
        flush_interval,
    ));

    let state = Arc::new(AppState {
        local_redis: Mutex::new(local_redis),
        readcache: Mutex::new(readcache),
    });

    let app = Router::new()
        .route("/increment/:key", post(routes::increment))
        .route("/count/:key", get(routes::count))
        .route("/health", get(routes::health))
        .route("/flush", post(routes::flush))
        .with_state(state.clone());

    let bind_addr = format!("0.0.0.0:{}", config.port);
    let listener = tokio::net::TcpListener::bind(&bind_addr)
        .await
        .expect("Failed to bind TCP listener");

    tracing::info!("Gateway listening on {}", bind_addr);

    let mut term_signal =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler");

    tokio::select! {
        _ = term_signal.recv() => {
            tracing::info!("SIGTERM received, draining local Redis...");
        }
        result = axum::serve(listener, app) => {
            if let Err(e) = result {
                tracing::error!("Server error: {}", e);
            }
            return;
        }
    }

    drain(&state).await;
    tracing::info!("Gateway shut down cleanly");
}

async fn drain(state: &Arc<AppState>) {
    let local = state.local_redis.lock().await;
    match local.scan_and_getdel().await {
        Ok(map) => {
            if map.is_empty() {
                tracing::info!("No keys to drain");
                return;
            }
            let n = map.len();
            let cache = state.readcache.lock().await;
            for (key, val) in &map {
                if let Err(e) = cache.incrby(key, *val).await {
                    tracing::error!("Failed to drain key {}: {}", key, e);
                }
            }
            tracing::info!("Drained {} keys before shutdown", n);
        }
        Err(e) => {
            tracing::error!("Failed to scan local Redis during drain: {}", e);
        }
    }
}
