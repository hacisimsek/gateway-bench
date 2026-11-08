//! Rust API gateway (axum + tower + hyper).

mod auth;
mod config;
mod proxy;
mod ratelimit;
mod telemetry;

use std::{env, sync::Arc};

use axum::{Router, middleware, routing::get};
use tracing::info;
use hyper_util::{client::legacy::Client, rt::TokioExecutor};

use auth::JwtVerifier;
use config::Config;
use proxy::AppState;
use ratelimit::RateLimiter;

#[tokio::main]
async fn main() {
    let (prometheus, traces) = telemetry::init();
    tokio::spawn(telemetry::run_upkeep(prometheus.clone()));
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let admin_port = env::var("ADMIN_PORT").unwrap_or_else(|_| "9090".into());
    let routes_file = env::var("ROUTES_FILE").unwrap_or_else(|_| "/etc/gateway/routes.yaml".into());

    let config = Config::load(&routes_file);
    for r in &config.routes {
        info!("route {}: {} -> {}", r.id, r.path, r.uri);
    }
    // One pooled client for all routes: keep-alive connections are reused across requests.
    let client = Client::builder(TokioExecutor::new()).build_http();
    let state = Arc::new(AppState { config, client });
    let verifier = Arc::new(JwtVerifier::load(
        &env::var("JWT_PUBLIC_KEY_FILE").unwrap_or_else(|_| "/etc/gateway/jwt/public.pem".into()),
        &env::var("JWT_ISSUER").unwrap_or_else(|_| "gateway-bench".into()),
    ));
    let (per_second, burst) = (env_num("RATE_LIMIT_PER_SECOND", 10), env_num("RATE_LIMIT_BURST", 20));
    info!("rate limit: {per_second}/s per subject, burst {burst}");
    let limiter = Arc::new(RateLimiter::load(
        &env::var("REDIS_URL").unwrap_or_else(|_| "redis://redis:6379".into()),
        &env::var("RATE_LIMIT_SCRIPT_FILE").unwrap_or_else(|_| "/etc/gateway/ratelimit/token_bucket.lua".into()),
        per_second,
        burst,
    ));

    // The layer added last runs first: observe (span + metrics), auth, then the rate limiter
    // (it needs the token's subject).
    let app = Router::new()
        .fallback(proxy::proxy)
        .layer(middleware::from_fn_with_state(limiter, ratelimit::rate_limit))
        .layer(middleware::from_fn_with_state(verifier, auth::require_jwt))
        .layer(middleware::from_fn(telemetry::observe))
        .with_state(state);
    // Probes and metrics on their own port, never exposed through the Ingress (same as Spring's management port).
    let admin = Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/metrics", get(move || async move { prometheus.render() }));

    let admin_listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{admin_port}")).await.unwrap();
    tokio::spawn(async { axum::serve(admin_listener, admin).await.unwrap() });
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    info!("gateway-rust listening on :{port}, admin on :{admin_port}");
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await.unwrap();
    info!("drained, shutting down");
    let _ = traces.shutdown(); // flush the last batch of spans
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
