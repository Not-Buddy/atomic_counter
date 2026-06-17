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
