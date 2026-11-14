# S1 passthrough — median of runs

```
date: 2026-11-14T09:48:52Z
host: Apple M4 Pro, docker cpus=12 mem=8321429504
commit: 234075b-dirty
limits: rust 2 cpu/1024m, java 2 cpu/1024m, upstream 4 cpu/no mem limit, k6 4 cpu
jwt: yes (RS256, verified on every request)
rate limit: PER_SECOND=1000000  BURST=1000000 
java options:-XX:+UseG1GC
```

| target | rate | achieved rps | p50 ms | p95 ms | p99 ms | errors % | dropped | cpu % | mem MiB | redis cpu % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rust | 1000 | 1000 | 0.47 | 1.30 | 2.31 | 0.00 | 0 | 25 | 42 | 6 |
| java | 1000 | 1000 | 0.64 | 1.24 | 3.60 | 0.00 | 0 | 64 | 1009 | 4 |
| rust | 5000 | 5000 | 0.23 | 0.49 | 1.79 | 0.00 | 0 | 49 | 49 | 11 |
| java | 5000 | 5000 | 0.52 | 3.46 | 10.50 | 0.00 | 11 | 184 | 678 | 11 |
| rust | 10000 | 10000 | 0.29 | 0.95 | 3.86 | 0.00 | 0 | 88 | 128 | 16 |
| java | 10000 | 4629 | 367.38 | 577.95 | 1648.47 | 0.00 | 159954 | 193 | 1021 | 10 |
| rust | 20000 | 19958 | 0.56 | 4.70 | 30.79 | 0.00 | 1226 | 131 | 136 | 25 |
| java | 20000 | 4623 | 410.18 | 600.01 | 1009.17 | 0.00 | 460226 | 189 | 1020 | 10 |
