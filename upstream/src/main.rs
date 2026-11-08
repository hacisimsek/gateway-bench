//! Mock backend shared by both gateways. Echoes the request as JSON after an
//! optional delay, so benchmarks measure the gateway, not the backend.

use std::{env, sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::{Request, State},
    http::HeaderMap,
    routing::get,
};
use serde_json::{Value, json};

const MAX_DELAY_MS: u64 = 10_000;

struct Config {
    name: String,
    default_delay_ms: u64,
}

#[tokio::main]
async fn main() {
    let config = Arc::new(Config {
        name: env::var("SERVICE_NAME").unwrap_or_else(|_| "upstream".into()),
        default_delay_ms: env::var("DELAY_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(0),
    });
    let port = env::var("PORT").unwrap_or_else(|_| "9000".into());

    let app = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .fallback(echo)
        .with_state(config);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("upstream listening on :{port}");
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await.unwrap();
}

async fn echo(State(config): State<Arc<Config>>, req: Request) -> Json<Value> {
    let delay = delay_ms(req.headers(), config.default_delay_ms);
    if delay > 0 {
        tokio::time::sleep(Duration::from_millis(delay)).await;
    }
    Json(json!({
        "service": config.name,
        "method": req.method().as_str(),
        "path": req.uri().path(),
        "delay_ms": delay,
        // Shows whether the gateway passed the trace on (W3C trace context).
        "traceparent": req.headers().get("traceparent").and_then(|v| v.to_str().ok()),
    }))
}

/// `x-delay-ms` header overrides the default; capped so a bad client can't park connections forever.
fn delay_ms(headers: &HeaderMap, default: u64) -> u64 {
    headers
        .get("x-delay-ms")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
        .min(MAX_DELAY_MS)
}

async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    tokio::select! {
        _ = ctrl_c => {},
        _ = term.recv() => {},
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(v: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert("x-delay-ms", v.parse().unwrap());
        h
    }

    #[test]
    fn delay_header_overrides_default_and_is_capped() {
        assert_eq!(delay_ms(&HeaderMap::new(), 5), 5);
        assert_eq!(delay_ms(&headers("200"), 5), 200);
        assert_eq!(delay_ms(&headers("abc"), 5), 5);
        assert_eq!(delay_ms(&headers("999999"), 5), MAX_DELAY_MS);
    }
}
