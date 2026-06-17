use std::collections::HashMap;
use std::time::Duration;

use redis::aio::ConnectionManager;
use sqlx::Row;
use tokio::time::sleep;

/// Runs a periodic flush loop that drains counter deltas from this gateway
/// replica's local Redis, upserts them into Postgres, and updates the shared
/// read cache.
///
/// Each gateway replica flushes itself independently. This avoids the Docker
/// Swarm IPVS networking issue where direct container-IP connections on the
/// overlay network are blocked — no cross-container communication is needed.
pub async fn flush_loop(
    local_redis: ConnectionManager,
    pool: sqlx::PgPool,
    readcache: ConnectionManager,
    interval_ms: u64,
) {
    let interval = Duration::from_millis(interval_ms);

    loop {
        sleep(interval).await;

        if let Err(e) = sqlx::query("SELECT 1").execute(&pool).await {
            tracing::error!("Postgres health check failed: {}, skipping flush", e);
            continue;
        }

        let deltas = match scan_and_getdel(&local_redis).await {
            Ok(map) => map,
            Err(e) => {
                tracing::error!("Failed to scan local Redis: {}", e);
                continue;
            }
        };

        if deltas.is_empty() {
            tracing::debug!("No keys to flush this cycle");
            continue;
        }

        let n_keys = deltas.len();

        let mut tx = match pool.begin().await {
            Ok(tx) => tx,
            Err(e) => {
                tracing::error!("Failed to begin transaction: {}", e);
                continue;
            }
        };

        let mut totals: HashMap<String, i64> = HashMap::new();
        let mut tx_failed = false;

        for (key, delta) in &deltas {
            match sqlx::query(
                "INSERT INTO counters (key, value, last_updated)
                 VALUES ($1, $2, NOW())
                 ON CONFLICT (key) DO UPDATE
                 SET value = counters.value + EXCLUDED.value,
                     last_updated = NOW()
                 RETURNING value",
            )
            .bind(key)
            .bind(*delta)
            .fetch_one(&mut *tx)
            .await
            {
                Ok(row) => {
                    let total: i64 = row.get(0);
                    totals.insert(key.clone(), total);
                }
                Err(e) => {
                    tx_failed = true;
                    tracing::error!("Failed to upsert key {}: {}", key, e);
                    break;
                }
            }
        }

        if tx_failed {
            let _ = tx.rollback().await;
            continue;
        }

        if let Err(e) = tx.commit().await {
            tracing::error!("Failed to commit transaction: {}", e);
            continue;
        }

        // Update the shared read cache with the new totals from Postgres
        for (key, total) in &totals {
            let mut con = readcache.clone();
            if let Err(e) = redis::cmd("SET")
                .arg(format!("counter:{}", key))
                .arg(*total)
                .query_async::<_, ()>(&mut con)
                .await
            {
                tracing::error!("Failed to update read cache for key {}: {}", key, e);
            }
        }

        tracing::info!("Self-flushed {} keys to Postgres and read cache", n_keys);
    }
}

/// SCAN + GETDEL all counter:* keys from the local Redis, returning a map
/// of short key names to their accumulated deltas.
async fn scan_and_getdel(
    conn: &ConnectionManager,
) -> Result<HashMap<String, i64>, redis::RedisError> {
    let mut con = conn.clone();
    let mut keys = Vec::new();
    let mut cursor: i64 = 0;

    loop {
        let (next_cursor, batch): (i64, Vec<String>) = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg("counter:*")
            .arg("COUNT")
            .arg(100)
            .query_async(&mut con)
            .await?;
        keys.extend(batch);
        if next_cursor == 0 {
            break;
        }
        cursor = next_cursor;
    }

    if keys.is_empty() {
        return Ok(HashMap::new());
    }

    let mut pipe = redis::pipe();
    for key in &keys {
        pipe.cmd("GETDEL").arg(key.as_str());
    }

    let results: Vec<Option<i64>> = pipe.query_async(&mut con).await?;

    let mut map = HashMap::new();
    for (key, val) in keys.into_iter().zip(results.into_iter()) {
        if let Some(v) = val {
            let short_key = key.strip_prefix("counter:").unwrap_or(&key).to_string();
            map.insert(short_key, v);
        }
    }

    Ok(map)
}
