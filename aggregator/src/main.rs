use std::collections::HashMap;
use std::net::IpAddr;
use std::time::Duration;

use futures::future::join_all;
use sqlx::Row;
use tokio::time::sleep;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use trust_dns_resolver::config::{
    NameServerConfig, NameServerConfigGroup, Protocol, ResolverConfig, ResolverOpts,
};
use trust_dns_resolver::TokioAsyncResolver;

struct Config {
    gateway_service_name: String,
    gateway_redis_port: u16,
    flush_interval_ms: u64,
    database_url: String,
    readcache_host: String,
    readcache_port: u16,
}

impl Config {
    fn from_env() -> Self {
        Self {
            gateway_service_name: std::env::var("GATEWAY_SERVICE_NAME")
                .unwrap_or_else(|_| "gateway".into()),
            gateway_redis_port: std::env::var("GATEWAY_REDIS_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(6379),
            flush_interval_ms: std::env::var("FLUSH_INTERVAL_MS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(10000),
            database_url: std::env::var("DATABASE_URL").expect("DATABASE_URL must be set"),
            readcache_host: std::env::var("READCACHE_HOST")
                .unwrap_or_else(|_| "redis-readcache".into()),
            readcache_port: std::env::var("READCACHE_PORT")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(6379),
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

    let pool = sqlx::PgPool::connect(&config.database_url)
        .await
        .expect("Failed to connect to Postgres");

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

    let readcache_url = format!(
        "redis://{}:{}",
        config.readcache_host, config.readcache_port
    );
    let readcache_client =
        redis::Client::open(readcache_url.as_str()).expect("Failed to open read cache client");
    let readcache_conn = redis::aio::ConnectionManager::new(readcache_client)
        .await
        .expect("Failed to connect to read cache Redis");

    tokio::spawn(flush_loop(
        pool,
        readcache_conn,
        config.gateway_service_name,
        config.gateway_redis_port,
        config.flush_interval_ms,
    ));

    let mut term_signal =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler");
    term_signal.recv().await;
    tracing::info!("Aggregator shutting down cleanly");
}

async fn flush_loop(
    pool: sqlx::PgPool,
    readcache: redis::aio::ConnectionManager,
    service_name: String,
    redis_port: u16,
    interval_ms: u64,
) {
    let resolver = build_resolver();
    let interval = Duration::from_millis(interval_ms);

    loop {
        sleep(interval).await;

        if let Err(e) = sqlx::query("SELECT 1").execute(&pool).await {
            tracing::error!("Postgres health check failed: {}, skipping cycle", e);
            continue;
        }

        let dns_name = format!("tasks.{}", service_name);
        let ips: Vec<IpAddr> = match resolver.lookup_ip(&dns_name).await {
            Ok(lookup) => lookup.iter().collect(),
            Err(e) => {
                tracing::warn!(
                    "DNS resolution failed for {}: {}, skipping cycle",
                    dns_name,
                    e
                );
                continue;
            }
        };

        if ips.is_empty() {
            tracing::warn!(
                "No gateway replicas found for {}, skipping cycle",
                dns_name
            );
            continue;
        }

        let futs: Vec<_> = ips
            .iter()
            .map(|ip| timed_fetch(*ip, redis_port))
            .collect();

        let results = join_all(futs).await;

        let mut aggregate: HashMap<String, i64> = HashMap::new();
        let mut reachable = 0usize;
        let mut unreachable = 0usize;

        for (i, result) in results.into_iter().enumerate() {
            match result {
                Ok(Ok(map)) => {
                    reachable += 1;
                    for (key, delta) in map {
                        *aggregate.entry(key).or_insert(0) += delta;
                    }
                }
                Ok(Err(e)) => {
                    unreachable += 1;
                    tracing::error!("Failed to reach replica {}: {}", ips[i], e);
                }
                Err(_elapsed) => {
                    unreachable += 1;
                    tracing::error!("Timeout reaching replica {}", ips[i]);
                }
            }
        }

        let n_keys = aggregate.len();

        if aggregate.is_empty() {
            tracing::info!(
                "Flushed 0 keys from {} replicas, skipped {} unreachable",
                reachable,
                unreachable
            );
            continue;
        }

        let mut tx = match pool.begin().await {
            Ok(tx) => tx,
            Err(e) => {
                tracing::error!("Failed to begin transaction: {}", e);
                continue;
            }
        };

        let mut totals: HashMap<String, i64> = HashMap::new();
        let mut tx_failed = false;

        for (key, delta) in &aggregate {
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

        tracing::info!(
            "Flushed {} keys from {} replicas, skipped {} unreachable",
            n_keys,
            reachable,
            unreachable
        );
    }
}

fn build_resolver() -> TokioAsyncResolver {
    let mut group = NameServerConfigGroup::new();
    group.push(NameServerConfig {
        socket_addr: std::net::SocketAddr::new(
            std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 11)),
            53,
        ),
        protocol: Protocol::Udp,
        tls_dns_name: None,
        trust_negative_responses: true,
        bind_addr: None,
    });

    let config = ResolverConfig::from_parts(None, vec![], group);
    let mut opts = ResolverOpts::default();
    opts.use_hosts_file = false;
    opts.edns0 = false;
    opts.cache_size = 0;

    TokioAsyncResolver::tokio(config, opts)
}

async fn timed_fetch(
    ip: IpAddr,
    port: u16,
) -> Result<
    Result<HashMap<String, i64>, Box<dyn std::error::Error + Send + Sync>>,
    tokio::time::error::Elapsed,
> {
    tokio::time::timeout(Duration::from_secs(2), fetch_from_replica(ip, port)).await
}

async fn fetch_from_replica(
    ip: IpAddr,
    port: u16,
) -> Result<HashMap<String, i64>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!("redis://{}:{}/", ip, port);
    let client = redis::Client::open(url.as_str())?;
    let mut con = redis::aio::ConnectionManager::new(client).await?;

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
