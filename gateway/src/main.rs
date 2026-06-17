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
    let local_redis = LocalRedis::new(local_conn);

    let readcache_url = format!(
        "redis://{}:{}",
        config.readcache_host, config.readcache_port
    );
    let readcache_client = redis::Client::open(readcache_url.as_str())
        .expect("Failed to open read cache Redis client");
    let readcache_conn = redis::aio::ConnectionManager::new(readcache_client)
        .await
        .expect("Failed to connect to read cache Redis");
    let readcache = ReadCache::new(readcache_conn);

    let state = Arc::new(AppState {
        local_redis: Mutex::new(local_redis),
        readcache: Mutex::new(readcache),
    });

    let app = Router::new()
        .route("/increment/:key", post(routes::increment))
        .route("/count/:key", get(routes::count))
        .route("/health", get(routes::health))
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
