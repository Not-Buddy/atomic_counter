use axum::{extract::{Path, State}, Json};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::local_redis::LocalRedis;
use crate::readcache::ReadCache;

pub struct AppState {
    pub local_redis: Mutex<LocalRedis>,
    pub readcache: Mutex<ReadCache>,
}

pub async fn increment(
    State(state): State<Arc<AppState>>,
    Path(key): Path<String>,
) -> Json<Value> {
    let local = state.local_redis.lock().await;
    match local.incr(&key).await {
        Ok(value) => Json(json!({ "key": key, "local_value": value })),
        Err(e) => Json(json!({ "error": format!("{}", e) })),
    }
}

pub async fn count(
    State(state): State<Arc<AppState>>,
    Path(key): Path<String>,
) -> Json<Value> {
    let cache = state.readcache.lock().await;
    match cache.get(&key).await {
        Ok(Some(value)) => Json(json!({ "key": key, "count": value, "stale": true })),
        Ok(None) => Json(json!({ "key": key, "count": 0, "stale": true })),
        Err(e) => Json(json!({ "error": format!("{}", e) })),
    }
}

pub async fn health() -> Json<Value> {
    let host = hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string());
    Json(json!({ "status": "ok", "replica": host }))
}

/// Called by the aggregator to atomically drain all counter deltas from this
/// replica's local Redis. Returns a JSON map of `{ key: delta }` pairs.
/// Using HTTP on port 3000 avoids the Docker Swarm IPVS issue that blocks
/// direct container-IP connections to the embedded Redis on port 6379.
pub async fn flush(
    State(state): State<Arc<AppState>>,
) -> Json<Value> {
    let local = state.local_redis.lock().await;
    match local.scan_and_getdel().await {
        Ok(map) => {
            tracing::info!("Flush endpoint: drained {} keys", map.len());
            Json(json!(map))
        }
        Err(e) => {
            tracing::error!("Flush endpoint failed: {}", e);
            Json(json!({ "error": format!("{}", e) }))
        }
    }
}
