use redis::aio::ConnectionManager;

pub struct ReadCache {
    conn: ConnectionManager,
}

impl ReadCache {
    pub fn new(conn: ConnectionManager) -> Self {
        Self { conn }
    }

    pub async fn get(&self, key: &str) -> Result<Option<i64>, redis::RedisError> {
        let mut con = self.conn.clone();
        redis::cmd("GET")
            .arg(format!("counter:{}", key))
            .query_async(&mut con)
            .await
    }

    pub async fn incrby(&self, key: &str, delta: i64) -> Result<(), redis::RedisError> {
        let mut con = self.conn.clone();
        redis::cmd("INCRBY")
            .arg(format!("counter:{}", key))
            .arg(delta)
            .query_async(&mut con)
            .await
    }

    pub async fn set(&self, key: &str, value: i64) -> Result<(), redis::RedisError> {
        let mut con = self.conn.clone();
        redis::cmd("SET")
            .arg(format!("counter:{}", key))
            .arg(value)
            .query_async(&mut con)
            .await
    }
}
