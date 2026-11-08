# S1 passthrough — median of runs

```
date: 2026-11-08T07:08:10Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: 01c70f5-dirty
limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu
jwt: yes (RS256, verified on every request)
rate limit: PER_SECOND=1000000  BURST=1000000 
java options:
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB | redis cpu % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 1000 | 1000 | 0.44 | 1.07 | 2.01 | 0.00 | 0 | 20 | 41 | 7 |
| java | 1000 | 1000 | 0.62 | 0.99 | 2.67 | 0.00 | 0 | 64 | 511 | 4 |
| rust | 5000 | 5000 | 0.21 | 0.44 | 0.78 | 0.00 | 0 | 43 | 41 | 11 |
| java | 5000 | 4992 | 0.52 | 4.20 | 17.25 | 0.00 | 225 | 162 | 512 | 11 |
| rust | 10000 | 10000 | 0.26 | 0.99 | 4.35 | 0.00 | 0 | 75 | 53 | 18 |
| java | 10000 | 1269 | 1506.10 | 2521.43 | 3591.72 | 0.00 | 261188 | 118 | 512 | 3 |
| rust | 20000 | 19967 | 0.39 | 1.41 | 7.71 | 0.00 | 948 | 119 | 72 | 26 |
| java | 20000 | 1243 | 1491.20 | 2913.43 | 5025.54 | 0.00 | 561130 | 115 | 512 | 3 |
