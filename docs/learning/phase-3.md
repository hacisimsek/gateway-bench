# Phase 3 — Distributed rate limiting with Redis

**Built:** a token bucket per JWT subject, kept in Redis and shared by both gateways (and by any
number of replicas later in Kubernetes). One Lua file, [ratelimit/token_bucket.lua](../../ratelimit/token_bucket.lua),
holds the whole algorithm; both gateways load the same file and send it with `EVALSHA`.
Default limit: 10 requests/s per subject, burst 20. Over the limit: `429` with `Retry-After`.

| | Rust | Java |
|---|---|---|
| Where | axum middleware after auth ([ratelimit.rs](../../gateway-rust/src/ratelimit.rs)) | Servlet filter after Spring Security ([RateLimitFilter.java](../../gateway-java/src/main/java/dev/codewithhaci/gateway/RateLimitFilter.java)) |
| Redis client | `redis` crate, one multiplexed `ConnectionManager` | Spring Data Redis on Lettuce, one shared connection |
| Subject comes from | auth middleware puts it in request extensions | `SecurityContext` (`JwtAuthenticationToken.getName()` = `sub`) |
| Redis down | fail open after a 100 ms `tokio::time::timeout` | fail open after a 100 ms Lettuce command timeout |

## Decisions (asked before building)

- **Key = JWT `sub`.** Auth runs first, so the subject is already verified. IP-based keys break
  behind NAT and proxies.
- **Fail open.** If Redis is down the API stays up, unlimited, and logs a warning. Same default as
  Spring Cloud Gateway's reactive `RedisRateLimiter`.
- **One global limit from env**, not per route yet.

## Why a Lua script

A token bucket is read, compute, write. Done as separate commands, two gateways can read the
same token count and both let a request through. Redis runs a Lua script atomically, so
"take a token" is one indivisible step no matter how many gateways call it. The script also
reads Redis' own clock (`TIME`), so gateways with drifting clocks still agree.

Spring Cloud Gateway Server MVC has a built-in rate limiter, but it is Bucket4j-based. We skip
it so both gateways run byte-for-byte the same algorithm.

## Parity test

`make smoke-ratelimit` checks both gateways:

- 30 parallel requests with a fresh subject: exactly 20 pass, 10 get `429`.
- A `429` carries `Retry-After: 1`.
- **Shared bucket:** 20 requests through Rust drain the subject's bucket; the next 10 through
  Java all get `429`. Two different languages, one bucket.
- **Fail open:** with Redis stopped, both still return `200`.

## What we learned

- **Middleware order is the whole design.** The rate limiter needs the subject, so it must run
  after auth. In axum the layer added *last* runs *first*. In Spring, a plain `Filter` bean runs
  after the security filter chain (order -100), with the `SecurityContext` already filled.
- **Fail open has a price.** While Redis is down every request waits for the 100 ms timeout
  before going through. A circuit breaker (skip Redis for a while after a few failures) would
  fix that; noted for later.
- **Lazy connections matter for startup.** Both gateways start and serve even when Redis is not
  up yet (`ConnectionManager::new_lazy_with_config` in Rust; Lettuce is lazy by default).
  Otherwise a Redis restart would crash-loop every gateway pod.
- **Spring adds a Redis health indicator** to `/actuator/health` automatically. With Redis stopped,
  `/actuator/health` returns 503 but `/actuator/health/readiness` stays 200. That is what we want:
  with fail open, Redis down must not take pods out of service. Point probes at the groups, never
  at the aggregate.

## Cost of rate limiting (median of 3 runs, same limits as before, Java on default flags)

Limits raised to 1 000 000/s so no request is rejected: this measures one Redis round trip per
request. Raw data: [bench/results/s1/20261108-100810-jwt-rl](../../bench/results/s1/20261108-100810-jwt-rl/results.md),
compared with phase 2's JWT-only run.

| | rate | achieved | p50 JWT → +RL | p99 JWT → +RL | gateway CPU | Redis CPU |
|---|---:|---:|---|---|---|---:|
| rust | 5 000 | 5 000 | 0.22 → 0.21 ms | 1.92 → 0.78 ms | 40 → 43 % | 11 % |
| java | 5 000 | 4 992 | 0.40 → 0.52 ms | 4.27 → **17.25 ms** | 137 → 162 % | 11 % |
| rust | 10 000 | 10 000 | 0.19 → 0.26 ms | 1.98 → 4.35 ms | 64 → 75 % | 18 % |
| java | 10 000 | 1 800 → 1 269 | 1 067 → 1 506 ms | 2 527 → 3 592 ms | 120 → 118 % | 3 % |
| rust | 20 000 | 19 967 | 0.31 → 0.39 ms | 4.81 → 7.71 ms | 99 → 119 % | 26 % |

- **Rust absorbs the Redis call.** At 20k rps it adds ~0.1 ms at p50 and ~20 % of one core.
  The multiplexed connection pipelines every request's `EVALSHA` over one TCP socket.
- **Java was already at its edge, and this pushed it.** At 5k rps p99 rose from 4 ms to 17 ms
  and 225 iterations were dropped; at 10k achieved throughput fell from 1 800 to 1 269 rps.
  Same memory story as phases 1–2 (the container sits at its 512 MiB limit); not GC-logged this time.
- **Redis is not the bottleneck.** One Redis thread spent about a quarter of a core at 20k rps.

## Caveats

- Every benchmark request uses one token, so all traffic hits **one Redis key**. Real traffic
  spreads over many keys; a single hot key is the worst case for Redis and still fine here.
- The rust p99 drop at 5k (1.92 → 0.78 ms) is run-to-run noise, not an improvement.
- Same machine for everything, k6 drops some iterations at 20k.
