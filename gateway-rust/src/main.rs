//! Rust API gateway (axum + tower + hyper).

mod auth;
mod config;
mod proxy;
mod ratelimit;

use std::{env, sync::Arc};

use axum::{Router, middleware, routing::get};
use hyper_util::{client::legacy::Client, rt::TokioExecutor};

use auth::JwtVerifier;
use config::Config;
use proxy::AppState;
use ratelimit::RateLimiter;

#[tokio::main]
async fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let routes_file = env::var("ROUTES_FILE").unwrap_or_else(|_| "/etc/gateway/routes.yaml".into());

    let config = Config::load(&routes_file);
    for r in &config.routes {
        println!("route {}: {} -> {}", r.id, r.path, r.uri);
    }
    // One pooled client for all routes: keep-alive connections are reused across requests.
    let client = Client::builder(TokioExecutor::new()).build_http();
    let state = Arc::new(AppState { config, client });
    let verifier = Arc::new(JwtVerifier::load(
        &env::var("JWT_PUBLIC_KEY_FILE").unwrap_or_else(|_| "/etc/gateway/jwt/public.pem".into()),
        &env::var("JWT_ISSUER").unwrap_or_else(|_| "gateway-bench".into()),
    ));
    let (per_second, burst) = (env_num("RATE_LIMIT_PER_SECOND", 10), env_num("RATE_LIMIT_BURST", 20));
    println!("rate limit: {per_second}/s per subject, burst {burst}");
    let limiter = Arc::new(RateLimiter::load(
        &env::var("REDIS_URL").unwrap_or_else(|_| "redis://redis:6379".into()),
        &env::var("RATE_LIMIT_SCRIPT_FILE").unwrap_or_else(|_| "/etc/gateway/ratelimit/token_bucket.lua".into()),
        per_second,
        burst,
    ));

    // Auth and rate limiting wrap only the proxied routes; health checks stay open for Kubernetes probes.
    // The layer added last runs first: auth, then the rate limiter (it needs the token's subject).
    let proxied = Router::new()
        .fallback(proxy::proxy)
        .layer(middleware::from_fn_with_state(limiter, ratelimit::rate_limit))
        .layer(middleware::from_fn_with_state(verifier, auth::require_jwt))
        .with_state(state);
    let app = Router::new().route("/healthz", get(|| async { "ok" })).merge(proxied);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("gateway-rust listening on :{port}");
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await.unwrap();
}

fn env_num(name: &str, default: u32) -> u32 {
    env::var(name).map_or(default, |v| v.parse().unwrap_or_else(|e| panic!("{name}={v}: {e}")))
}

/// Kubernetes sends SIGTERM before killing a pod; finish in-flight requests first.
async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    tokio::select! {
        _ = ctrl_c => {},
        _ = term.recv() => {},
    }
}
