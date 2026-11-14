# Results: Rust vs Java gateway

All runs: Apple M4 Pro, Docker Desktop (12 CPUs, 8 GiB), k6 at a constant arrival rate, 3 runs
per rate, **median** shown. Each gateway gets **2 CPUs**. Raw data and per-run JSON are in
[bench/results/s1/](../bench/results/s1/); each folder has `env.txt` (limits, flags, commit) and
`results.md`.

## Headline (fair settings)

Full chain on every request: RS256 JWT check, Redis rate limit (limits raised so nothing is
rejected), Prometheus metrics, OTLP tracing. Both gateways: 2 CPU / 1 GiB. Java with `-XX:+UseG1GC`.
Folder: [20261114-124852-s2-fair](../bench/results/s1/20261114-124852-s2-fair/results.md).

| rate | | achieved rps | p50 ms | p99 ms | CPU % | memory MiB | errors |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1k | Rust | 1 000 | 0.47 | 2.3 | 25 | 42 | 0 |
| | Java | 1 000 | 0.64 | 3.6 | 64 | 1 009 | 0 |
| 5k | Rust | 5 000 | 0.23 | **1.8** | 49 | 49 | 0 |
| | Java | 5 000 | 0.52 | 10.5 | 184 | 678 | 0 |
| 10k | Rust | 10 000 | 0.29 | 3.9 | 88 | 128 | 0 |
| | Java | **4 629** | 367 | 1 648 | 193 (full) | 1 021 | 0 |
| 20k | Rust | 19 958 | 0.56 | 31 | 131 | 136 | 0 |
| | Java | **4 623** | 410 | 1 009 | 189 (full) | 1 020 | 0 |

| startup and size (`make cold-start`) | Rust | Java |
|---|---:|---:|
| image | 14 MB | 133 MB |
| ready after `docker start` | 172 ms | 1.5 s (AOT cache; 3.4 s without) |
| source lines (main code + config) | 453 | 230 |

## What the numbers say

- **Throughput:** with 2 CPUs Java saturates at about **4.6k rps**; Rust carries **20k rps** at
  65 % of its CPU budget. That is at least **4.3×**, and 20k was the top of the test, not Rust's limit.
- **CPU per request:** at 5k rps Rust uses 49 % CPU, Java 184 %, about **3.8×** less.
- **Memory:** Rust stays at 40–140 MiB. Java grows into whatever it is given (it is a JVM: unused
  heap is not returned), so the pod size, not the live set, is the real cost.
- **Low load:** at 1k rps the difference is small (p99 2.3 vs 3.6 ms). Users would not notice it.
- **Overload:** neither gateway sheds load. Past its limit Java queues and latency climbs to
  1–2 s, still with 0 errors. A concurrency limit would turn that into fast 503s.

## The JVM settings matter more than anything else

The same Java code at its default settings (2 CPU / 512 MiB, where the JVM picks Serial GC):

| Java at 10k rps | 512 MiB, default GC | 1 GiB, G1 |
|---|---:|---:|
| achieved rps | 963–1 269 | **4 629** |
| behaviour | GC death spiral; one run 100 % errors | stable, CPU-bound, 0 errors |

At 512 MiB the in-flight requests fill the heap and the JVM runs back-to-back full GCs that free
nothing (see [phase 4 notes](learning/phase-4.md)). Raising memory and choosing G1 gave about
**4× the throughput** and removed the collapse. Comparisons against Java at default settings
overstate Rust's lead.

## Earlier runs (same 2 CPU / 512 MiB, Java default GC unless noted)

| folder | what | Rust @20k | Java @10k / @20k |
|---|---|---|---|
| [20261107-164406](../bench/results/s1/20261107-164406/results.md) | proxy only, plus direct-to-upstream baseline | 19 963 rps, p99 3.2 ms | 9 997 / 4 382 rps |
| [20261107-171124-java-g1](../bench/results/s1/20261107-171124-java-g1/results.md) | proxy only, Java with G1 | – | 9 992 / 7 499 rps |
| [20261107-172853-jwt](../bench/results/s1/20261107-172853-jwt/results.md) | + JWT | 19 944 rps, p99 4.8 ms | 1 800 / 1 667 rps |
| [20261108-100810-jwt-rl](../bench/results/s1/20261108-100810-jwt-rl/results.md) | + Redis rate limit | 19 967 rps, p99 7.7 ms | 1 269 / 1 243 rps |
| [20261108-120823-s2](../bench/results/s1/20261108-120823-s2/results.md) | + metrics and tracing (before the Rust log fix) | 19 450 rps, p99 124 ms | 963 / 1 043 rps |
| [20261108-125112-s2-fmtfix](../bench/results/s1/20261108-125112-s2-fmtfix/results.md) | after the Rust log fix | 19 974 rps, p99 12.1 ms | invalid: Java was still stuck in the GC spiral |

## Caveats

- One laptop, Docker Desktop, load generator on the same machine. Compare the gateways with each
  other, not with production numbers.
- In the fair run, run 2 of 3 hit a host hiccup: Rust's 10k and 20k fell to ~5.5k rps and both
  gateways' 1k p99 rose to ~29 ms. Runs 1 and 3 agree, so the median is used.
- Not tested: Rust above 20k rps, more than 2 CPUs, load shedding.

## Recommendation

- **High-traffic gateway, cost matters: Rust.** Even with fair JVM settings it carries over 4× the
  traffic on the same CPUs, uses about 4× less CPU per request and a fraction of the memory, and is
  ready in under 0.2 s.
- **Team knows Java and traffic is a few thousand rps per pod: Java is fine**, with these settings:
  G1 GC (the JVM does not pick it on 2 CPUs), at least 1 GiB, and a concurrency limit so a spike
  gives fast 503s instead of seconds of latency. In return the code is half the size and Spring's
  ecosystem (security, actuator, gateway filters) does most of the work.
