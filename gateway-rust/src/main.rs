//! Rust API gateway (axum + tower + hyper).
//! Phase 0: health endpoint and graceful shutdown only. Routing arrives in phase 1.

use std::env;

use axum::{Router, routing::get};

#[tokio::main]
async fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".into());
    let app = Router::new().route("/healthz", get(|| async { "ok" }));

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}")).await.unwrap();
    println!("gateway-rust listening on :{port}");
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await.unwrap();
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
