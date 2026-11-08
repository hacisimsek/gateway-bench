# Phase 5 — CI, smaller images, faster Java startup

**Built:** a GitHub Actions pipeline ([ci.yml](../../.github/workflows/ci.yml)) and slimmer images
for all three services.

```
push / PR ──► unit tests (make test) ─────────┐
          └─► parity tests on the full stack ─┴─► main only: build 3 images × {amd64, arm64}
                                                   natively ──► one multi-arch tag per image
                                                   ghcr.io/hacisimsek/gateway-bench/<service>:sha-<commit>
```

## Decisions (asked before building)

- **Rust: distroless `cc-debian13`.** glibc, CA certificates, no shell. Same code, same allocator,
  same performance. A static musl build would be smaller, but musl's allocator is slow and
  would skew the benchmarks.
- **Java: jlink + AOT cache.** A JRE trimmed to the modules the app uses, plus Java 25's AOT cache
  (Project Leyden). GraalVM native image was ruled out: it changes the runtime, and the
  comparison is "Java 25 with virtual threads", not "native Java".
- **amd64 + arm64, built natively.** Each architecture builds on its own GitHub runner, so there
  is no QEMU emulation. The Java AOT cache is also trained on the CPU it will run on. arm64
  matters here: the phase 6 kind cluster runs on an Apple Silicon Mac.
- **CI runs the parity tests**, not just unit tests: `smoke-auth`, `smoke-ratelimit` and
  `smoke-shutdown` against both gateways on the real Compose stack.

## Results (`make cold-start`, median of 5; sizes as `docker image inspect` reports them)

| | image before | image after | ready before | ready after |
|---|---:|---:|---:|---:|
| upstream | 31 MB | 12 MB | | |
| gateway-rust | 34 MB | **14 MB** | 175 ms | 172 ms |
| gateway-java | 159 MB | **133 MB** | 3 400 ms | **1 508 ms** |

"Ready" is from `docker start` until the readiness endpoint answers 200, so it includes
Docker's own ~150 ms. Rust's startup was already almost all Docker.

**Where Java's 1.9 s went:**

| change | ready |
|---|---:|
| before: full JRE, fat jar | 3 400 ms |
| jlink JRE + unpacked jar, AOT cache off (`-XX:AOTMode=off`) | 2 797 ms |
| + AOT cache | **1 508 ms** |

**What is inside the Java image (uncompressed):**

| | |
|---|---:|
| AOT cache (`app.aot`) | 102 MB |
| jlink JRE (the full Temurin 25 JRE is 199 MB) | 65 MB |
| dependencies (`lib/`) | 64 MB |
| distroless base | 38 MB |

The AOT cache is now the largest part of the image: 102 MB buys 1.3 s of startup. That is a
good trade for autoscaling and rolling deploys, and a poor one if image pulls are the bottleneck.

## What we learned

- **The AOT cache is a recording of one startup.** The build runs the app once with
  `-XX:AOTCacheOutput` and `-Dspring.context.exit=onRefresh`, which starts the Spring context and
  exits. It must use the same JRE and the same jar paths as production, so the training run uses
  the jlink'ed JRE at `/opt/jre` and the app at `/app`. Real config (JWT key, Lua script) is not
  needed; throwaway stand-ins are enough.
- **jlink needs help.** `jdeps --recursive` finds most modules. Ones loaded by reflection or
  service lookup (`jdk.management` for metrics, `jdk.naming.dns`) have to be listed by hand.
- **Temurin's JDK lives at `/opt/java`**, so jlink's output went to `/opt/jre`.
- **The local CI dry run found a flaky test.** `smoke-auth` tampered with the *last* character
  of the signature. In base64url that character's low bits are padding, so 1 time in 4 the edit
  decodes to the same bytes. Then Java (Nimbus) accepts the token, while Rust's `base64`
  rejects the non-canonical encoding. That is not a security hole, since the signature bytes are
  identical. It is a real strictness difference, and a test that passed by luck. The test now
  edits a character in the middle of the signature.
- **Bake builds the same images as Compose.** CI builds with `docker buildx bake -f compose.yaml`
  so it can use the GitHub Actions layer cache, then runs `docker compose up --no-build` on those
  images.
