use axum::{extract::{Path, State}, http::StatusCode, response::IntoResponse, Json};
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
) -> impl IntoResponse {
    let local = state.local_redis.lock().await;
    match local.incr(&key).await {
        Ok(value) => (StatusCode::OK, Json(json!({ "key": key, "local_value": value }))),
        Err(e) => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": format!("{}", e) }))),
    }
}

pub async fn count(
    State(state): State<Arc<AppState>>,
    Path(key): Path<String>,
) -> impl IntoResponse {
    let cache = state.readcache.lock().await;
    match cache.get(&key).await {
        Ok(Some(value)) => (StatusCode::OK, Json(json!({ "key": key, "count": value, "stale": true }))),
        Ok(None) => (StatusCode::OK, Json(json!({ "key": key, "count": 0, "stale": true }))),
        Err(e) => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": format!("{}", e) }))),
    }
}

pub async fn health() -> Json<Value> {
    let host = hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string());
    Json(json!({ "status": "ok", "replica": host }))
}

pub async fn flush(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let local = state.local_redis.lock().await;
    match local.scan_and_getdel().await {
        Ok(map) => {
            tracing::info!("Flush endpoint: drained {} keys", map.len());
            (StatusCode::OK, Json(json!(map)))
        }
        Err(e) => {
            tracing::error!("Flush endpoint failed: {}", e);
            (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "error": format!("{}", e) })))
        }
    }
}
