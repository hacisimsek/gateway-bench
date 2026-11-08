# S1 passthrough — median of runs

```
date: 2026-11-08T09:08:23Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: eb0eb9c-dirty
limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu
jwt: yes (RS256, verified on every request)
rate limit: PER_SECOND=1000000  BURST=1000000 
java options:
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB | redis cpu % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 1000 | 1000 | 0.45 | 0.94 | 1.62 | 0.00 | 0 | 23 | 87 | 6 |
| java | 1000 | 1000 | 0.65 | 1.12 | 2.86 | 0.00 | 0 | 69 | 511 | 4 |
| rust | 5000 | 5000 | 0.24 | 0.47 | 1.61 | 0.00 | 0 | 53 | 87 | 12 |
| java | 5000 | 4997 | 0.58 | 6.24 | 15.06 | 0.00 | 81 | 181 | 512 | 11 |
| rust | 10000 | 9999 | 0.32 | 1.14 | 6.40 | 0.00 | 0 | 91 | 92 | 18 |
| java | 10000 | 963 | 1852.83 | 4789.61 | 6418.79 | 0.00 | 270231 | 119 | 511 | 3 |
| rust | 20000 | 19450 | 0.67 | 73.19 | 123.90 | 0.00 | 16439 | 146 | 130 | 24 |
| java | 20000 | 1043 | 1836.67 | 3950.72 | 5211.02 | 0.00 | 568149 | 112 | 512 | 2 |
