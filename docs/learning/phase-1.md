# Phase 1 — Routing proxy and the first baseline (S1)

**Built:** path-prefix routing in both gateways, configured from YAML (no code in Java at all),
and the S1 passthrough benchmark: k6 at fixed rates against the upstream directly, then
through each gateway. Raw data: [bench/results/s1/20261107-164406](../../bench/results/s1/20261107-164406/results.md).

## Results (median of 3 runs, 0 ms upstream)

Limits: each gateway 2 CPU / 512 MiB · upstream 4 CPU · k6 4 CPU · Apple M4 Pro, Docker Desktop.

| target | offered rps | achieved rps | p50 ms | p99 ms | cpu % | mem MiB |
|---|---:|---:|---:|---:|---:|---:|
| direct | 5 000 | 5 000 | 0.18 | 1.50 | 22 | 78 |
| rust | 5 000 | 5 000 | 0.19 | 1.19 | 25 | 55 |
| java | 5 000 | 5 000 | 0.31 | 3.07 | 101 | 495 |
| direct | 10 000 | 9 984 | 0.14 | 4.23 | 30 | 83 |
| rust | 10 000 | 10 000 | 0.15 | 1.44 | 40 | 71 |
| java | 10 000 | 9 997 | 0.38 | 5.96 | 162 | 497 |
| rust | 20 000 | 19 963 | 0.21 | 3.23 | 66 | 73 |
| **java** | **20 000** | **4 382** | **435** | **867** | 124 | 510 |

(cpu % is of one core, so 200 % = the full 2-CPU limit.)

## What we learned

- **Both gateways add well under a millisecond at the median** up to 10k rps. At this level
  the network hop costs more than the gateway logic.
- **Rust used about a third of its CPU budget at 20k rps and ~70 MiB of memory.**
  It still has headroom; the next limit we hit is the load generator, not the gateway.
- **Java collapsed at 20k rps — and the cause was the JVM's defaults, not Java.**
  A GC-logged rerun showed:
  - The JVM chose **Serial GC** (single-threaded). It does this automatically when it sees
    fewer than 2 CPUs *or* less than ~1.8 GiB of memory, which a 512 MiB container is.
  - In 30 s at 20k rps there were **193 full GCs, 24 s of total pause**: the gateway was stopped
    ~80 % of the time. Once requests queue up, more are in flight, the live heap grows,
    and GC runs even more often: a classic overload spiral.
  - Throughput fell *below* what it handled at 10k. Overload doesn't plateau, it collapses.
- **Container defaults matter as much as the language.** "Java in a 512 MiB container with
  default flags" and "Java tuned for its container" are different things to measure.

## Experiment: same limits, G1 instead of Serial

Same 2 CPU / 512 MiB, only `-XX:+UseG1GC` added
([results](../../bench/results/s1/20261107-171124-java-g1/results.md), median of 3 runs).

| Java @ 20k offered | Serial (default) | G1 |
|---|---:|---:|
| achieved rps | 4 382 | **7 499** |
| p50 | 435 ms | **153 ms** |
| p99 | **867 ms** | 4 746 ms |
| CPU | 124 % | 193 % |
| time paused in GC (30 s, GC-logged run) | 24.0 s (80 %) | 15.6 s (52 %) |
| full GCs in 30 s | 193 | 123 |

- **G1 helps throughput by ~70 %** and finally uses the whole CPU budget, because collection
  work runs on multiple threads instead of one.
- **But the tail gets worse.** G1 keeps most requests moving and lets a few wait behind
  repeated full GCs, so p50 improves while p99 jumps to seconds.
- **The real limit is memory, not the collector.** After every full GC, ~270 MiB of the
  384 MiB heap is still live. That is the backlog: ~2 000 requests in flight, each holding
  buffers on the Tomcat side and the upstream-client side. A bigger heap or fewer in-flight
  requests would help more than another GC.
- **Rust handled the same 20k rps in ~70 MiB.** Memory per in-flight request is the
  difference to watch in later phases (S4 pushes exactly this).
- Java's comfortable ceiling here is around 10k rps (162 % CPU at 10k); beyond that, any
  overload turns into a memory problem.

## Caveats

- At 20k rps k6 itself starts to drop iterations (also against the upstream directly), so
  20k numbers for direct and rust are partly load-generator bound.
- Single machine: load generator, gateways and upstream share the same CPUs. Read the
  comparison, not the absolute numbers.
- Java memory looks flat at ~495 MiB because the JVM reserves heap up front
  (75 % of the limit), not because each request costs more.
