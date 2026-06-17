use redis::aio::ConnectionManager;
use std::collections::HashMap;

pub struct LocalRedis {
    conn: ConnectionManager,
}

impl LocalRedis {
    pub fn new(conn: ConnectionManager) -> Self {
        Self { conn }
    }

    pub async fn incr(&self, key: &str) -> Result<i64, redis::RedisError> {
        let mut con = self.conn.clone();
        redis::AsyncCommands::incr(&mut con, format!("counter:{}", key), 1).await
    }

    pub async fn scan_and_getdel(&self) -> Result<HashMap<String, i64>, redis::RedisError> {
        let mut con = self.conn.clone();
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
            pipe.cmd("GETDEL").arg(key);
        }

        let results: Vec<Option<i64>> = pipe.query_async(&mut con).await?;

        let mut map = HashMap::new();
        for (key, val) in keys.into_iter().zip(results.into_iter()) {
            if let Some(v) = val {
                let short_key = key
                    .strip_prefix("counter:")
                    .unwrap_or(&key)
                    .to_string();
                map.insert(short_key, v);
            }
        }

        Ok(map)
    }
}
