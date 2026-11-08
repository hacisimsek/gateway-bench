//! Distributed rate limiting: one token bucket per JWT subject, stored in Redis.
//! The bucket logic is ratelimit/token_bucket.lua, the same file gateway-java runs,
//! so both gateways (and any number of replicas) share every user's bucket.

use std::{sync::Arc, time::Duration};

use axum::{
    extract::{Request, State},
    http::{HeaderName, HeaderValue, StatusCode, header},
    middleware::Next,
    response::{IntoResponse, Response},
};
use redis::{
    Script,
    aio::{ConnectionManager, ConnectionManagerConfig},
};

use crate::auth::Subject;

/// Past this, Redis counts as down and the request goes through unlimited (fail open).
const REDIS_TIMEOUT: Duration = Duration::from_millis(100);
const REMAINING: HeaderName = HeaderName::from_static("x-ratelimit-remaining");

pub struct RateLimiter {
    redis: ConnectionManager,
    script: Script,
    per_second: u32,
    burst: u32,
}

impl RateLimiter {
    pub fn load(redis_url: &str, script_file: &str, per_second: u32, burst: u32) -> Self {
        let lua = std::fs::read_to_string(script_file).unwrap_or_else(|e| panic!("cannot read {script_file}: {e}"));
        let client = redis::Client::open(redis_url).unwrap_or_else(|e| panic!("invalid redis url {redis_url}: {e}"));
        // Lazy: the gateway starts, and serves unlimited, even while Redis is still down.
        let redis = ConnectionManager::new_lazy_with_config(client, ConnectionManagerConfig::new())
            .expect("redis connection manager");
        Self { redis, script: Script::new(&lua), per_second, burst }
    }

    /// `(allowed, tokens left, ms until the next token)`, or `None` when Redis is unavailable.
    async fn take(&self, subject: &str) -> Option<(bool, i64, i64)> {
        let mut con = self.redis.clone(); // cheap: all clones share one multiplexed connection
        let mut call = self.script.prepare_invoke();
        call.key(format!("rl:{subject}")).arg(self.per_second).arg(self.burst);
        // EVALSHA, falling back to EVAL (which caches the script) the first time.
        match tokio::time::timeout(REDIS_TIMEOUT, call.invoke_async::<(i64, i64, i64)>(&mut con)).await {
            Ok(Ok((allowed, left, wait_ms))) => Some((allowed == 1, left, wait_ms)),
            Ok(Err(e)) => {
                tracing::warn!("rate limit skipped, redis error: {e}");
                None
            }
            Err(_) => {
                tracing::warn!("rate limit skipped, redis timeout");
                None
            }
        }
    }
}

/// Runs after `auth::require_jwt`, which puts the token's subject into the request extensions.
pub async fn rate_limit(State(limiter): State<Arc<RateLimiter>>, req: Request, next: Next) -> Response {
    let subject = req.extensions().get::<Subject>().map_or("", |s| s.0.as_str());
    match limiter.take(subject).await {
        None => next.run(req).await,
        Some((true, left, _)) => {
            let mut res = next.run(req).await;
            res.headers_mut().insert(REMAINING, HeaderValue::from(left));
            res
        }
        Some((false, _, wait_ms)) => (
            StatusCode::TOO_MANY_REQUESTS,
            [(header::RETRY_AFTER, HeaderValue::from((wait_ms + 999) / 1000)), (REMAINING, HeaderValue::from(0))],
        )
            .into_response(),
    }
}
