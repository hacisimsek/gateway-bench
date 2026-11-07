# gateway-bench

The same API gateway built twice — in **Rust** (axum + tower + hyper) and in **Java 25**
(Spring Cloud Gateway Server MVC on virtual threads) — with identical features, identical
Kubernetes deployment, and identical load tests.

A learning project: every phase adds one concept to both gateways and measures the result.
See [docs/DESIGN.md](docs/DESIGN.md) for the full design.

## Status

| Phase | | |
|---|---|---|
| 0 | Bootstrap: services, Docker Compose, Makefile | ✅ |
| 1 | Routing proxy + first baseline benchmark | ⏳ |
| 2–7 | JWT, rate limiting, observability, CI, GitOps, full benchmarks | |

## Run locally

Only Docker is required; Rust and Java builds run inside containers.

```bash
make up      # build and start upstream, gateway-rust, gateway-java
make smoke   # health check all three
make test    # unit tests for all services
make down
```

| Service | Port |
|---|---|
| upstream (mock backend) | 9000 |
| gateway-rust | 8081 |
| gateway-java | 8082 |
