use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

struct Config {
    database_url: String,
}

impl Config {
    fn from_env() -> Self {
        Self {
            database_url: std::env::var("DATABASE_URL").expect("DATABASE_URL must be set"),
        }
    }
}

/// The aggregator now serves as a migration runner and health monitor.
///
/// Counter flushing has been moved into each gateway replica (self-flush),
/// which avoids the Docker Swarm IPVS issue that blocked the aggregator
/// from reaching individual gateway containers on their overlay IPs.
#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer())
        .init();

    let config = Config::from_env();

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

    tracing::info!("Aggregator started — migrations applied, gateway replicas handle their own flushing");

    let mut term_signal =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler");
    term_signal.recv().await;
    tracing::info!("Aggregator shutting down cleanly");
}
