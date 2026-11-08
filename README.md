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
| 1 | Routing proxy + first baseline benchmark (S1) | ✅ |
| 2 | JWT validation (RS256) + benchmark with auth | ✅ |
| 3 | Redis rate limiting (shared Lua token bucket) + benchmark | ✅ |
| 4 | Metrics, traces, JSON logs, graceful shutdown + full-chain benchmark (S2) | ✅ |
| 5–7 | CI, GitOps, full benchmarks | |

## Run locally

Only Docker is required; Rust and Java builds run inside containers.

```bash
make up          # generate dev JWT keys (first run), build and start everything
make smoke       # health check both gateways (admin ports)
make smoke-auth  # same JWT cases against both gateways; they must agree
make smoke-ratelimit  # 429s, a bucket shared by both gateways, fail open when Redis stops
make smoke-shutdown   # SIGTERM during a slow request: it still finishes with 200
make test        # unit tests for all services
make bench-jwt   # both gateways with a JWT on every request (~16 min)
make bench-s2    # full chain: JWT + rate limit + metrics + tracing (~16 min)
make down
```

Routes come from config, not code: [gateway-rust/routes.yaml](gateway-rust/routes.yaml) and
[gateway-java/.../application.yml](gateway-java/src/main/resources/application.yml).
Proxied routes need a JWT signed by the dev key in `.keys/` (generated locally, never committed):

```bash
TOKEN=$(scripts/mint-jwt.sh)
curl -H "Authorization: Bearer $TOKEN" localhost:8081/users/42   # rust
curl -H "Authorization: Bearer $TOKEN" localhost:8082/users/42   # java
```

Each token subject gets 10 requests/s with a burst of 20, counted in Redis across both gateways
([ratelimit/token_bucket.lua](ratelimit/token_bucket.lua)). Over the limit: `429` with `Retry-After`.
Change it with `RATE_LIMIT_PER_SECOND=… RATE_LIMIT_BURST=… docker compose up -d`.

Grafana at [localhost:3000](http://localhost:3000) opens on a Rust-vs-Java dashboard (traffic, p50/p99,
Java GC). Traces are in Jaeger at [localhost:16686](http://localhost:16686); every log line carries the trace id.

| Service | Port |
|---|---|
| upstream (mock backend) | 9000 |
| gateway-rust | 8081 (traffic), 9091 (`/healthz`, `/metrics`) |
| gateway-java | 8082 (traffic), 9092 (`/actuator/health/*`, `/actuator/prometheus`) |
| Grafana | 3000 |
| Prometheus | 9090 |
| Jaeger UI | 16686 |
| redis | internal only |
