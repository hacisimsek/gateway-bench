# Phase 0 — Bootstrap

**Built:** a mock upstream (Rust), empty Rust and Java gateways with health endpoints,
Docker Compose with equal CPU/memory limits, and a Makefile that builds and tests everything in Docker.

## What we learned

- **Same idea, two ecosystems.** Cargo (`Cargo.toml` + `Cargo.lock`) and Maven (`pom.xml` + wrapper)
  both pin dependencies; committing `Cargo.lock` makes Rust builds reproducible, the Spring Cloud
  BOM does the same job for Java.
- **Dependency-first Docker layers.** Both Dockerfiles copy only the manifest first and resolve
  dependencies, so rebuilding after a code change skips the slow download/compile step.
- **Graceful shutdown is explicit in Rust, a setting in Spring.** Rust listens for SIGTERM with
  `tokio::signal` and lets `axum::serve` drain; Spring does it with `server.shutdown: graceful`.
- **Virtual threads are one line in Spring Boot:** `spring.threads.virtual.enabled: true`.
  Rust's equivalent is the tokio runtime started by `#[tokio::main]`.

## First numbers (not a benchmark yet)

| | gateway-rust | gateway-java |
|---|---|---|
| Image size | 142 MB | 517 MB |

Most of both sizes is the base image (Debian slim vs. Ubuntu + JRE), not our code.
Phase 5 looks at slimmer bases (distroless, jlink).
