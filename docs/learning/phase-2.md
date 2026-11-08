# Phase 2 — JWT validation

**Built:** RS256 JWT validation on every proxied request in both gateways (`exp` with 60 s
clock skew, `iss`, signature). Health endpoints stay open. A dev key pair is generated
locally by `make keys` and never committed; `scripts/mint-jwt.sh` signs test tokens with openssl.

| | Rust | Java |
|---|---|---|
| Where | axum middleware wrapping only the proxy routes ([auth.rs](../../gateway-rust/src/auth.rs)) | Spring Security filter chain ([SecurityConfig.java](../../gateway-java/src/main/java/dev/codewithhaci/gateway/SecurityConfig.java)) |
| Library | `jsonwebtoken` with the aws-lc-rs crypto backend | `NimbusJwtDecoder` |
| Unknown route without token | 401 (auth runs before routing) | 401 (same) |

## Parity test

`make smoke-auth` sends the same eight cases to both gateways and fails if they disagree:
no token, valid, expired 30 s ago (inside skew), expired 1 h ago, wrong issuer,
tampered signature, signed by another key, Basic auth. Both now agree on all eight.

## What we learned

- **`issuer-uri` is not "check the issuer".** In Spring Boot it means "discover keys from this
  URL", even when a public key is configured. With a non-URL issuer it failed at the first
  request. Declaring the `JwtDecoder` bean by hand made the rules explicit and matched Rust's
  `JwtVerifier` one to one.
- **The parity test found a real difference on its first run.** Our minting script produced
  expired tokens with `iat` *after* `exp`. Spring rejects that as malformed; `jsonwebtoken`
  does not check `iat` at all. Fixed the script (a real expired token was issued before it
  expired); the strictness difference remains and is worth knowing.
- **Spring explains rejections, Rust doesn't.** Spring's 401 carries an `error_description`
  in `WWW-Authenticate`; ours returns a bare `Bearer`. Telling a client *why* a token failed
  is debatable on a public edge.

## Cost of JWT (median of 3 runs, same limits as phase 1, Java on default flags)

Raw data: [bench/results/s1/20261107-172853-jwt](../../bench/results/s1/20261107-172853-jwt/results.md).

| | rate | p50 no auth → JWT | p99 no auth → JWT | CPU no auth → JWT |
|---|---:|---|---|---|
| rust | 5 000 | 0.19 → 0.22 ms | 1.19 → 1.92 ms | 25 → 40 % |
| java | 5 000 | 0.31 → 0.40 ms | 3.07 → 4.27 ms | 101 → 137 % |
| rust | 10 000 | 0.15 → 0.19 ms | 1.44 → 1.98 ms | 40 → 64 % |
| **java** | **10 000** | 0.38 → **1 067 ms** | 5.96 → **2 527 ms** | 162 → 120 % |
| rust | 20 000 | 0.21 → 0.31 ms | 3.23 → 4.81 ms | 66 → 99 % |

- **RS256 verification costs roughly 20 µs of CPU per request in Rust and 70–100 µs in Java**
  (estimated from the CPU difference; docker stats sampling is coarse). Latency barely moves
  in Rust; the cost shows up as CPU.
- **JWT moved Java's collapse point from 20k to 10k rps.** Achieved throughput at 10k fell to
  ~1 800 rps. A GC-logged rerun showed the same mechanism as phase 1: Serial GC, 151 full GCs
  and 24.8 s of pause in 30 s. Each authenticated request allocates more (token parsing,
  security context), so the 512 MiB heap fills sooner.
- **Rust at 20k rps with JWT used half its CPU budget and under 100 MiB.**

## Caveats

- Same as phase 1: one machine, k6 drops some iterations at 20k (1 650 for rust here).
- Java runs with default JVM flags on purpose. Phase 1 showed G1 helps throughput but not the
  memory ceiling; a tuned Java profile is a separate experiment, not the default.
