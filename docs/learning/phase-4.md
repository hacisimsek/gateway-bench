# Phase 4 — Observability and graceful shutdown

**Built:** both gateways now export Prometheus metrics, OpenTelemetry traces and JSON logs, and
the stack has Prometheus, Jaeger and a provisioned Grafana dashboard
([localhost:3000](http://localhost:3000)). Graceful shutdown, already in place since phase 0, is now tested.

![Grafana during the S2 benchmark](img/phase-4-grafana.jpg)

*The S2 benchmark in Grafana. Each hump is one rate step. Java (bottom left) spends up to ~80 %
of its time in full GC pauses (MarkSweepCompact) while its heap sits at the 384 MiB ceiling.
Gaps in the Java panels are scrapes that timed out while the JVM was paused.*

| | Rust | Java |
|---|---|---|
| Metrics | `metrics` + `metrics-exporter-prometheus`, `/metrics` | Micrometer Prometheus registry, `/actuator/prometheus` |
| Admin port | second axum listener on 9090 (`/healthz`, `/metrics`) | `management.server.port: 9090` |
| Traces | `tracing` + `tracing-opentelemetry`, OTLP/HTTP | Micrometer Tracing → OpenTelemetry, OTLP/HTTP |
| Spans per request | 1 (server span) | 8 (security filter chain, auth, Redis `EVALSHA`, HTTP client, …) |
| Trace to upstream | `traceparent` injected by hand in the proxy | automatic (instrumented HTTP client) |
| Logs | `tracing-subscriber` JSON (events only), `trace_id` added to each log line | Spring Boot structured logging (ECS), `traceId` from MDC |
| Config | standard `OTEL_*` env vars, read by the SDK | same env vars, mapped by Spring Boot |

## Decisions (asked before building)

- **Prometheus + Grafana + Jaeger** as three separate containers, the same pieces we will run in
  Kubernetes, rather than one all-in-one image.
- **10 % parent-based sampling.** If the caller already decided (a sampled `traceparent`), we follow it.
- **No per-request access log.** Logs are for events (startup, warnings, errors); metrics and
  traces describe requests.

## What we learned

- **One set of `OTEL_*` variables configures both.** The Rust SDK reads `OTEL_SERVICE_NAME`,
  `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_TRACES_SAMPLER(_ARG)` itself; Spring Boot 4 maps them to
  its own properties. Compose sets them once for both gateways.
- **Same metric, same buckets, one query.** Rust records `http_server_requests_seconds` with the
  buckets Micrometer is told to use (`management.metrics.distribution.slo`), so one PromQL
  query draws both lines. Gotcha: Spring parses these as durations, and `2.5ms` is not a valid
  duration. `2500us` is.
- **Separate admin port.** Probes and metrics never go through the public Ingress. Spring needs
  one property; Rust needs a second listener. Spring's tests then need `@LocalManagementPort`,
  plus `@AutoConfigureMetrics`, because Spring disables metrics export in tests by default.
- **Java instruments everything by default.** Micrometer Observation creates spans for every
  security filter, the Redis call and the outgoing HTTP call: 8 spans per request against Rust's 1.
  Rich traces, but 8× the data to export and store.
- **Unsampled requests still carry a `traceparent`** (flag `00`), so services behind the gateway
  follow the same sampling decision. The upstream mock now echoes the header it received, and
  the logged trace id matches it in both gateways.
- **Graceful shutdown works in both.** `make smoke-shutdown` sends SIGTERM while a 3 s request is
  in flight: the request finishes with 200 and each gateway exits within ~3 s, long before
  Docker's kill timeout.

## Cost of observability (S2: JWT + rate limit + metrics + 10 % tracing, median of 3)

Two S2 runs. The first exposed a Rust problem (below); the second ran after the fix.

- First run, before the fix: [20261108-120823-s2](../../bench/results/s1/20261108-120823-s2/results.md)
- Second run, Rust fixed: [20261108-125112-s2-fmtfix](../../bench/results/s1/20261108-125112-s2-fmtfix/results.md)
- Baseline without telemetry (phase 3): [20261108-100810-jwt-rl](../../bench/results/s1/20261108-100810-jwt-rl/results.md)

| | rate | phase 3 (no telemetry) | S2 before fix | S2 after fix |
|---|---:|---|---|---|
| rust p99 | 10 000 | 4.35 ms | 6.40 ms | **1.30 ms** |
| rust CPU | 10 000 | 75 % | 91 % | 79 % |
| rust p99 | 20 000 | 7.71 ms | 123.9 ms | **12.1 ms** |
| rust CPU | 20 000 | 119 % | 146 % | 132 % |
| java p99 | 5 000 | 17.25 ms | 15.06 ms | collapsed (see below) |
| java achieved | 10 000 | 1 269 rps | 963 rps | collapsed |

### Rust: profiling found the real cost, and it was not the one we guessed

The first S2 run put Rust at 20k rps close to its 2-CPU limit, with p99 between 22 and 193 ms.
Our first guess was the per-request histogram. **The profile said otherwise.**

How we profiled: we built the same gateway with symbols and frame pointers
([bench/profile/Dockerfile.rust-perf](../../bench/profile/Dockerfile.rust-perf)), ran `perf record -g`
inside the container for 20 s at 20k rps, and grouped samples by library
([before](../../bench/results/s1/20261108-120823-s2/probes/perf-before-fix.txt),
[after](../../bench/results/s1/20261108-120823-s2/probes-after-fix/perf-after-fix.txt)).

| where the gateway's CPU went at 20k rps | share |
|---|---:|
| kernel: network stack, scheduling | 31 % |
| JWT RS256 signature check (aws-lc) | 22 % |
| hyper / axum / tokio | 13 % |
| **tracing layers (JSON fmt + OpenTelemetry), inclusive** | **~12 %** |
| Redis client | 2 % |
| metrics / Prometheus histogram | **0.2 %** |

- **The culprit was the JSON log layer formatting span fields.** A `tracing-subscriber` fmt
  layer that sees spans serialises each span's fields to JSON when the span is created and again
  on every `record()`, even if nothing is ever logged. Our request span is created once and
  recorded into three times, so four JSON serialisations per request.
- **The fix is one filter:** the fmt layer now sees only events (`filter_fn(|m| m.is_event())`).
  Log lines get the trace id explicitly, `warn!(trace_id = %telemetry::trace_id(), …)`, and it
  is only computed when something is logged.
- **A/B after the fix, same machine, interleaved, 3 runs each at 20k rps:**
  phase 3 binary 125–128 % CPU, phase 4 binary 134–136 %. Telemetry now costs about **4 µs per
  request** instead of ~11 µs, and p99 is no worse than without telemetry (5 ms vs 6–14 ms).
  Raw data: [probes-after-fix/](../../bench/results/s1/20261108-120823-s2/probes-after-fix).
- **Lesson about our own probes.** Before profiling we "tested" the span theory with
  `RUST_LOG=warn docker compose up`. Compose only passes variables listed in `compose.yaml`,
  so that setting never reached the container, and the probe falsely cleared spans.
  The [probes/](../../bench/results/s1/20261108-120823-s2/probes) folder keeps that data;
  the `no-spans` runs are invalid.
- **The biggest application cost is now JWT verification**: RS256 is ~22 % of the CPU,
  ~15 µs per request. Faster algorithms (ES256, EdDSA) or caching verified tokens are possible
  future experiments.

### Java: at 5k rps it now sits on a cliff edge

In the first S2 run Java handled 5k rps (p99 15 ms). In the second run, with identical Java
code, **it fell over during the 5k warm-up and never recovered**: 100 % errors for the whole
benchmark, container at 512/512 MiB and one core busy.

We reproduced it with GC logging: the live set is 358 MB in a 371 MB heap, and the JVM runs
back-to-back full GCs (~145 ms each) that free nothing. **It stays like that minutes after the
load stops**: readiness times out and a diagnostic tool cannot even attach.

The same load with 1.5 GiB of memory shows why. Under load the live heap is 290–380 MB, and it
drains once the load stops. So **this is not a leak**:

1. Requests are still in flight (k6 allows up to 2 000), and each one holds buffers, security
   and observation contexts and 8 spans.
2. With a 384 MB heap that state *is* the heap.
3. The JVM spends all its CPU on GC, so those requests can never finish and free it.

Virtual threads make accepting work nearly free, so nothing pushes back. A concurrency limit
(load shedding) would turn this into fast 503s instead of a dead pod. That is a design topic for
both gateways, and a candidate for a later phase.

## Caveats

- Observability containers share the machine with the load generator, so S2 runs on a busier
  host than earlier phases. The interleaved A/B probes are the like-for-like comparison.
- Probes are short (30 s) runs, indicative only.
- The second run's Java numbers record the collapse; for working Java numbers under S2 use the first run.
- Java's p99 line in Grafana is capped at 10 s, the highest histogram bucket.
